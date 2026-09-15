import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';

import 'package:convenient_test_manager/launcher/flutter_worker_process.dart';
import 'package:convenient_test_manager/launcher/launch_configuration.dart';
import 'package:convenient_test_manager/launcher/launcher_preferences.dart';
import 'package:convenient_test_manager/launcher/launcher_session_services.dart';
import 'package:convenient_test_manager/launcher/project_discovery.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

enum LauncherState {
  idle,
  validating,
  starting,
  connecting,
  running,
  stopping,
  failed,
}

enum LauncherErrorCode {
  busy,
  incompleteSelection,
  invalidProject,
  invalidEntrypoint,
  invalidSdk,
  reservedDefine,
  deviceDiscoveryFailure,
  noEntrypoints,
  noDevices,
  restoreFailure,
  saveFailure,
  bindFailure,
  portConflict,
  invalidManagerPort,
  invalidWorkerEndpoint,
  connectionFailure,
  processStartFailure,
  buildFailure,
  processExited,
  processFailure,
  reportLoadFailure,
  cleanupFailure,
}

/// A localization-neutral diagnostic for presentation by the launcher UI.
final class LauncherDiagnostic {
  LauncherDiagnostic(
    this.code, {
    Map<String, Object?> arguments = const <String, Object?>{},
  }) : arguments = UnmodifiableMapView<String, Object?>(
         Map<String, Object?>.of(arguments),
       );

  final LauncherErrorCode code;
  final Map<String, Object?> arguments;
}

/// Immutable view of the fields edited by the launcher UI.
final class LauncherSelectionSnapshot {
  LauncherSelectionSnapshot({
    required this.projectDirectory,
    required List<String> entrypoints,
    required this.entrypoint,
    required this.flutterExecutable,
    required List<({String id, String name})> devices,
    required this.deviceId,
    required Map<String, String> dartDefines,
    required this.restoring,
    required this.saving,
    required this.refreshingDevices,
  }) : entrypoints = List<String>.unmodifiable(entrypoints),
       devices = List<({String id, String name})>.unmodifiable(devices),
       dartDefines = UnmodifiableMapView<String, String>(
         Map<String, String>.of(dartDefines),
       );

  final String? projectDirectory;
  final List<String> entrypoints;
  final String? entrypoint;
  final String? flutterExecutable;
  final List<({String id, String name})> devices;
  final String? deviceId;
  final Map<String, String> dartDefines;
  final bool restoring;
  final bool saving;
  final bool refreshingDevices;
}

/// Immutable diagnostics and ownership for the current manager session.
final class LauncherSessionSnapshot {
  const LauncherSessionSnapshot({
    required this.sessionId,
    required this.managerPort,
    required this.workerUri,
    required this.reportPath,
    required this.external,
    required this.ownedPid,
  });

  final String sessionId;
  final int managerPort;
  final Uri? workerUri;
  final String reportPath;
  final bool external;
  final int? ownedPid;
}

/// Process boundary used by the controller and its deterministic tests.
abstract interface class LauncherWorkerProcess {
  Stream<WorkerEvent> get events;
  bool get owned;
  int? get ownedPid;
  int? get currentRunId;
  List<WorkerLogEvent> get logs;

  Future<void> start(
    LaunchConfiguration configuration, {
    required String sessionId,
    required int managerPort,
  });
  Future<void> stop();
  Future<void> dispose();
}

/// Production adapter over the completed machine-protocol process owner.
final class FlutterLauncherWorkerProcess implements LauncherWorkerProcess {
  FlutterLauncherWorkerProcess(FlutterWorkerProcess process)
    : _process = process;

  final FlutterWorkerProcess _process;

  @override
  Stream<WorkerEvent> get events => _process.events;
  @override
  bool get owned => _process.owned;
  @override
  int? get ownedPid => _process.ownedPid;
  @override
  int? get currentRunId => _process.currentRunId;
  @override
  List<WorkerLogEvent> get logs => _process.logs;
  @override
  Future<void> start(
    LaunchConfiguration configuration, {
    required String sessionId,
    required int managerPort,
  }) => _process.start(
    configuration,
    sessionId: sessionId,
    managerPort: managerPort,
  );
  @override
  Future<void> stop() => _process.stop();
  @override
  Future<void> dispose() => _process.dispose();
}

/// Coordinates selection, one owned launch, or one explicit external session.
///
/// Public mutation methods are intentionally UI-shaped: [restore],
/// [chooseProject], [chooseFlutterExecutable], [chooseEntrypoint],
/// [chooseDevice], [setDartDefines], [refreshDevices], [start], [stop],
/// [connectExternal], [reconnect], [loadReport], and [shutdown]. No method
/// auto-starts restored settings or auto-connects to a process not explicitly
/// supplied to [connectExternal].
final class LauncherController extends ChangeNotifier {
  LauncherController({
    required ProjectDiscovery discovery,
    required LauncherPreferences preferences,
    required LauncherWorkerProcess process,
    required LauncherSessionServices sessionServices,
    required String reportRootDirectory,
    this.readinessTimeout = const Duration(seconds: 30),
    String Function()? sessionIdFactory,
    DeviceDiscoveryQuery Function(String flutterExecutable)?
    deviceDiscoveryQueryFactory,
  }) : _discovery = discovery,
       _preferences = preferences,
       _process = process,
       _sessionServices = sessionServices,
       reportRootDirectory = p.normalize(p.absolute(reportRootDirectory)),
       _sessionIdFactory = sessionIdFactory ?? _newSessionId,
       _deviceDiscoveryQueryFactory =
           deviceDiscoveryQueryFactory ??
           ((executable) => startDeviceDiscoveryQuery(discovery, executable)) {
    if (readinessTimeout <= Duration.zero) {
      throw ArgumentError.value(
        readinessTimeout,
        'readinessTimeout',
        'must be positive',
      );
    }
    _eventSubscription = _process.events.listen((event) {
      unawaited(_handleWorkerEvent(event));
    });
  }

