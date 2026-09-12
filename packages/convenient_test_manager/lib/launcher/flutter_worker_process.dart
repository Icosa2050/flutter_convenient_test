import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:convenient_test_manager/launcher/flutter_machine_protocol.dart';
import 'package:convenient_test_manager/launcher/launch_configuration.dart';
import 'package:convenient_test_manager/launcher/owned_process_group.dart';

typedef FlutterProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      required bool includeParentEnvironment,
      required bool runInShell,
      required ProcessStartMode mode,
    });

enum WorkerLogSource { stdout, stderr }

enum WorkerFailureCode {
  invalidManagerPort,
  invalidSessionId,
  reservedDartDefine,
  alreadyRunning,
  disposed,
  spawnFailed,
  unsupportedProtocol,
  protocolViolation,
  buildFailed,
  exitedEarly,
  unexpectedExit,
  stopRequestFailed,
  stopTimedOut,
}

sealed class WorkerEvent {
  const WorkerEvent({required this.runId, required this.sessionId});

  final int runId;
  final String sessionId;
}

final class WorkerLogEvent extends WorkerEvent {
  const WorkerLogEvent({
    required super.runId,
    required super.sessionId,
    required this.source,
    required this.message,
    required this.isError,
    required this.malformedProtocol,
    required this.truncated,
  });

  final WorkerLogSource source;
  final String message;
  final bool isError;
  final bool malformedProtocol;
  final bool truncated;
}

final class WorkerAppStartedEvent extends WorkerEvent {
  const WorkerAppStartedEvent({
    required super.runId,
    required super.sessionId,
    required this.appId,
  });

  final String appId;
}

final class WorkerDebugPortEvent extends WorkerEvent {
  const WorkerDebugPortEvent({
    required super.runId,
    required super.sessionId,
    required this.appId,
    required this.vmServiceUri,
    required this.baseUri,
    required this.port,
  });

  final String appId;

  /// Flutter's advertised `wsUri`, normally the DDS WebSocket endpoint.
  final Uri vmServiceUri;

  /// The underlying VM service base URI when Flutter supplies one.
  final Uri? baseUri;
  final int? port;
}

final class WorkerExitedEvent extends WorkerEvent {
  const WorkerExitedEvent({
    required super.runId,
    required super.sessionId,
    required this.exitCode,
    required this.stopRequested,
    required this.appStopRequested,
  });

  final int exitCode;
  final bool stopRequested;

  /// True means an `app.stop` request was written to Flutter. Native app cleanup
  /// still has to pass the owned-process-boundary cleanup before this event.
  final bool appStopRequested;
}

final class WorkerFailureEvent extends WorkerEvent {
  WorkerFailureEvent({
    required super.runId,
    required super.sessionId,
    required this.code,
    Map<String, Object?> details = const <String, Object?>{},
  }) : details = UnmodifiableMapView<String, Object?>(
         Map<String, Object?>.of(details),
       );

  final WorkerFailureCode code;
  final Map<String, Object?> details;
}

final class WorkerProcessException implements Exception {
  WorkerProcessException(
    this.code, {
    Map<String, Object?> details = const <String, Object?>{},
  }) : details = UnmodifiableMapView<String, Object?>(
         Map<String, Object?>.of(details),
       );

  final WorkerFailureCode code;
  final Map<String, Object?> details;

  @override
  String toString() => 'WorkerProcessException($code, $details)';
}

/// Owns exactly one `flutter run --machine` process family at a time.
final class FlutterWorkerProcess {
  FlutterWorkerProcess({
    FlutterProcessStarter? processStarter,
    OwnedProcessGroupStarter? ownedProcessGroupStarter,
    this.gracefulStopTimeout = const Duration(seconds: 10),
    this.terminateTimeout = const Duration(seconds: 3),
    this.killTimeout = const Duration(seconds: 2),
    this.maxRetainedLogLines = 2000,
    this.maxLogCharacters = 16 * 1024,
  }) : assert(
         processStarter == null || ownedProcessGroupStarter == null,
         'inject either processStarter or ownedProcessGroupStarter, not both',
       ),
       _processStarter = processStarter,
       _ownedProcessGroupStarter =
           ownedProcessGroupStarter ??
           (processStarter == null && Platform.isMacOS
               ? PosixOwnedProcessGroup.start
               : null) {
    if (maxRetainedLogLines <= 0) {
      throw ArgumentError.value(
        maxRetainedLogLines,
        'maxRetainedLogLines',
        'must be positive',
      );
    }
    if (maxLogCharacters <= 0) {
      throw ArgumentError.value(
        maxLogCharacters,
        'maxLogCharacters',
        'must be positive',
      );
    }
  }

