import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

typedef ProjectProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
      required bool includeParentEnvironment,
      required bool runInShell,
    });

/// One device-discovery operation whose process authority is explicit.
///
/// [ownsProcess] also covers a process start that has been requested but has
/// not completed yet. Callers must retain the query until [cancel] confirms
/// that no process can arrive late or remain alive.
abstract interface class DeviceDiscoveryQuery {
  Future<List<({String id, String name})>> get result;
  bool get ownsProcess;
  int? get ownedPid;

  /// Cancels this query and cleans up only its exact process handle.
  ///
  /// Returns false when bounded cleanup cannot yet prove that ownership was
  /// released. The query remains retryable in that case.
  Future<bool> cancel();
}

/// Starts a query with explicit ownership when [discovery] supports it.
///
/// The fallback preserves compatibility with injected discovery doubles that
/// implement the original [ProjectDiscovery.devices] API.
DeviceDiscoveryQuery startDeviceDiscoveryQuery(
  ProjectDiscovery discovery,
  String flutterExecutable,
) {
  final productionDiscovery = _ownedDeviceDiscoveryFactories[discovery];
  if (productionDiscovery != null) {
    return productionDiscovery._startDeviceDiscovery(flutterExecutable);
  }
  return _FutureDeviceDiscoveryQuery(discovery.devices(flutterExecutable));
}

final Expando<ProjectDiscovery> _ownedDeviceDiscoveryFactories =
    Expando<ProjectDiscovery>('owned device discovery factories');

enum ProjectDiscoveryError {
  invalidProject,
  invalidEntrypoint,
  entrypointOutsideProject,
  invalidFlutterExecutable,
  deviceDiscoveryFailed,
  invalidDeviceOutput,
}

class ProjectDiscoveryException implements Exception {
  const ProjectDiscoveryException(this.code, {this.details = const {}});

  final ProjectDiscoveryError code;
  final Map<String, Object?> details;

  @override
  String toString() => 'ProjectDiscoveryException($code, $details)';
}

class FlutterSdkNotFoundException implements Exception {
  const FlutterSdkNotFoundException(this.attemptedPaths);

  final List<String> attemptedPaths;

  @override
  String toString() => 'FlutterSdkNotFoundException($attemptedPaths)';
}

class ProjectDiscovery {
  ProjectDiscovery({
    ProjectProcessStarter processStarter = _startProcess,
    Map<String, String>? environment,
    Duration deviceDiscoveryTimeout = const Duration(seconds: 15),
    Duration processTerminationTimeout = const Duration(seconds: 2),
  }) : assert(deviceDiscoveryTimeout > Duration.zero),
       assert(processTerminationTimeout > Duration.zero),
       _processStarter = processStarter,
       _environment = Map<String, String>.unmodifiable(
         environment ?? Platform.environment,
       ),
       _deviceDiscoveryTimeout = deviceDiscoveryTimeout,
       _processTerminationTimeout = processTerminationTimeout {
    _ownedDeviceDiscoveryFactories[this] = this;
  }

  final ProjectProcessStarter _processStarter;
  final Map<String, String> _environment;
  final Duration _deviceDiscoveryTimeout;
  final Duration _processTerminationTimeout;
  _ProcessDeviceDiscoveryQuery? _activeDeviceDiscovery;

  Future<String> canonicalProjectDirectory(String projectDirectory) async {
    final directory = Directory(p.absolute(projectDirectory));
    if (!await directory.exists()) {
      throw ProjectDiscoveryException(
        ProjectDiscoveryError.invalidProject,
        details: <String, Object?>{'path': projectDirectory},
      );
    }
    final canonicalDirectory = await directory.resolveSymbolicLinks();
    if (!await File(p.join(canonicalDirectory, 'pubspec.yaml')).exists()) {
      throw ProjectDiscoveryException(
        ProjectDiscoveryError.invalidProject,
        details: <String, Object?>{'path': canonicalDirectory},
      );
    }
    return p.normalize(canonicalDirectory);
  }