  final ProjectDiscovery _discovery;
  final LauncherPreferences _preferences;
  final LauncherWorkerProcess _process;
  final LauncherSessionServices _sessionServices;
  final String Function() _sessionIdFactory;
  final DeviceDiscoveryQuery Function(String flutterExecutable)
  _deviceDiscoveryQueryFactory;
  final String reportRootDirectory;
  final Duration readinessTimeout;
  late final StreamSubscription<WorkerEvent> _eventSubscription;

  LauncherState _state = LauncherState.idle;
  LauncherDiagnostic? _error;
  String? _projectDirectory;
  List<String> _entrypoints = const <String>[];
  String? _entrypoint;
  String? _flutterExecutable;
  List<({String id, String name})> _devices = const [];
  String? _deviceId;
  Map<String, String> _dartDefines = const <String, String>{};
  bool _restoring = false;
  bool _saving = false;
  int _pendingSaves = 0;
  bool _refreshingDevices = false;
  var _selectionGeneration = 0;
  var _operationGeneration = 0;
  Future<void> _saveTail = Future<void>.value();
  Future<bool>? _cleanupFuture;
  Completer<void>? _activeCompletion;
  bool _managedLaunchActive = false;
  LauncherSessionSnapshot? _session;
  int? _runtimeGeneration;
  int? _activeRunId;
  String? _startedAppId;
  WorkerDebugPortEvent? _debugEvent;
  Future<void>? _connectFuture;
  Future<void>? _shutdownFuture;
  DeviceDiscoveryQuery? _activeDeviceDiscovery;
  bool _failureInProgress = false;
  bool _connectionEventsAllowed = false;
  bool _loadingReport = false;
  bool _shutdownRequested = false;
  bool _shutdownComplete = false;
  bool _disposed = false;

  /// Current lifecycle state for progress and control enablement.
  LauncherState get state => _state;

  /// Latest localization-neutral failure or non-fatal diagnostic.
  LauncherDiagnostic? get error => _error;

  /// Immutable bounded process-log snapshot from the owned worker adapter.
  List<WorkerLogEvent> get logs =>
      List<WorkerLogEvent>.unmodifiable(_process.logs);

  /// Immutable current session diagnostics, or null when fully released.
  LauncherSessionSnapshot? get session {
    final value = _session;
    if (value == null) return null;
    return LauncherSessionSnapshot(
      sessionId: value.sessionId,
      managerPort: value.managerPort,
      workerUri: value.workerUri,
      reportPath: value.reportPath,
      external: value.external,
      ownedPid: _process.ownedPid,
    );
  }

  /// Immutable current selection and selection-progress snapshot.
  LauncherSelectionSnapshot get selection => LauncherSelectionSnapshot(
    projectDirectory: _projectDirectory,
    entrypoints: _entrypoints,
    entrypoint: _entrypoint,
    flutterExecutable: _flutterExecutable,
    devices: _devices,
    deviceId: _deviceId,
    dartDefines: _dartDefines,
    restoring: _restoring,
    saving: _saving,
    refreshingDevices: _refreshingDevices,
  );

  /// Whether this controller currently owns a live Flutter process.
  bool get ownsWorker => _process.owned || _ownsDiscoveryProcess;

  /// Whether Stop should be exposed for an owned worker.
  ///
  /// This is always false for explicit external connections.
  bool get canStop => _session?.external == false && _process.owned;

  /// Whether an in-progress managed validation/spawn/connect can be cancelled.
  bool get canCancelLaunch =>
      _managedLaunchActive &&
      _activeCompletion != null &&
      const <LauncherState>{
        LauncherState.validating,
        LauncherState.starting,
        LauncherState.connecting,
      }.contains(_state);

  /// Whether cleanup failed with session resources retained for retry.
  bool get canRetryCleanup =>
      _state == LauncherState.failed &&
      (_session != null || _ownsDiscoveryProcess);

  /// Whether a selection, launch, connection, or cleanup transition is active.
  bool get isBusy =>
      _loadingReport ||
      _restoring ||
      _saving ||
      _refreshingDevices ||
      _ownsDiscoveryProcess ||
      const <LauncherState>{
        LauncherState.validating,
        LauncherState.starting,
        LauncherState.connecting,
        LauncherState.stopping,
      }.contains(_state);

  /// Whether the active Dart-define editor may accept another preference value.
  ///
  /// Preference writes are serialized separately, so saving alone does not
  /// close the editor. Launch, restore, discovery, report, session, cleanup,
  /// and shutdown authority still do.
  bool get canEditDartDefines =>
      !_admissionClosed &&
      !_loadingReport &&
      !_restoring &&
      !_refreshingDevices &&
      !_ownsDiscoveryProcess &&
      !_process.owned &&
      _session == null &&
      _sessionServices.boundPort == null &&
      _activeCompletion == null &&
      _cleanupFuture == null &&
      !_failureInProgress &&
      !const <LauncherState>{
        LauncherState.validating,
        LauncherState.starting,
        LauncherState.connecting,
        LauncherState.running,
        LauncherState.stopping,
      }.contains(_state);

  /// Whether the current owned or explicit external session may reconnect.
  bool get canReconnect {
    final activeSession = _session;
    return !_admissionClosed &&
        !isBusy &&
        _activeCompletion == null &&
        _cleanupFuture == null &&
        !_failureInProgress &&
        activeSession != null &&
        activeSession.workerUri != null &&
        _runtimeGeneration != null &&
        _state == LauncherState.running &&
        _sessionServices.boundPort == activeSession.managerPort &&
        (activeSession.external ? !_process.owned : _process.owned);
  }

  /// Whether an offline report may be selected with no live session residue.
  bool get canLoadReport => !_loadingReport && _reportLoadAuthorityAvailable;

  /// Whether report selection or reading is currently in progress.
  bool get isLoadingReport => _loadingReport;

  /// Whether the current complete selection may start a managed session.
  bool get canStart =>
      !_admissionClosed &&
      !_restoring &&
      !isBusy &&
      _activeCompletion == null &&
      !_process.owned &&
      _session == null &&
      _sessionServices.boundPort == null &&
      _completeConfiguration() != null;