  static const Set<String> reservedDartDefineKeys = <String>{
    'CONVENIENT_TEST_APP_CODE_DIR',
    'CONVENIENT_TEST_MANAGER_HOST',
    'CONVENIENT_TEST_MANAGER_PORT',
  };

  final FlutterProcessStarter? _processStarter;
  final OwnedProcessGroupStarter? _ownedProcessGroupStarter;
  final Duration gracefulStopTimeout;
  final Duration terminateTimeout;
  final Duration killTimeout;
  final int maxRetainedLogLines;
  final int maxLogCharacters;

  final _eventController = StreamController<WorkerEvent>.broadcast(sync: true);
  final Queue<WorkerLogEvent> _logs = Queue<WorkerLogEvent>();

  _WorkerRun? _current;
  Future<void>? _stopFuture;
  Future<void>? _disposeFuture;
  Completer<void>? _startSettled;
  var _starting = false;
  var _lastRunId = 0;
  var _disposing = false;
  var _disposed = false;

  Stream<WorkerEvent> get events => _eventController.stream;
  bool get owned => _current != null;
  int? get ownedPid => _current?.process.pid;
  int? get currentRunId => _current?.runId;
  List<WorkerLogEvent> get logs => List<WorkerLogEvent>.unmodifiable(_logs);

  Future<void> start(
    LaunchConfiguration configuration, {
    required String sessionId,
    required int managerPort,
  }) async {
    if (_disposing || _disposed) {
      throw WorkerProcessException(WorkerFailureCode.disposed);
    }
    if (_starting || owned) {
      _emitFailure(
        runId: _current?.runId ?? _lastRunId,
        sessionId: _current?.sessionId ?? sessionId,
        code: WorkerFailureCode.alreadyRunning,
        details: <String, Object?>{'pid': ownedPid},
      );
      throw WorkerProcessException(
        WorkerFailureCode.alreadyRunning,
        details: <String, Object?>{'pid': ownedPid},
      );
    }
    _validateStart(sessionId, managerPort, configuration.dartDefines);

    final runId = ++_lastRunId;
    final arguments = _arguments(configuration, managerPort);
    _logs.clear();
    _starting = true;
    final startSettled = Completer<void>();
    _startSettled = startSettled;

    try {
      final ownership = await _startOwnedProcess(
        configuration.flutterExecutable,
        arguments,
        workingDirectory: configuration.projectDirectory,
        includeParentEnvironment: true,
        runInShell: false,
        mode: ProcessStartMode.normal,
      );
      final run = _WorkerRun(
        runId: runId,
        sessionId: sessionId,
        ownership: ownership,
      );
      _current = run;
      _listen(run, ownership.stdout, WorkerLogSource.stdout);
      _listen(run, ownership.stderr, WorkerLogSource.stderr);
      run.exitFuture = ownership.process.exitCode.then((exitCode) {
        run.rootExitCode = exitCode;
        unawaited(_handleRootExit(run));
        return exitCode;
      });
    } on Object catch (error) {
      if (error case OwnedProcessGroupStartException(
        cleanupOwnership: final ownership?,
      )) {
        final run = _WorkerRun(
          runId: runId,
          sessionId: sessionId,
          ownership: ownership,
        )..terminalFailureReported = true;
        _current = run;
        _listen(run, ownership.stdout, WorkerLogSource.stdout);
        _listen(run, ownership.stderr, WorkerLogSource.stderr);
        run.exitFuture = ownership.process.exitCode.then((exitCode) {
          run.rootExitCode = exitCode;
          unawaited(_handleRootExit(run));
          return exitCode;
        });
      }
      _emitFailure(
        runId: runId,
        sessionId: sessionId,
        code: WorkerFailureCode.spawnFailed,
        details: <String, Object?>{'error': error},
      );
      throw WorkerProcessException(
        WorkerFailureCode.spawnFailed,
        details: <String, Object?>{'error': error},
      );
    } finally {
      _starting = false;
      if (!startSettled.isCompleted) {
        startSettled.complete();
      }
      if (identical(_startSettled, startSettled)) {
        _startSettled = null;
      }
    }
  }