  Future<List<String>> entrypoints(String projectDirectory) async {
    final project = await canonicalProjectDirectory(projectDirectory);
    final integrationDirectory = Directory(p.join(project, 'integration_test'));
    if (!await integrationDirectory.exists()) {
      return const <String>[];
    }

    final result = <String>[];
    await for (final entity in integrationDirectory.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is File && p.extension(entity.path) == '.dart') {
        final canonicalFile = await entity.resolveSymbolicLinks();
        if (_isContained(project, canonicalFile)) {
          result.add(p.relative(canonicalFile, from: project));
        }
      }
    }
    result.sort();
    return result;
  }

  /// Revalidates an entrypoint immediately before launch.
  ///
  /// Returns its canonical project-relative path when valid.
  Future<String> validateEntrypoint(
    String projectDirectory,
    String entrypoint,
  ) async {
    final project = await canonicalProjectDirectory(projectDirectory);
    if (entrypoint.isEmpty || p.isAbsolute(entrypoint)) {
      throw ProjectDiscoveryException(
        ProjectDiscoveryError.invalidEntrypoint,
        details: <String, Object?>{'entrypoint': entrypoint},
      );
    }
    final normalizedEntrypoint = p.normalize(entrypoint);
    final lexicalPath = p.normalize(p.join(project, normalizedEntrypoint));
    if (!_isContained(project, lexicalPath) ||
        p.extension(lexicalPath) != '.dart' ||
        !await File(lexicalPath).exists()) {
      throw ProjectDiscoveryException(
        ProjectDiscoveryError.invalidEntrypoint,
        details: <String, Object?>{'entrypoint': entrypoint},
      );
    }

    final canonicalFile = await File(lexicalPath).resolveSymbolicLinks();
    final integrationDirectory = p.join(project, 'integration_test');
    if (!_isContained(project, canonicalFile) ||
        !_isContained(integrationDirectory, canonicalFile)) {
      throw ProjectDiscoveryException(
        ProjectDiscoveryError.entrypointOutsideProject,
        details: <String, Object?>{'entrypoint': entrypoint},
      );
    }
    return p.relative(canonicalFile, from: project);
  }

  Future<String> resolveFlutterExecutable({
    required String projectDirectory,
    String? explicitFlutterExecutable,
    String? savedFlutterExecutable,
  }) async {
    final project = await canonicalProjectDirectory(projectDirectory);
    final attempted = <String>[];
    final candidates = <String?>[
      explicitFlutterExecutable,
      p.join(project, '.fvm', 'flutter_sdk', 'bin', 'flutter'),
      savedFlutterExecutable,
      ..._pathCandidates(),
    ];
    for (final candidate in candidates) {
      if (candidate == null || candidate.isEmpty) {
        continue;
      }
      final absoluteCandidate = p.normalize(p.absolute(candidate));
      if (attempted.contains(absoluteCandidate)) {
        continue;
      }
      attempted.add(absoluteCandidate);
      if (await _isExecutableFile(absoluteCandidate)) {
        return File(absoluteCandidate).resolveSymbolicLinks();
      }
    }
    throw FlutterSdkNotFoundException(List<String>.unmodifiable(attempted));
  }

  Future<List<({String id, String name})>> devices(String flutterExecutable) =>
      _startDeviceDiscovery(flutterExecutable).result;

  DeviceDiscoveryQuery _startDeviceDiscovery(String flutterExecutable) {
    final active = _activeDeviceDiscovery;
    if (active != null && active.ownsProcess) {
      throw ProjectDiscoveryException(
        ProjectDiscoveryError.deviceDiscoveryFailed,
        details: <String, Object?>{
          'error': 'device discovery is already active',
          if (active.ownedPid != null) 'pid': active.ownedPid,
        },
      );
    }
    late final _ProcessDeviceDiscoveryQuery query;
    query = _ProcessDeviceDiscoveryQuery(
      flutterExecutable: flutterExecutable,
      processStarter: _processStarter,
      environment: _environment,
      discoveryTimeout: _deviceDiscoveryTimeout,
      terminationTimeout: _processTerminationTimeout,
      release: () {
        if (identical(_activeDeviceDiscovery, query)) {
          _activeDeviceDiscovery = null;
        }
      },
    );
    _activeDeviceDiscovery = query;
    query.start();
    return query;
  }

  static List<({String id, String name})> _parseDevices(ProcessResult result) {
    if (result.exitCode != 0) {
      throw ProjectDiscoveryException(
        ProjectDiscoveryError.deviceDiscoveryFailed,
        details: <String, Object?>{
          'exitCode': result.exitCode,
          'stderr': result.stderr.toString(),
        },
      );
    }

    try {
      final json = jsonDecode(result.stdout.toString());
      if (json is! List<dynamic>) {
        throw const FormatException('device output must be a JSON list');
      }
      final devices = <({String id, String name})>[];
      for (final item in json) {
        if (item is! Map<String, dynamic> ||
            item['id'] is! String ||
            item['name'] is! String) {
          throw const FormatException('device entry is invalid');
        }
        final targetPlatform = item['targetPlatform'];
        final isLaunchableTarget =
            item['isSupported'] == true &&
            (targetPlatform == 'darwin' ||
                (targetPlatform == 'ios' && item['emulator'] == true));
        if (!isLaunchableTarget) {
          continue;
        }
        devices.add((id: item['id'] as String, name: item['name'] as String));
      }
      devices.sort((first, second) {
        final byName = first.name.compareTo(second.name);
        return byName != 0 ? byName : first.id.compareTo(second.id);
      });
      return devices;
    } on FormatException catch (error) {
      throw ProjectDiscoveryException(
        ProjectDiscoveryError.invalidDeviceOutput,
        details: <String, Object?>{'error': error.message},
      );
    }
  }

  Iterable<String> _pathCandidates() sync* {
    final pathValue = _environment['PATH'];
    if (pathValue == null) {
      return;
    }
    for (final directory in pathValue.split(':')) {
      if (directory.isNotEmpty) {
        yield p.join(directory, 'flutter');
      }
    }
  }
}