  /// Restores and re-discovers saved selections without starting or connecting.
  Future<void> restore() async {
    if (_admissionClosed ||
        _loadingReport ||
        _activeCompletion != null ||
        _process.owned ||
        _session != null) {
      _rejectBusy();
      return;
    }
    final generation = ++_selectionGeneration;
    _restoring = true;
    _state = LauncherState.validating;
    _error = null;
    _notify();
    try {
      final configuration = await _preferences.load();
      if (!_isCurrentSelection(generation)) return;
      final preferencesDiagnostic = _preferences.diagnostic;
      if (configuration == null) {
        if (preferencesDiagnostic != null) {
          _error = LauncherDiagnostic(
            LauncherErrorCode.restoreFailure,
            arguments: <String, Object?>{
              'code': preferencesDiagnostic.code,
              ...preferencesDiagnostic.arguments,
            },
          );
        }
        _state = LauncherState.idle;
        return;
      }

      final project = await _discovery.canonicalProjectDirectory(
        configuration.projectDirectory,
      );
      if (!_isCurrentSelection(generation)) return;
      final entrypoints = await _discovery.entrypoints(project);
      if (!_isCurrentSelection(generation)) return;
      final flutterExecutable = await _discovery.resolveFlutterExecutable(
        projectDirectory: project,
        explicitFlutterExecutable: configuration.flutterExecutable,
      );
      if (!_isCurrentSelection(generation)) return;
      final devices = await _discoverDevices(flutterExecutable, generation);
      if (!_isCurrentSelection(generation)) return;

      _projectDirectory = project;
      _entrypoints = entrypoints;
      _entrypoint = entrypoints.contains(configuration.entrypoint)
          ? configuration.entrypoint
          : null;
      _flutterExecutable = flutterExecutable;
      _devices = devices;
      _deviceId = devices.any((device) => device.id == configuration.deviceId)
          ? configuration.deviceId
          : null;
      _dartDefines = Map<String, String>.unmodifiable(
        configuration.dartDefines,
      );
      _state = LauncherState.idle;
    } on Object catch (exception) {
      if (_isCurrentSelection(generation)) {
        _error = _selectionError(exception, restoring: true);
        _state = LauncherState.failed;
      }
    } finally {
      if (_isCurrentSelection(generation)) {
        _restoring = false;
        _notify();
      }
    }
  }

  /// Selects and validates a project, then discovers entrypoints, SDK, devices.
  Future<void> chooseProject(String projectDirectory) async {
    if (!_canChangeSelection()) return;
    final generation = ++_selectionGeneration;
    _restoring = false;
    _refreshingDevices = false;
    _projectDirectory = projectDirectory;
    _entrypoints = const <String>[];
    _entrypoint = null;
    _devices = const [];
    _deviceId = null;
    _state = LauncherState.validating;
    _error = null;
    _notify();
    try {
      final project = await _discovery.canonicalProjectDirectory(
        projectDirectory,
      );
      final entrypoints = await _discovery.entrypoints(project);
      if (!_isCurrentSelection(generation)) return;
      _projectDirectory = project;
      _entrypoints = entrypoints;
      _notify();
      final flutterExecutable = await _discovery.resolveFlutterExecutable(
        projectDirectory: project,
        savedFlutterExecutable: _flutterExecutable,
      );
      if (!_isCurrentSelection(generation)) return;
      final devices = await _discoverDevices(flutterExecutable, generation);
      if (!_isCurrentSelection(generation)) return;
      _flutterExecutable = flutterExecutable;
      _devices = devices;
      _state = LauncherState.idle;
      if (entrypoints.isEmpty) {
        _error = LauncherDiagnostic(LauncherErrorCode.noEntrypoints);
      } else if (devices.isEmpty) {
        _error = LauncherDiagnostic(LauncherErrorCode.noDevices);
      }
    } on Object catch (exception) {
      if (_isCurrentSelection(generation)) {
        _error = _selectionError(exception);
        _state = LauncherState.failed;
      }
    } finally {
      if (_isCurrentSelection(generation)) _notify();
    }
  }

  /// Selects an explicit Flutter executable and refreshes its devices.
  Future<void> chooseFlutterExecutable(String flutterExecutable) async {
    if (!_canChangeSelection()) return;
    final project = _projectDirectory;
    if (project == null) {
      _error = LauncherDiagnostic(LauncherErrorCode.incompleteSelection);
      _state = LauncherState.failed;
      _notify();
      return;
    }
    final generation = ++_selectionGeneration;
    _restoring = false;
    _flutterExecutable = flutterExecutable;
    _devices = const [];
    _deviceId = null;
    _refreshingDevices = true;
    _state = LauncherState.validating;
    _error = null;
    _notify();
    try {
      final executable = await _discovery.resolveFlutterExecutable(
        projectDirectory: project,
        explicitFlutterExecutable: flutterExecutable,
      );
      if (!_isCurrentSelection(generation)) return;
      final devices = await _discoverDevices(executable, generation);
      if (!_isCurrentSelection(generation)) return;
      _flutterExecutable = executable;
      _devices = devices;
      _state = LauncherState.idle;
      if (devices.isEmpty) {
        _error = LauncherDiagnostic(LauncherErrorCode.noDevices);
      }
    } on Object catch (exception) {
      if (_isCurrentSelection(generation)) {
        _error = _selectionError(exception);
        _state = LauncherState.failed;
      }
    } finally {
      if (_isCurrentSelection(generation)) {
        _refreshingDevices = false;
        _notify();
      }
    }
  }

  /// Refreshes devices using the currently selected Flutter executable.
  Future<void> refreshDevices() async {
    if (!_canChangeSelection()) return;
    final executable = _flutterExecutable;
    if (executable == null) {
      _error = LauncherDiagnostic(LauncherErrorCode.invalidSdk);
      _state = LauncherState.failed;
      _notify();
      return;
    }
    await chooseFlutterExecutable(executable);
  }