  Future<OwnedProcessGroup> _startOwnedProcess(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required bool includeParentEnvironment,
    required bool runInShell,
    required ProcessStartMode mode,
  }) async {
    if (_ownedProcessGroupStarter case final starter?) {
      return starter(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        includeParentEnvironment: includeParentEnvironment,
        runInShell: runInShell,
        mode: mode,
      );
    }
    final process = await (_processStarter ?? Process.start)(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      includeParentEnvironment: includeParentEnvironment,
      runInShell: runInShell,
      mode: mode,
    );
    return SingleProcessOwnership(process);
  }

  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) {
      return existing;
    }
    final future = _stopAfterPendingStart();
    _stopFuture = future;
    return future.whenComplete(() {
      if (identical(_stopFuture, future)) {
        _stopFuture = null;
      }
    });
  }

  Future<void> _stopAfterPendingStart() async {
    if (_starting) {
      await _startSettled?.future;
    }
    final run = _current;
    if (run == null) {
      return;
    }
    await _stopRun(run);
  }

  Future<void> _stopRun(_WorkerRun run) async {
    run.stopRequested = true;
    if (run.rootExitCode != null) {
      await _containRun(run);
      return;
    }
    if (run.appId case final appId?) {
      final requestId = ++run.requestId;
      run.pendingStopRequestId = requestId;
      run.stopResponse = Completer<bool>();
      try {
        run.process.stdin.writeln(
          FlutterMachineProtocol.encodeRequest(
            id: requestId,
            method: 'app.stop',
            params: <String, Object?>{'appId': appId},
          ),
        );
        await run.process.stdin.flush();
        run.appStopRequested = true;
      } on Object catch (error) {
        _reportRunFailure(
          run,
          WorkerFailureCode.stopRequestFailed,
          <String, Object?>{'pid': run.process.pid, 'error': error},
          terminal: false,
        );
      }
      if (await _waitForStopResponseOrExit(run, gracefulStopTimeout) &&
          (!_isCurrent(run) ||
              await _waitForFinished(run, gracefulStopTimeout))) {
        return;
      }
    } else {
      run.ownership.signal(ProcessSignal.sigint);
      if (await _waitForFinished(run, gracefulStopTimeout)) {
        return;
      }
    }
    await _containRun(run);
  }

  Future<bool> _waitForFinished(_WorkerRun run, Duration timeout) async {
    try {
      await run.finished.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<bool> _waitForStopResponseOrExit(
    _WorkerRun run,
    Duration timeout,
  ) async {
    try {
      await Future.any<Object?>(<Future<Object?>>[
        run.exitFuture,
        if (run.stopResponse case final response?) response.future,
      ]).timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> _handleRootExit(_WorkerRun run) async {
    if (!_isCurrent(run)) {
      return;
    }
    try {
      await _containRun(run);
    } on WorkerProcessException {
      // The failure event was emitted by _containRun. Ownership is retained so
      // an explicit stop/dispose can retry the exact same boundary.
    }
  }

  Future<void> _containRun(_WorkerRun run) {
    final existing = run.containmentFuture;
    if (existing != null) {
      return existing;
    }
    late final Future<void> tracked;
    tracked = _containRunOnce(run).whenComplete(() {
      if (identical(run.containmentFuture, tracked)) {
        run.containmentFuture = null;
      }
    });
    run.containmentFuture = tracked;
    return tracked;
  }

  Future<void> _containRunOnce(_WorkerRun run) async {
    try {
      if (await run.ownership.waitForExit(Duration.zero)) {
        await _finishRun(run);
        return;
      }
      run.ownership.signal(ProcessSignal.sigterm);
      if (await run.ownership.waitForExit(terminateTimeout)) {
        await _finishRun(run);
        return;
      }
      run.ownership.signal(ProcessSignal.sigkill);
      if (await run.ownership.waitForExit(killTimeout)) {
        await _finishRun(run);
        return;
      }
    } on Object catch (error) {
      _throwStopTimedOut(run, error: error);
    }
    _throwStopTimedOut(run);
  }

  Never _throwStopTimedOut(_WorkerRun run, {Object? error}) {
    final details = <String, Object?>{
      'pid': run.process.pid,
      'processGroupId': run.ownership.groupId,
      'appId': run.appId,
      'appStopRequested': run.appStopRequested,
      if (error != null) 'error': error,
    };
    _reportRunFailure(
      run,
      WorkerFailureCode.stopTimedOut,
      details,
      terminal: false,
    );
    throw WorkerProcessException(
      WorkerFailureCode.stopTimedOut,
      details: details,
    );
  }

  Future<void> dispose() {
    if (_disposed) {
      return Future<void>.value();
    }
    final existing = _disposeFuture;
    if (existing != null) {
      return existing;
    }

    _disposing = true;
    late final Future<void> tracked;
    tracked = _disposeCleanup().whenComplete(() {
      if (identical(_disposeFuture, tracked)) {
        _disposeFuture = null;
      }
    });
    _disposeFuture = tracked;
    return tracked;
  }

  Future<void> _disposeCleanup() async {
    try {
      await stop();
      if (owned) {
        return;
      }
      _disposed = true;
      await _eventController.close();
    } finally {
      _disposing = false;
    }
  }

  void _validateStart(
    String sessionId,
    int managerPort,
    Map<String, String> dartDefines,
  ) {
    if (sessionId.isEmpty) {
      _emitFailure(
        runId: _lastRunId,
        sessionId: sessionId,
        code: WorkerFailureCode.invalidSessionId,
      );
      throw WorkerProcessException(WorkerFailureCode.invalidSessionId);
    }
    if (managerPort < 1 || managerPort > 65535) {
      final details = <String, Object?>{'port': managerPort};
      _emitFailure(
        runId: _lastRunId,
        sessionId: sessionId,
        code: WorkerFailureCode.invalidManagerPort,
        details: details,
      );
      throw WorkerProcessException(
        WorkerFailureCode.invalidManagerPort,
        details: details,
      );
    }
    for (final key in reservedDartDefineKeys) {
      if (dartDefines.containsKey(key)) {
        final details = <String, Object?>{'key': key};
        _emitFailure(
          runId: _lastRunId,
          sessionId: sessionId,
          code: WorkerFailureCode.reservedDartDefine,
          details: details,
        );
        throw WorkerProcessException(
          WorkerFailureCode.reservedDartDefine,
          details: details,
        );
      }
    }
  }

  List<String> _arguments(LaunchConfiguration configuration, int managerPort) =>
      <String>[
        'run',
        '--machine',
        '--debug',
        '-d',
        configuration.deviceId,
        configuration.entrypoint,
        '--host-vmservice-port',
        '0',
        '--dart-define',
        'CONVENIENT_TEST_APP_CODE_DIR=${configuration.projectDirectory}',
        '--dart-define',
        'CONVENIENT_TEST_MANAGER_HOST=127.0.0.1',
        '--dart-define',
        'CONVENIENT_TEST_MANAGER_PORT=$managerPort',
        for (final entry in configuration.dartDefines.entries) ...<String>[
          '--dart-define',
          '${entry.key}=${entry.value}',
        ],
      ];

  void _listen(
    _WorkerRun run,
    Stream<List<int>> bytes,
    WorkerLogSource source,
  ) {
    final subscription =
        FlutterMachineProtocol(maxRecordCharacters: maxLogCharacters)
            .decode(bytes)
            .listen(
              (record) => _handleRecord(run, source, record),
              onError: (Object error, StackTrace stackTrace) {
                if (!_isCurrent(run)) {
                  return;
                }
                _reportRunFailure(
                  run,
                  WorkerFailureCode.protocolViolation,
                  <String, Object?>{
                    'source': source.name,
                    'error': error,
                    'stackTrace': stackTrace,
                  },
                );
              },
            );
    run.subscriptions.add(subscription);
  }

  void _handleRecord(
    _WorkerRun run,
    WorkerLogSource source,
    FlutterMachineRecord record,
  ) {
    if (!_isCurrent(run)) {
      return;
    }
    switch (record) {
      case FlutterMachineLog():
        _emitLog(
          run,
          source,
          record.text,
          isError: source == WorkerLogSource.stderr,
          malformedProtocol: record.malformedProtocol,
          truncated: record.truncated,
        );
      case FlutterMachineResponse():
        if (record.id == run.pendingStopRequestId) {
          run.pendingStopRequestId = null;
          final response = run.stopResponse;
          if (record.error != null || record.result != true) {
            _reportRunFailure(
              run,
              WorkerFailureCode.stopRequestFailed,
              <String, Object?>{
                'pid': run.process.pid,
                'error': record.error,
                'result': record.result,
                'trace': record.trace,
              },
              terminal: false,
            );
            if (response != null && !response.isCompleted) {
              response.complete(false);
            }
          } else if (response != null && !response.isCompleted) {
            response.complete(true);
          }
        }
      case FlutterMachineEvent():
        _handleMachineEvent(run, source, record);
    }
  }

  void _handleMachineEvent(
    _WorkerRun run,
    WorkerLogSource source,
    FlutterMachineEvent event,
  ) {
    if (event.name == 'daemon.connected') {
      _acceptProtocol(run, event.params);
      return;
    }
    if (event.name == 'app.log' || event.name == 'daemon.logMessage') {
      final message = event.params['log'] ?? event.params['message'];
      if (message is String) {
        _emitLog(
          run,
          source,
          message,
          isError:
              source == WorkerLogSource.stderr || event.params['error'] == true,
        );
      } else {
        _reportProtocolViolation(run, event.name, 'missingLog');
      }
      return;
    }
    if (!event.name.startsWith('app.')) {
      return;
    }
    if (!run.protocolAccepted) {
      _reportProtocolViolation(run, event.name, 'protocolNotAccepted');
      return;
    }

    switch (event.name) {
      case 'app.start':
        final appId = _appId(event.params);
        if (appId == null) {
          _reportProtocolViolation(run, event.name, 'invalidAppId');
          return;
        }
        if (run.appId != null && run.appId != appId) {
          _reportProtocolViolation(run, event.name, 'appIdMismatch');
          return;
        }
        run.appId = appId;
      case 'app.started':
        final appId = _matchingAppId(run, event);
        if (appId == null) {
          return;
        }
        run.appStarted = true;
        _emit(
          WorkerAppStartedEvent(
            runId: run.runId,
            sessionId: run.sessionId,
            appId: appId,
          ),
        );
      case 'app.debugPort':
        final appId = _matchingAppId(run, event);
        if (appId == null) {
          return;
        }
        final wsUriValue = event.params['wsUri'];
        final wsUri = wsUriValue is String ? Uri.tryParse(wsUriValue) : null;
        if (wsUri == null ||
            !wsUri.hasAuthority ||
            (wsUri.scheme != 'ws' && wsUri.scheme != 'wss')) {
          _reportProtocolViolation(run, event.name, 'invalidWsUri');
          return;
        }
        final baseUriValue = event.params['baseUri'];
        final baseUri = baseUriValue is String
            ? Uri.tryParse(baseUriValue)
            : null;
        if (baseUriValue != null && baseUri == null) {
          _reportProtocolViolation(run, event.name, 'invalidBaseUri');
          return;
        }
        final portValue = event.params['port'];
        if (portValue != null && portValue is! int) {
          _reportProtocolViolation(run, event.name, 'invalidPort');
          return;
        }
        _emit(
          WorkerDebugPortEvent(
            runId: run.runId,
            sessionId: run.sessionId,
            appId: appId,
            vmServiceUri: wsUri,
            baseUri: baseUri,
            port: portValue as int?,
          ),
        );
      case 'app.stop':
        final appId = _appId(event.params);
        if (run.appId != null && appId != run.appId) {
          _reportProtocolViolation(run, event.name, 'appIdMismatch');
          return;
        }
        final error = event.params['error'];
        if (error != null) {
          _reportRunFailure(
            run,
            run.appStarted
                ? WorkerFailureCode.unexpectedExit
                : WorkerFailureCode.buildFailed,
            <String, Object?>{'error': error, 'appId': appId},
          );
        }
    }
  }

  void _acceptProtocol(_WorkerRun run, Map<String, Object?> params) {
    final version = params['version'];
    if (version is! String || !_isSupportedProtocol(version)) {
      _reportRunFailure(
        run,
        WorkerFailureCode.unsupportedProtocol,
        <String, Object?>{'version': version},
      );
      return;
    }
    run.protocolAccepted = true;
    run.protocolVersion = version;
  }

  bool _isSupportedProtocol(String version) {
    final parts = version.split('.');
    if (parts.length != 3) {
      return false;
    }
    final major = int.tryParse(parts[0]);
    final minor = int.tryParse(parts[1]);
    final patch = int.tryParse(parts[2]);
    return major == 0 && minor == 6 && patch != null;
  }

  String? _matchingAppId(_WorkerRun run, FlutterMachineEvent event) {
    final appId = _appId(event.params);
    if (appId == null || run.appId == null || appId != run.appId) {
      _reportProtocolViolation(run, event.name, 'appIdMismatch');
      return null;
    }
    return appId;
  }

  String? _appId(Map<String, Object?> params) {
    final appId = params['appId'];
    return appId is String && appId.isNotEmpty ? appId : null;
  }

  void _reportProtocolViolation(_WorkerRun run, String event, String reason) {
    _reportRunFailure(
      run,
      WorkerFailureCode.protocolViolation,
      <String, Object?>{
        'event': event,
        'reason': reason,
        'pid': run.process.pid,
      },
    );
  }

  void _emitLog(
    _WorkerRun run,
    WorkerLogSource source,
    String message, {
    required bool isError,
    bool malformedProtocol = false,
    bool truncated = false,
  }) {
    final log = WorkerLogEvent(
      runId: run.runId,
      sessionId: run.sessionId,
      source: source,
      message: message,
      isError: isError,
      malformedProtocol: malformedProtocol,
      truncated: truncated,
    );
    _logs.addLast(log);
    while (_logs.length > maxRetainedLogLines) {
      _logs.removeFirst();
    }
    _emit(log);
  }

  Future<void> _finishRun(_WorkerRun run) async {
    if (!_isCurrent(run)) {
      return;
    }
    final exitCode = run.rootExitCode ?? await run.process.exitCode;
    if (!await run.ownership.waitForExit(Duration.zero)) {
      return;
    }
    run.active = false;
    _current = null;
    for (final subscription in run.subscriptions) {
      unawaited(subscription.cancel());
    }

    if (!run.stopRequested && !run.terminalFailureReported) {
      _reportRunFailure(
        run,
        run.appStarted
            ? WorkerFailureCode.unexpectedExit
            : WorkerFailureCode.exitedEarly,
        <String, Object?>{'pid': run.process.pid, 'exitCode': exitCode},
      );
    }
    _emit(
      WorkerExitedEvent(
        runId: run.runId,
        sessionId: run.sessionId,
        exitCode: exitCode,
        stopRequested: run.stopRequested,
        appStopRequested: run.appStopRequested,
      ),
    );
    if (!run.finished.isCompleted) {
      run.finished.complete();
    }
  }

  void _reportRunFailure(
    _WorkerRun run,
    WorkerFailureCode code,
    Map<String, Object?> details, {
    bool terminal = true,
  }) {
    if (!_isCurrent(run) && run.active) {
      return;
    }
    if (terminal) {
      run.terminalFailureReported = true;
    }
    _emitFailure(
      runId: run.runId,
      sessionId: run.sessionId,
      code: code,
      details: details,
    );
  }

  void _emitFailure({
    required int runId,
    required String sessionId,
    required WorkerFailureCode code,
    Map<String, Object?> details = const <String, Object?>{},
  }) {
    _emit(
      WorkerFailureEvent(
        runId: runId,
        sessionId: sessionId,
        code: code,
        details: details,
      ),
    );
  }

  bool _isCurrent(_WorkerRun run) =>
      run.active && identical(_current, run) && run.runId == _current?.runId;

  void _emit(WorkerEvent event) {
    if (!_eventController.isClosed) {
      _eventController.add(event);
    }
  }
}

final class _WorkerRun {
  _WorkerRun({
    required this.runId,
    required this.sessionId,
    required this.ownership,
  });

  final int runId;
  final String sessionId;
  final OwnedProcessGroup ownership;
  final subscriptions = <StreamSubscription<FlutterMachineRecord>>[];
  final finished = Completer<void>();
  late final Future<int> exitFuture;
  Future<void>? containmentFuture;

  Process get process => ownership.process;

  String? protocolVersion;
  String? appId;
  int? rootExitCode;
  int? pendingStopRequestId;
  Completer<bool>? stopResponse;
  var requestId = 0;
  var active = true;
  var protocolAccepted = false;
  var appStarted = false;
  var stopRequested = false;
  var appStopRequested = false;
  var terminalFailureReported = false;
}