final class _FutureDeviceDiscoveryQuery implements DeviceDiscoveryQuery {
  _FutureDeviceDiscoveryQuery(this.result);

  @override
  final Future<List<({String id, String name})>> result;

  @override
  bool get ownsProcess => false;

  @override
  int? get ownedPid => null;

  @override
  Future<bool> cancel() async => true;
}

final class _ProcessDeviceDiscoveryQuery implements DeviceDiscoveryQuery {
  _ProcessDeviceDiscoveryQuery({
    required this.flutterExecutable,
    required ProjectProcessStarter processStarter,
    required Map<String, String> environment,
    required Duration discoveryTimeout,
    required Duration terminationTimeout,
    required void Function() release,
  }) : _processStarter = processStarter,
       _environment = environment,
       _discoveryTimeout = discoveryTimeout,
       _terminationTimeout = terminationTimeout,
       _release = release;

  final String flutterExecutable;
  final ProjectProcessStarter _processStarter;
  final Map<String, String> _environment;
  final Duration _discoveryTimeout;
  final Duration _terminationTimeout;
  final void Function() _release;
  final Completer<List<({String id, String name})>> _result =
      Completer<List<({String id, String name})>>();
  final Completer<void> _starterSettled = Completer<void>();

  Timer? _deadline;
  Process? _process;
  String? _resolvedExecutable;
  Future<bool>? _cleanupFuture;
  Future<bool>? _terminationFuture;
  bool _starterInvoked = false;
  bool _cancelRequested = false;
  bool _timedOut = false;
  bool _released = false;

  @override
  Future<List<({String id, String name})>> get result => _result.future;

  @override
  bool get ownsProcess => !_released;

  @override
  int? get ownedPid => _process?.pid;

  void start() {
    _deadline = Timer(_discoveryTimeout, () {
      unawaited(_handleDeadline());
    });
    unawaited(_run());
  }

  @override
  Future<bool> cancel() async {
    if (_released) return true;
    _cancelRequested = true;
    _deadline?.cancel();
    final terminated = await _cleanupAfterCancellation();
    _completeCancellation(terminated: terminated);
    return terminated;
  }

  Future<void> _handleDeadline() async {
    if (_result.isCompleted) return;
    _timedOut = true;
    _cancelRequested = true;
    final terminated = await _cleanupAfterCancellation();
    _completeCancellation(terminated: terminated);
  }

  Future<void> _run() async {
    try {
      if (!p.isAbsolute(flutterExecutable) ||
          !await _isExecutableFile(flutterExecutable)) {
        throw ProjectDiscoveryException(
          ProjectDiscoveryError.invalidFlutterExecutable,
          details: <String, Object?>{'path': flutterExecutable},
        );
      }
      final executable = await File(flutterExecutable).resolveSymbolicLinks();
      _resolvedExecutable = executable;
      if (_cancelRequested || _result.isCompleted) {
        _releaseOwnership();
        _completeCancellation(terminated: true);
        return;
      }

      _starterInvoked = true;
      Future<Process> pendingProcess;
      try {
        pendingProcess = _processStarter(
          executable,
          const <String>['devices', '--machine'],
          environment: _environment,
          includeParentEnvironment: false,
          runInShell: false,
        );
      } on Object {
        _settleStarter();
        rethrow;
      }
      try {
        _process = await pendingProcess;
      } finally {
        _settleStarter();
      }
      if (_cancelRequested || _result.isCompleted) {
        final terminated = await _cleanupAfterCancellation();
        _completeCancellation(terminated: terminated);
        return;
      }

      final process = _process!;
      final stdout = process.stdout.transform(systemEncoding.decoder).join();
      final stderr = process.stderr.transform(systemEncoding.decoder).join();
      late final ProcessResult processResult;
      try {
        await process.stdin.close();
        final values = await Future.wait<Object>(<Future<Object>>[
          process.exitCode,
          stdout,
          stderr,
        ]);
        if (_cancelRequested || _result.isCompleted) return;
        _deadline?.cancel();
        _releaseOwnership();
        processResult = ProcessResult(
          process.pid,
          values[0] as int,
          values[1] as String,
          values[2] as String,
        );
      } on Object catch (error, stackTrace) {
        if (_cancelRequested || _result.isCompleted) return;
        _deadline?.cancel();
        final terminated = await _terminateOwnedProcess();
        _completeError(
          ProjectDiscoveryException(
            ProjectDiscoveryError.deviceDiscoveryFailed,
            details: <String, Object?>{
              'path': executable,
              'pid': process.pid,
              'terminated': terminated,
              'error': error,
            },
          ),
          stackTrace,
        );
        return;
      }
      try {
        _result.complete(ProjectDiscovery._parseDevices(processResult));
      } on Object catch (error, stackTrace) {
        _completeError(error, stackTrace);
      }
    } on Object catch (error, stackTrace) {
      if (_cancelRequested || _result.isCompleted) {
        if (_process == null) _releaseOwnership();
        return;
      }
      _deadline?.cancel();
      if (_starterInvoked && !_starterSettled.isCompleted) {
        _settleStarter();
      }
      if (_process == null) _releaseOwnership();
      if (error is ProjectDiscoveryException) {
        _completeError(error, stackTrace);
      } else {
        _completeError(
          ProjectDiscoveryException(
            ProjectDiscoveryError.deviceDiscoveryFailed,
            details: <String, Object?>{'error': error},
          ),
          stackTrace,
        );
      }
    }
  }