  /// Selects a discovered entrypoint, or clears it with null.
  Future<void> chooseEntrypoint(String? entrypoint) async {
    if (!_canChangeSelection()) return;
    if (entrypoint != null && !_entrypoints.contains(entrypoint)) {
      _error = LauncherDiagnostic(
        LauncherErrorCode.invalidEntrypoint,
        arguments: <String, Object?>{'entrypoint': entrypoint},
      );
      _state = LauncherState.failed;
      _notify();
      return;
    }
    _entrypoint = entrypoint;
    _state = LauncherState.idle;
    _error = null;
    _notify();
    await _saveIfComplete();
  }

  /// Selects a discovered device ID, or clears it with null.
  Future<void> chooseDevice(String? deviceId) async {
    if (!_canChangeSelection()) return;
    if (deviceId != null && !_devices.any((device) => device.id == deviceId)) {
      _error = LauncherDiagnostic(
        LauncherErrorCode.noDevices,
        arguments: <String, Object?>{'deviceId': deviceId},
      );
      _state = LauncherState.failed;
      _notify();
      return;
    }
    _deviceId = deviceId;
    _state = LauncherState.idle;
    _error = null;
    _notify();
    await _saveIfComplete();
  }

  /// Replaces the literal user Dart-define map and persists complete settings.
  Future<void> setDartDefines(Map<String, String> dartDefines) async {
    if (!_canChangeSelection()) return;
    _dartDefines = Map<String, String>.unmodifiable(dartDefines);
    _state = LauncherState.idle;
    _error = null;
    _notify();
    await _saveIfComplete();
  }

  /// Starts a managed session and completes when it is running or failed.
  ///
  /// Source containment is revalidated before listener allocation or spawning.
  /// Build time has no blind timeout; [stop] remains available to cancel it.
  Future<void> start() async {
    if (_admissionClosed ||
        isBusy ||
        _activeCompletion != null ||
        _process.owned ||
        _session != null ||
        _sessionServices.boundPort != null) {
      _rejectBusy();
      return;
    }
    final selected = _completeConfiguration();
    if (selected == null) {
      _error = LauncherDiagnostic(LauncherErrorCode.incompleteSelection);
      _state = LauncherState.failed;
      _notify();
      return;
    }

    final operation = ++_operationGeneration;
    final completion = Completer<void>();
    _activeCompletion = completion;
    _managedLaunchActive = true;
    _resetActiveEventState();
    _connectionEventsAllowed = true;
    _state = LauncherState.validating;
    _error = null;
    _notify();
    try {
      final validatedEntrypoint = await _discovery.validateEntrypoint(
        selected.projectDirectory,
        selected.entrypoint,
      );
      if (!_isCurrentOperation(operation)) {
        _complete(completion);
        return;
      }
      final configuration = LaunchConfiguration(
        projectDirectory: selected.projectDirectory,
        entrypoint: validatedEntrypoint,
        flutterExecutable: selected.flutterExecutable,
        deviceId: selected.deviceId,
        dartDefines: selected.dartDefines,
      );
      await _saveConfiguration(configuration);
      if (!_isCurrentOperation(operation)) {
        _complete(completion);
        return;
      }

      final sessionId = _sessionIdFactory();
      final reportPath = p.join(reportRootDirectory, sessionId);
      final managerPort = await _sessionServices.bind(port: 0);
      if (!_isCurrentOperation(operation)) {
        await _cleanupResources();
        _complete(completion);
        return;
      }
      if (managerPort < 1 || managerPort > 65535) {
        throw _LauncherException(
          LauncherErrorCode.invalidManagerPort,
          <String, Object?>{'port': managerPort},
        );
      }
      _session = LauncherSessionSnapshot(
        sessionId: sessionId,
        managerPort: managerPort,
        workerUri: null,
        reportPath: reportPath,
        external: false,
        ownedPid: null,
      );
      _runtimeGeneration = await _sessionServices.prepareSession(
        reportPath: reportPath,
      );
      if (!_isCurrentOperation(operation)) {
        await _cleanupResources();
        _complete(completion);
        return;
      }
      _state = LauncherState.starting;
      _notify();
      await _process.start(
        configuration,
        sessionId: sessionId,
        managerPort: managerPort,
      );
      if (!_isCurrentOperation(operation)) {
        await _cleanupResources();
        _complete(completion);
        return;
      }
      _activeRunId = _process.currentRunId;
      _notify();
      await completion.future;
    } on Object catch (exception) {
      if (_isCurrentOperation(operation)) {
        await _failActive(_operationError(exception, managedBind: true));
      }
      _complete(completion);
    } finally {
      if (identical(_activeCompletion, completion) && completion.isCompleted) {
        _activeCompletion = null;
        _managedLaunchActive = false;
      }
    }
  }

  /// Explicitly binds [managerPort] before connecting to the full [workerUri].
  ///
  /// The URI must be a valid loopback WebSocket endpoint ending in `/ws`. This
  /// includes the conventional unauthenticated `/ws` compatibility endpoint.
  /// This method never claims ownership of, signals, or stops the external
  /// worker process.
  Future<void> connectExternal({
    required int managerPort,
    required Uri workerUri,
  }) async {
    if (_admissionClosed ||
        _activeCompletion != null ||
        _process.owned ||
        _sessionServices.boundPort != null ||
        isBusy ||
        _state == LauncherState.running) {
      _rejectBusy();
      return;
    }
    if (managerPort < 1 || managerPort > 65535) {
      _error = LauncherDiagnostic(
        LauncherErrorCode.invalidManagerPort,
        arguments: <String, Object?>{'port': managerPort},
      );
      _state = LauncherState.failed;
      _notify();
      return;
    }
    if (!_isValidLoopbackWebSocket(workerUri)) {
      _error = LauncherDiagnostic(
        LauncherErrorCode.invalidWorkerEndpoint,
        arguments: <String, Object?>{'workerUri': workerUri},
      );
      _state = LauncherState.failed;
      _notify();
      return;
    }

    final operation = ++_operationGeneration;
    final completion = Completer<void>();
    _activeCompletion = completion;
    _managedLaunchActive = false;
    _state = LauncherState.connecting;
    _error = null;
    _notify();
    try {
      final actualPort = await _sessionServices.bind(port: managerPort);
      if (!_isCurrentOperation(operation)) {
        await _cleanupResources();
        _complete(completion);
        return;
      }
      if (actualPort != managerPort) {
        throw _LauncherException(
          LauncherErrorCode.portConflict,
          <String, Object?>{'port': managerPort, 'actualPort': actualPort},
        );
      }
      final sessionId = _sessionIdFactory();
      final reportPath = p.join(reportRootDirectory, sessionId);
      _session = LauncherSessionSnapshot(
        sessionId: sessionId,
        managerPort: actualPort,
        workerUri: workerUri,
        reportPath: reportPath,
        external: true,
        ownedPid: null,
      );
      final runtimeGeneration = await _sessionServices.prepareSession(
        reportPath: reportPath,
      );
      _runtimeGeneration = runtimeGeneration;
      if (!_isCurrentOperation(operation)) {
        await _cleanupResources();
        _complete(completion);
        return;
      }
      await _connectUntilReady(
        operation: operation,
        uri: workerUri,
        generation: runtimeGeneration,
      );
      if (!_isCurrentOperation(operation)) {
        await _cleanupResources();
        _complete(completion);
        return;
      }
      if (!_sessionServices.connected) {
        throw _LauncherException(LauncherErrorCode.connectionFailure);
      }
      _state = LauncherState.running;
      _notify();
      _complete(completion);
    } on Object catch (exception) {
      if (_isCurrentOperation(operation)) {
        await _failActive(
          _operationError(exception, externalPort: managerPort),
        );
      }
      _complete(completion);
    } finally {
      if (identical(_activeCompletion, completion) && completion.isCompleted) {
        _activeCompletion = null;
      }
    }
  }

  /// Reconnects only the current session's complete saved worker URI.
  ///
  /// The existing listener, runtime generation, session identity, ownership,
  /// and report path remain authoritative. No listener is rebound and no
  /// default worker endpoint is consulted.
  Future<void> reconnect() async {
    if (!canReconnect) {
      _rejectBusy();
      return;
    }
    final activeSession = _session!;
    final workerUri = activeSession.workerUri!;
    final runtimeGeneration = _runtimeGeneration!;
    final operation = ++_operationGeneration;
    final completion = Completer<void>();
    _activeCompletion = completion;
    _managedLaunchActive = false;
    _connectionEventsAllowed = false;
    _state = LauncherState.connecting;
    _error = null;
    _notify();
    try {
      await _connectUntilReady(
        operation: operation,
        uri: workerUri,
        generation: runtimeGeneration,
      );
      if (!_isCurrentReconnect(
        operation: operation,
        session: activeSession,
        runtimeGeneration: runtimeGeneration,
      )) {
        _complete(completion);
        return;
      }
      if (!_sessionServices.connected) {
        throw _LauncherException(LauncherErrorCode.connectionFailure);
      }
      _state = LauncherState.running;
      _error = null;
      _notify();
      _complete(completion);
    } on Object catch (exception) {
      if (_isCurrentReconnect(
        operation: operation,
        session: activeSession,
        runtimeGeneration: runtimeGeneration,
      )) {
        await _failActive(_operationError(exception));
      }
      _complete(completion);
    } finally {
      if (identical(_activeCompletion, completion)) {
        _activeCompletion = null;
      }
    }
  }

  /// Selects and reads one offline report while session admission is closed.
  ///
  /// A null path is cancellation. Picker and reader errors are converted to a
  /// localization-neutral diagnostic and are never rethrown to the UI.
  Future<void> loadReport({
    required Future<String?> Function() choosePath,
    required Future<void> Function(String path, bool Function() isCurrent)
    readReport,
  }) async {
    if (!canLoadReport) {
      _rejectBusy();
      return;
    }
    final operation = ++_operationGeneration;
    _loadingReport = true;
    _notify();
    String? path;
    try {
      path = await choosePath();
      if (!_isCurrentReportLoad(operation) || path == null) return;
      await readReport(path, () => _isCurrentReportLoad(operation));
    } on Object catch (exception) {
      if (_isCurrentReportLoad(operation)) {
        _error = LauncherDiagnostic(
          LauncherErrorCode.reportLoadFailure,
          arguments: <String, Object?>{
            'stage': path == null ? 'choosePath' : 'readReport',
            'path': ?path,
            'error': exception,
          },
        );
        _state = LauncherState.failed;
      }
    } finally {
      _loadingReport = false;
      _notify();
    }
  }

  /// Stops only an owned process, then releases this controller's VM/listener.
  ///
  /// For external sessions it only disconnects and releases the local listener.
  /// A cleanup failure retains diagnostics/resources so this can be retried.
  Future<void> stop() async {
    _connectionEventsAllowed = false;
    if (_state == LauncherState.stopping) {
      await _cleanupFuture;
      return;
    }
    if (_session == null &&
        !_process.owned &&
        _sessionServices.boundPort == null &&
        _activeCompletion == null &&
        _activeDeviceDiscovery == null) {
      _state = LauncherState.idle;
      _notify();
      return;
    }
    ++_operationGeneration;
    ++_selectionGeneration;
    _restoring = false;
    _refreshingDevices = false;
    _activeRunId = null;
    _connectFuture = null;
    _state = LauncherState.stopping;
    _notify();
    final cleaned = await _cleanupResources();
    if (cleaned) {
      _state = LauncherState.idle;
      _error = null;
      _session = null;
      _runtimeGeneration = null;
      _resetActiveEventState();
    } else {
      _state = LauncherState.failed;
      _error ??= LauncherDiagnostic(
        LauncherErrorCode.cleanupFailure,
        arguments: <String, Object?>{'pid': _process.ownedPid},
      );
    }
    final completion = _activeCompletion;
    if (completion != null) {
      _complete(completion);
      if (identical(_activeCompletion, completion)) {
        _activeCompletion = null;
        _managedLaunchActive = false;
      }
    }
    _notify();
  }