  Future<bool> _cleanupAfterCancellation() {
    final active = _cleanupFuture;
    if (active != null) return active;
    late final Future<bool> tracked;
    tracked = _cleanupAfterCancellationInner().whenComplete(() {
      if (identical(_cleanupFuture, tracked)) _cleanupFuture = null;
    });
    _cleanupFuture = tracked;
    return tracked;
  }

  Future<bool> _cleanupAfterCancellationInner() async {
    if (_released) return true;
    if (!_starterInvoked) {
      _releaseOwnership();
      return true;
    }
    if (!_starterSettled.isCompleted) {
      try {
        await _starterSettled.future.timeout(_terminationTimeout);
      } on TimeoutException {
        return false;
      }
    }
    if (_process == null) {
      _releaseOwnership();
      return true;
    }
    return _terminateOwnedProcess();
  }

  Future<bool> _terminateOwnedProcess() {
    final active = _terminationFuture;
    if (active != null) return active;
    late final Future<bool> tracked;
    tracked = _terminateOwnedProcessInner().whenComplete(() {
      if (identical(_terminationFuture, tracked)) _terminationFuture = null;
    });
    _terminationFuture = tracked;
    return tracked;
  }

  Future<bool> _terminateOwnedProcessInner() async {
    final process = _process;
    if (process == null) return false;
    var terminated = false;
    try {
      process.kill();
      terminated = await _waitForExit(process);
      if (!terminated) {
        process.kill(ProcessSignal.sigkill);
        terminated = await _waitForExit(process);
      }
    } on Object {
      terminated = false;
    }
    if (terminated) _releaseOwnership();
    return terminated;
  }

  Future<bool> _waitForExit(Process process) async {
    try {
      await process.exitCode.timeout(_terminationTimeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  void _settleStarter() {
    if (!_starterSettled.isCompleted) _starterSettled.complete();
  }

  void _releaseOwnership() {
    if (_released) return;
    _released = true;
    _deadline?.cancel();
    _release();
  }

  void _completeCancellation({required bool terminated}) {
    if (_result.isCompleted) return;
    _completeError(
      ProjectDiscoveryException(
        ProjectDiscoveryError.deviceDiscoveryFailed,
        details: <String, Object?>{
          'path': _resolvedExecutable ?? flutterExecutable,
          if (_timedOut)
            'timeoutMilliseconds': _discoveryTimeout.inMilliseconds
          else
            'cancelled': true,
          if (ownedPid != null) 'pid': ownedPid,
          'terminated': terminated,
        },
      ),
      StackTrace.current,
    );
  }

  void _completeError(Object error, StackTrace stackTrace) {
    if (!_result.isCompleted) _result.completeError(error, stackTrace);
  }
}

Future<Process> _startProcess(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
  bool runInShell = false,
}) => Process.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
  includeParentEnvironment: includeParentEnvironment,
  runInShell: runInShell,
);

Future<bool> _isExecutableFile(String path) async {
  final stat = await FileStat.stat(path);
  return stat.type == FileSystemEntityType.file && (stat.mode & 0x49) != 0;
}

bool _isContained(String parent, String child) {
  final normalizedParent = p.normalize(parent);
  final normalizedChild = p.normalize(child);
  return normalizedParent == normalizedChild ||
      p.isWithin(normalizedParent, normalizedChild);
}