  /// Performs [stop] and disposes process/event resources when cleanup succeeds.
  Future<void> shutdown() {
    if (!_shutdownRequested) {
      _shutdownRequested = true;
      _connectionEventsAllowed = false;
      ++_operationGeneration;
      ++_selectionGeneration;
      _restoring = false;
      _refreshingDevices = false;
      _notify();
    }
    if (_shutdownComplete) return Future<void>.value();
    final active = _shutdownFuture;
    if (active != null) return active;
    late final Future<void> tracked;
    tracked = _performShutdown().whenComplete(() {
      if (identical(_shutdownFuture, tracked)) _shutdownFuture = null;
    });
    _shutdownFuture = tracked;
    return tracked;
  }

  Future<void> _performShutdown() async {
    try {
      if (!await _cancelDeviceDiscovery()) {
        _state = LauncherState.failed;
        _error = LauncherDiagnostic(
          LauncherErrorCode.cleanupFailure,
          arguments: <String, Object?>{
            'pid': _activeDeviceDiscovery?.ownedPid,
            'resource': 'deviceDiscovery',
            'terminated': false,
          },
        );
        _notify();
        return;
      }
      await stop();
      if (_state == LauncherState.failed ||
          _ownsDiscoveryProcess ||
          _process.owned ||
          _session != null ||
          _sessionServices.boundPort != null) {
        return;
      }
      await _eventSubscription.cancel();
      await _process.dispose();
      _shutdownComplete = true;
      _state = LauncherState.idle;
      _error = null;
      _notify();
    } on Object catch (exception) {
      _state = LauncherState.failed;
      _error = LauncherDiagnostic(
        LauncherErrorCode.cleanupFailure,
        arguments: <String, Object?>{
          'pid': _process.ownedPid,
          'error': exception,
        },
      );
      _notify();
    }
  }

  Future<void> _handleWorkerEvent(WorkerEvent event) async {
    final activeSession = _session;
    if (activeSession == null ||
        activeSession.external ||
        event.sessionId != activeSession.sessionId) {
      return;
    }
    final expectedRun = _activeRunId ?? _process.currentRunId;
    if (expectedRun == null || event.runId != expectedRun) return;
    _activeRunId ??= expectedRun;

    switch (event) {
      case WorkerLogEvent():
        _notify();
      case WorkerAppStartedEvent():
        if (!_connectionEventsAllowed ||
            (_state != LauncherState.starting &&
                _state != LauncherState.connecting)) {
          return;
        }
        _startedAppId = event.appId;
        await _maybeConnectOwned();
      case WorkerDebugPortEvent():
        if (!_connectionEventsAllowed ||
            (_state != LauncherState.starting &&
                _state != LauncherState.connecting)) {
          return;
        }
        _debugEvent = event;
        await _maybeConnectOwned();
      case WorkerFailureEvent():
        if (_state != LauncherState.failed &&
            _state != LauncherState.stopping) {
          await _failActive(_workerError(event));
        }
      case WorkerExitedEvent():
        if (_state != LauncherState.failed &&
            _state != LauncherState.stopping) {
          await _failActive(
            LauncherDiagnostic(
              LauncherErrorCode.processExited,
              arguments: <String, Object?>{'exitCode': event.exitCode},
            ),
          );
        }
    }
  }

  Future<void> _maybeConnectOwned() {
    final existing = _connectFuture;
    if (existing != null) return existing;
    final debugEvent = _debugEvent;
    final session = _session;
    final runtimeGeneration = _runtimeGeneration;
    if (!_connectionEventsAllowed ||
        debugEvent == null ||
        _startedAppId == null ||
        debugEvent.appId != _startedAppId ||
        session == null ||
        runtimeGeneration == null) {
      return Future<void>.value();
    }
    final operation = _operationGeneration;
    final future = _connectOwned(
      operation: operation,
      event: debugEvent,
      runtimeGeneration: runtimeGeneration,
    );
    _connectFuture = future;
    return future;
  }

  Future<void> _connectOwned({
    required int operation,
    required WorkerDebugPortEvent event,
    required int runtimeGeneration,
  }) async {
    final uri = event.vmServiceUri;
    if (!_isAuthenticatedLoopbackWebSocket(uri)) {
      await _failActive(
        LauncherDiagnostic(
          LauncherErrorCode.invalidWorkerEndpoint,
          arguments: <String, Object?>{'workerUri': uri},
        ),
      );
      return;
    }
    final activeSession = _session!;
    _session = LauncherSessionSnapshot(
      sessionId: activeSession.sessionId,
      managerPort: activeSession.managerPort,
      workerUri: uri,
      reportPath: activeSession.reportPath,
      external: false,
      ownedPid: _process.ownedPid,
    );
    _state = LauncherState.connecting;
    _notify();
    try {
      await _connectUntilReady(
        operation: operation,
        uri: uri,
        generation: runtimeGeneration,
      );
      if (!_isCurrentOperation(operation)) return;
      if (!_sessionServices.connected) {
        throw _LauncherException(LauncherErrorCode.connectionFailure);
      }
      _state = LauncherState.running;
      _error = null;
      _notify();
      final completion = _activeCompletion;
      if (completion != null) _complete(completion);
    } on Object catch (exception) {
      if (_isCurrentOperation(operation)) {
        await _failActive(_operationError(exception));
      }
    }
  }

  Future<void> _connectUntilReady({
    required int operation,
    required Uri uri,
    required int generation,
  }) async {
    final elapsed = Stopwatch()..start();
    final connection = () async {
      await _sessionServices.connect(uri: uri);
      if (!_isCurrentOperation(operation)) return;
      final remaining = readinessTimeout - elapsed.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException(null, readinessTimeout);
      }
      await _sessionServices.waitUntilReady(
        generation: generation,
        timeout: remaining,
      );
    }();
    await connection.timeout(readinessTimeout);
  }

  Future<void> _failActive(LauncherDiagnostic diagnostic) async {
    if (_failureInProgress) return;
    _failureInProgress = true;
    _connectionEventsAllowed = false;
    ++_operationGeneration;
    _activeRunId = null;
    _connectFuture = null;
    _state = LauncherState.stopping;
    _error = diagnostic;
    _notify();
    try {
      final cleaned = await _cleanupResources();
      if (cleaned) {
        _error = diagnostic;
        _session = null;
        _runtimeGeneration = null;
      } else {
        _error = LauncherDiagnostic(
          LauncherErrorCode.cleanupFailure,
          arguments: <String, Object?>{
            'pid': _process.ownedPid,
            'cause': diagnostic.code,
            ...diagnostic.arguments,
          },
        );
      }
      _state = LauncherState.failed;
      final completion = _activeCompletion;
      if (completion != null) _complete(completion);
      _notify();
    } finally {
      _failureInProgress = false;
    }
  }

  Future<bool> _cleanupResources() {
    final current = _cleanupFuture;
    if (current != null) return current;
    final future = _cleanupResourcesInner();
    _cleanupFuture = future;
    return future.whenComplete(() {
      if (identical(_cleanupFuture, future)) _cleanupFuture = null;
    });
  }

  Future<bool> _cleanupResourcesInner() async {
    Object? cleanupError;
    bool discoveryCleaned;
    try {
      discoveryCleaned = await _cancelDeviceDiscovery();
    } on Object catch (exception) {
      cleanupError = exception;
      discoveryCleaned = false;
    }
    if (!discoveryCleaned) {
      _error = LauncherDiagnostic(
        LauncherErrorCode.cleanupFailure,
        arguments: <String, Object?>{
          'pid': _activeDeviceDiscovery?.ownedPid,
          'resource': 'deviceDiscovery',
          'terminated': false,
          'error': ?cleanupError,
        },
      );
      return false;
    }
    if (_process.owned ||
        (_session?.external == false && _activeCompletion != null)) {
      try {
        await _process.stop();
      } on Object catch (exception) {
        cleanupError = exception;
      }
    }
    if (_process.owned) {
      _error = LauncherDiagnostic(
        LauncherErrorCode.cleanupFailure,
        arguments: <String, Object?>{
          'pid': _process.ownedPid,
          'error': ?cleanupError,
        },
      );
      return false;
    }

    try {
      await _sessionServices.disconnect();
    } on Object catch (exception) {
      cleanupError ??= exception;
    }
    try {
      await _sessionServices.shutdownListener();
    } on Object catch (exception) {
      cleanupError ??= exception;
    }
    try {
      await _sessionServices.restoreGlobalConfiguration();
    } on Object catch (exception) {
      cleanupError ??= exception;
    }
    if (cleanupError != null) {
      _error = LauncherDiagnostic(
        LauncherErrorCode.cleanupFailure,
        arguments: <String, Object?>{'error': cleanupError},
      );
      return false;
    }
    return true;
  }

  Future<List<({String id, String name})>> _discoverDevices(
    String flutterExecutable,
    int generation,
  ) async {
    if (!_isCurrentSelection(generation)) return const [];
    final query = _deviceDiscoveryQueryFactory(flutterExecutable);
    _activeDeviceDiscovery = query;
    try {
      return await query.result;
    } finally {
      if (identical(_activeDeviceDiscovery, query) && !query.ownsProcess) {
        _activeDeviceDiscovery = null;
      }
    }
  }

  Future<bool> _cancelDeviceDiscovery() async {
    final query = _activeDeviceDiscovery;
    if (query == null) return true;
    final cleaned = await query.cancel();
    if (cleaned && identical(_activeDeviceDiscovery, query)) {
      _activeDeviceDiscovery = null;
    }
    return cleaned;
  }

  bool _canChangeSelection() {
    if (_admissionClosed ||
        _loadingReport ||
        _activeCompletion != null ||
        _ownsDiscoveryProcess ||
        _process.owned ||
        _session != null ||
        _sessionServices.boundPort != null ||
        _state == LauncherState.running ||
        _state == LauncherState.stopping) {
      _rejectBusy();
      return false;
    }
    return true;
  }

  bool get _admissionClosed => _shutdownRequested || _disposed;

  bool get _ownsDiscoveryProcess =>
      _activeDeviceDiscovery?.ownsProcess ?? false;

  bool _isCurrentSelection(int generation) =>
      !_admissionClosed && generation == _selectionGeneration;
  bool _isCurrentOperation(int generation) =>
      !_admissionClosed && generation == _operationGeneration;

  bool _isCurrentReconnect({
    required int operation,
    required LauncherSessionSnapshot session,
    required int runtimeGeneration,
  }) =>
      _isCurrentOperation(operation) &&
      identical(_session, session) &&
      _runtimeGeneration == runtimeGeneration;

  bool get _reportLoadAuthorityAvailable =>
      !_admissionClosed &&
      !isBusy &&
      _activeCompletion == null &&
      _cleanupFuture == null &&
      !_failureInProgress &&
      !_process.owned &&
      _session == null &&
      _sessionServices.boundPort == null &&
      !_sessionServices.connected;

  bool _isCurrentReportLoad(int operation) =>
      _loadingReport &&
      _isCurrentOperation(operation) &&
      _activeCompletion == null &&
      _cleanupFuture == null &&
      !_failureInProgress &&
      !_process.owned &&
      _session == null &&
      _sessionServices.boundPort == null &&
      !_sessionServices.connected;

  LaunchConfiguration? _completeConfiguration() {
    final project = _projectDirectory;
    final entrypoint = _entrypoint;
    final executable = _flutterExecutable;
    final device = _deviceId;
    if (project == null ||
        entrypoint == null ||
        executable == null ||
        device == null) {
      return null;
    }
    try {
      return LaunchConfiguration(
        projectDirectory: project,
        entrypoint: entrypoint,
        flutterExecutable: executable,
        deviceId: device,
        dartDefines: _dartDefines,
      );
    } on FormatException {
      return null;
    }
  }

  Future<void> _saveIfComplete() async {
    final configuration = _completeConfiguration();
    if (configuration != null) await _saveConfiguration(configuration);
  }

  Future<void> _saveConfiguration(LaunchConfiguration configuration) async {
    _pendingSaves++;
    _saving = true;
    _notify();
    final operation = _saveTail.then((_) => _preferences.save(configuration));
    _saveTail = operation.onError((_, _) {});
    try {
      await operation;
    } on Object catch (exception) {
      _error = LauncherDiagnostic(
        LauncherErrorCode.saveFailure,
        arguments: <String, Object?>{'error': exception},
      );
    } finally {
      _pendingSaves--;
      _saving = _pendingSaves > 0;
      _notify();
    }
  }

  LauncherDiagnostic _selectionError(
    Object exception, {
    bool restoring = false,
  }) {
    if (exception is ProjectDiscoveryException) {
      final code = switch (exception.code) {
        ProjectDiscoveryError.invalidProject =>
          LauncherErrorCode.invalidProject,
        ProjectDiscoveryError.invalidEntrypoint ||
        ProjectDiscoveryError.entrypointOutsideProject =>
          LauncherErrorCode.invalidEntrypoint,
        ProjectDiscoveryError.invalidFlutterExecutable =>
          LauncherErrorCode.invalidSdk,
        ProjectDiscoveryError.deviceDiscoveryFailed ||
        ProjectDiscoveryError.invalidDeviceOutput =>
          LauncherErrorCode.deviceDiscoveryFailure,
      };
      return LauncherDiagnostic(code, arguments: exception.details);
    }
    if (exception is FlutterSdkNotFoundException) {
      return LauncherDiagnostic(
        LauncherErrorCode.invalidSdk,
        arguments: <String, Object?>{
          'attemptedPaths': exception.attemptedPaths,
        },
      );
    }
    return LauncherDiagnostic(
      restoring
          ? LauncherErrorCode.restoreFailure
          : LauncherErrorCode.invalidProject,
      arguments: <String, Object?>{'error': exception},
    );
  }

  LauncherDiagnostic _operationError(
    Object exception, {
    bool managedBind = false,
    int? externalPort,
  }) {
    if (exception is _LauncherException) {
      return LauncherDiagnostic(exception.code, arguments: exception.arguments);
    }
    if (exception is ProjectDiscoveryException ||
        exception is FlutterSdkNotFoundException) {
      return _selectionError(exception);
    }
    if (exception is WorkerProcessException) {
      return _workerExceptionError(exception);
    }
    if (externalPort != null && _session == null) {
      return LauncherDiagnostic(
        LauncherErrorCode.portConflict,
        arguments: <String, Object?>{'port': externalPort, 'error': exception},
      );
    }
    if (managedBind && _session == null) {
      return LauncherDiagnostic(
        LauncherErrorCode.bindFailure,
        arguments: <String, Object?>{'error': exception},
      );
    }
    return LauncherDiagnostic(
      LauncherErrorCode.connectionFailure,
      arguments: <String, Object?>{'error': exception},
    );
  }

  LauncherDiagnostic _workerExceptionError(WorkerProcessException exception) =>
      LauncherDiagnostic(
        _launcherCodeForWorkerFailure(exception.code),
        arguments: exception.details,
      );

  LauncherDiagnostic _workerError(WorkerFailureEvent event) =>
      LauncherDiagnostic(
        _launcherCodeForWorkerFailure(event.code),
        arguments: event.details,
      );

  LauncherErrorCode _launcherCodeForWorkerFailure(WorkerFailureCode code) =>
      switch (code) {
        WorkerFailureCode.invalidManagerPort =>
          LauncherErrorCode.invalidManagerPort,
        WorkerFailureCode.reservedDartDefine =>
          LauncherErrorCode.reservedDefine,
        WorkerFailureCode.alreadyRunning => LauncherErrorCode.busy,
        WorkerFailureCode.spawnFailed => LauncherErrorCode.processStartFailure,
        WorkerFailureCode.buildFailed => LauncherErrorCode.buildFailure,
        WorkerFailureCode.exitedEarly ||
        WorkerFailureCode.unexpectedExit => LauncherErrorCode.processExited,
        WorkerFailureCode.invalidSessionId ||
        WorkerFailureCode.disposed ||
        WorkerFailureCode.unsupportedProtocol ||
        WorkerFailureCode.protocolViolation ||
        WorkerFailureCode.stopRequestFailed ||
        WorkerFailureCode.stopTimedOut => LauncherErrorCode.processFailure,
      };

  void _rejectBusy() {
    _error = LauncherDiagnostic(
      LauncherErrorCode.busy,
      arguments: <String, Object?>{'state': _state, 'pid': _process.ownedPid},
    );
    _notify();
  }

  void _resetActiveEventState() {
    _connectionEventsAllowed = false;
    _activeRunId = null;
    _startedAppId = null;
    _debugEvent = null;
    _connectFuture = null;
  }

  void _complete(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    ++_operationGeneration;
    ++_selectionGeneration;
    final discovery = _activeDeviceDiscovery;
    if (discovery != null) unawaited(discovery.cancel());
    unawaited(_eventSubscription.cancel());
    if (!_process.owned) unawaited(_process.dispose());
    super.dispose();
  }

  static String _newSessionId() {
    final random = Random.secure();
    final suffix = List<int>.generate(
      8,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
    return 'gui-${DateTime.now().toUtc().microsecondsSinceEpoch}-$suffix';
  }
}

final class _LauncherException implements Exception {
  _LauncherException(
    this.code, [
    Map<String, Object?> arguments = const <String, Object?>{},
  ]) : arguments = Map<String, Object?>.unmodifiable(arguments);

  final LauncherErrorCode code;
  final Map<String, Object?> arguments;
}

bool _isValidLoopbackWebSocket(Uri uri) {
  if ((uri.scheme != 'ws' && uri.scheme != 'wss') ||
      !uri.hasAuthority ||
      !uri.hasPort ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.path.isEmpty ||
      uri.path == '/' ||
      !uri.path.endsWith('/ws')) {
    return false;
  }
  if (uri.host.toLowerCase() == 'localhost') return true;
  return InternetAddress.tryParse(uri.host)?.isLoopback ?? false;
}

bool _isAuthenticatedLoopbackWebSocket(Uri uri) =>
    _isValidLoopbackWebSocket(uri) && uri.path != '/ws';
