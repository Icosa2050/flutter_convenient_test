import 'dart:async';

import 'package:convenient_test_manager/launcher/flutter_worker_process.dart';
import 'package:convenient_test_manager/launcher/launch_configuration.dart';
import 'package:convenient_test_manager/launcher/launcher_controller.dart';
import 'package:convenient_test_manager/launcher/launcher_preferences.dart';
import 'package:convenient_test_manager/launcher/launcher_session_services.dart';
import 'package:convenient_test_manager/launcher/project_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LauncherController selections', () {
    test(
      'restores immutable selections without starting or connecting',
      () async {
        final saved = _configuration(project: '/projects/restored');
        final preferences = _FakePreferences()..value = saved;
        final fixture = _Fixture(preferences: preferences);

        await fixture.controller.restore();

        expect(fixture.controller.state, LauncherState.idle);
        expect(
          fixture.controller.selection.projectDirectory,
          saved.projectDirectory,
        );
        expect(fixture.controller.selection.entrypoint, saved.entrypoint);
        expect(
          fixture.controller.selection.flutterExecutable,
          saved.flutterExecutable,
        );
        expect(fixture.controller.selection.deviceId, saved.deviceId);
        expect(fixture.controller.selection.dartDefines, saved.dartDefines);
        expect(fixture.worker.startCalls, 0);
        expect(fixture.services.connectUris, isEmpty);
        expect(
          () => fixture.controller.selection.dartDefines['NEW'] = 'value',
          throwsUnsupportedError,
        );
        expect(
          () => fixture.controller.selection.entrypoints.add('other.dart'),
          throwsUnsupportedError,
        );
      },
    );

    test('a stale project result cannot overwrite the newer project', () async {
      final first = Completer<String>();
      final discovery = _FakeDiscovery()
        ..canonicalProject = (path) => path == '/projects/slow'
            ? first.future
            : Future<String>.value(path);
      final fixture = _Fixture(discovery: discovery);

      final slow = fixture.controller.chooseProject('/projects/slow');
      await Future<void>.delayed(Duration.zero);
      await fixture.controller.chooseProject('/projects/new');
      first.complete('/projects/slow');
      await slow;

      expect(fixture.controller.selection.projectDirectory, '/projects/new');
      expect(fixture.controller.selection.entrypoints, [
        'integration_test/example_test.dart',
      ]);
    });

    test('changing SDK invalidates stale device discovery', () async {
      final slowDevices = Completer<List<({String id, String name})>>();
      final discovery = _FakeDiscovery()
        ..discoverDevices = (sdk) => sdk == '/sdk/slow'
            ? slowDevices.future
            : Future.value([(id: 'new-device', name: 'New device')]);
      final fixture = _Fixture(discovery: discovery);
      await fixture.controller.chooseProject('/projects/app');

      final slow = fixture.controller.chooseFlutterExecutable('/sdk/slow');
      await Future<void>.delayed(Duration.zero);
      await fixture.controller.chooseFlutterExecutable('/sdk/new');
      slowDevices.complete([(id: 'old-device', name: 'Old device')]);
      await slow;

      expect(fixture.controller.selection.flutterExecutable, '/sdk/new');
      expect(fixture.controller.selection.devices.single.id, 'new-device');
      expect(fixture.controller.selection.deviceId, isNull);
    });

    test(
      'missing SDK recovery preserves discovered entrypoints without reselecting the project',
      () async {
        final discovery = _FakeDiscovery()
          ..resolveSdk = (project, explicit, saved) {
            if (explicit == null) {
              throw const FlutterSdkNotFoundException(['/missing/flutter']);
            }
            return Future.value(explicit);
          };
        final fixture = _Fixture(discovery: discovery);

        await fixture.controller.chooseProject('/projects/app');

        expect(fixture.controller.state, LauncherState.failed);
        expect(fixture.controller.error?.code, LauncherErrorCode.invalidSdk);
        expect(fixture.controller.selection.projectDirectory, '/projects/app');
        expect(fixture.controller.selection.entrypoints, [
          'integration_test/example_test.dart',
        ]);

        await fixture.controller.chooseFlutterExecutable('/real/flutter');
        await fixture.controller.chooseEntrypoint(
          'integration_test/example_test.dart',
        );
        await fixture.controller.chooseDevice('device-1');

        expect(fixture.controller.selection.flutterExecutable, '/real/flutter');
        expect(fixture.controller.canStart, isTrue);
      },
    );

    test(
      'device discovery recovery preserves discovered entrypoints without reselecting the project',
      () async {
        var deviceDiscoveryCalls = 0;
        final discovery = _FakeDiscovery()
          ..discoverDevices = (_) {
            deviceDiscoveryCalls += 1;
            if (deviceDiscoveryCalls == 1) {
              throw const ProjectDiscoveryException(
                ProjectDiscoveryError.deviceDiscoveryFailed,
              );
            }
            return Future.value([(id: 'device-1', name: 'Device one')]);
          };
        final fixture = _Fixture(discovery: discovery);

        await fixture.controller.chooseProject('/projects/app');

        expect(fixture.controller.state, LauncherState.failed);
        expect(
          fixture.controller.error?.code,
          LauncherErrorCode.deviceDiscoveryFailure,
        );
        expect(fixture.controller.selection.entrypoints, [
          'integration_test/example_test.dart',
        ]);

        await fixture.controller.chooseFlutterExecutable('/real/flutter');
        await fixture.controller.chooseEntrypoint(
          'integration_test/example_test.dart',
        );
        await fixture.controller.chooseDevice('device-1');

        expect(fixture.controller.canStart, isTrue);
      },
    );

    test('shutdown awaits active restore discovery cleanup', () async {
      final preferences = _FakePreferences()
        ..value = _configuration(project: '/projects/restored');
      final cancelGate = Completer<bool>();
      final query = _FakeDeviceDiscoveryQuery.pending(cancelGate: cancelGate);
      var queryStarts = 0;
      final fixture = _Fixture(
        preferences: preferences,
        deviceDiscoveryQueryFactory: (_) {
          queryStarts++;
          return query;
        },
      );

      final restore = fixture.controller.restore();
      await _eventually(() => queryStarts == 1);
      var shutdownCompleted = false;
      final shutdown = fixture.controller.shutdown().whenComplete(
        () => shutdownCompleted = true,
      );
      await _eventually(() => query.cancelCalls == 1);

      expect(fixture.controller.selection.restoring, isFalse);
      expect(fixture.controller.canStart, isFalse);
      expect(shutdownCompleted, isFalse);
      expect(fixture.worker.disposeCalls, 0);

      cancelGate.complete(true);
      await shutdown;
      await restore;

      expect(query.ownsProcess, isFalse);
      expect(fixture.controller.ownsWorker, isFalse);
      expect(fixture.worker.disposeCalls, 1);
      expect(fixture.controller.state, LauncherState.idle);
    });

    test('shutdown cancels an active refresh discovery', () async {
      final activeQuery = _FakeDeviceDiscoveryQuery.pending();
      var queryStarts = 0;
      final fixture = _Fixture(
        deviceDiscoveryQueryFactory: (_) {
          queryStarts++;
          return queryStarts == 1
              ? _FakeDeviceDiscoveryQuery.completed()
              : activeQuery;
        },
      );
      await _selectValid(fixture.controller);

      final refresh = fixture.controller.refreshDevices();
      await _eventually(() => queryStarts == 2);
      await fixture.controller.shutdown();
      await refresh;

      expect(activeQuery.cancelCalls, 1);
      expect(activeQuery.ownsProcess, isFalse);
      expect(fixture.controller.selection.refreshingDevices, isFalse);
      expect(fixture.controller.ownsWorker, isFalse);
      expect(fixture.worker.disposeCalls, 1);
    });

    test('late SDK resolution after shutdown cannot start discovery', () async {
      final sdkGate = Completer<String>();
      var sdkResolutions = 0;
      var queryStarts = 0;
      final discovery = _FakeDiscovery()
        ..resolveSdk = (_, _, _) {
          sdkResolutions++;
          return sdkGate.future;
        };
      final preferences = _FakePreferences()..value = _configuration();
      final fixture = _Fixture(
        discovery: discovery,
        preferences: preferences,
        deviceDiscoveryQueryFactory: (_) {
          queryStarts++;
          return _FakeDeviceDiscoveryQuery.completed();
        },
      );

      final restore = fixture.controller.restore();
      await _eventually(() => sdkResolutions == 1);
      await fixture.controller.shutdown();
      sdkGate.complete('/sdk/late');
      await restore;

      expect(queryStarts, 0);
      expect(fixture.controller.selection.restoring, isFalse);
      expect(fixture.controller.ownsWorker, isFalse);
      expect(fixture.worker.disposeCalls, 1);
    });

    test(
      'Stop cancels active discovery without a late selection failure',
      () async {
        final preferences = _FakePreferences()..value = _configuration();
        final query = _FakeDeviceDiscoveryQuery.pending();
        final fixture = _Fixture(
          preferences: preferences,
          deviceDiscoveryQueryFactory: (_) => query,
        );
        final restore = fixture.controller.restore();
        await _eventually(() => fixture.controller.ownsWorker);

        await fixture.controller.stop();
        expect(query.cancelCalls, 1);
        await restore;

        expect(fixture.controller.ownsWorker, isFalse);
        expect(fixture.controller.selection.restoring, isFalse);
        expect(fixture.controller.state, LauncherState.idle);
        expect(fixture.controller.error, isNull);
        await fixture.controller.shutdown();
      },
    );

    test(
      'Stop retries unconfirmed discovery without hiding failed cleanup',
      () async {
        final preferences = _FakePreferences()..value = _configuration();
        final query = _FakeDeviceDiscoveryQuery.pending(
          cancelResults: <bool>[false, false, true],
        );
        final fixture = _Fixture(
          preferences: preferences,
          deviceDiscoveryQueryFactory: (_) => query,
        );
        final restore = fixture.controller.restore();
        await _eventually(() => fixture.controller.ownsWorker);

        await fixture.controller.shutdown();

        expect(fixture.controller.state, LauncherState.failed);
        expect(
          fixture.controller.error?.code,
          LauncherErrorCode.cleanupFailure,
        );
        expect(fixture.controller.error?.arguments['terminated'], isFalse);
        expect(fixture.controller.ownsWorker, isTrue);
        expect(fixture.controller.canRetryCleanup, isTrue);
        expect(fixture.worker.disposeCalls, 0);

        await fixture.controller.stop();
        expect(query.cancelCalls, 2);
        expect(query.ownsProcess, isTrue);
        expect(fixture.controller.state, LauncherState.failed);
        expect(fixture.controller.canRetryCleanup, isTrue);

        await fixture.controller.stop();
        await restore;

        expect(query.cancelCalls, 3);
        expect(query.ownsProcess, isFalse);
        expect(fixture.controller.ownsWorker, isFalse);
        expect(fixture.controller.state, LauncherState.idle);
        expect(fixture.controller.error, isNull);
        expect(fixture.controller.canRetryCleanup, isFalse);
        expect(fixture.worker.disposeCalls, 0);

        await fixture.controller.shutdown();
        expect(fixture.worker.disposeCalls, 1);
      },
    );
  });

  group('LauncherController managed sessions', () {
    test(
      'reconnects an owned session with its saved authenticated URI',
      () async {
        final fixture = _Fixture();
        await _selectValid(fixture.controller);
        final uri = Uri.parse('ws://127.0.0.1:43000/owned-token/ws');

        final start = fixture.controller.start();
        await _eventually(() => fixture.worker.startCalls == 1);
        final runId = fixture.worker.currentRunId!;
        fixture.worker.emitStarted(sessionId: 'session-1', runId: runId);
        fixture.worker.emitDebug(
          sessionId: 'session-1',
          runId: runId,
          uri: uri,
        );
        await start;
        final session = fixture.controller.session!;

        expect(fixture.controller.canReconnect, isTrue);
        await fixture.controller.reconnect();

        expect(fixture.services.connectUris, [uri, uri]);
        expect(fixture.controller.state, LauncherState.running);
        expect(fixture.controller.session?.sessionId, session.sessionId);
        expect(fixture.controller.session?.workerUri, uri);
        expect(fixture.controller.session?.reportPath, session.reportPath);
        expect(fixture.controller.ownsWorker, isTrue);
        await fixture.controller.stop();
      },
    );

    test(
      'stale reconnect completion cannot tear down its replacement session',
      () async {
        final fixture = _Fixture(sessionIds: ['session-a', 'session-b']);
        await _selectValid(fixture.controller);
        final uriA = Uri.parse('ws://127.0.0.1:43000/owned-token-a/ws');
        final start = fixture.controller.start();
        await _eventually(() => fixture.worker.startCalls == 1);
        final runId = fixture.worker.currentRunId!;
        fixture.worker.emitStarted(sessionId: 'session-a', runId: runId);
        fixture.worker.emitDebug(
          sessionId: 'session-a',
          runId: runId,
          uri: uriA,
        );
        await start;
        final reconnectGate = Completer<void>();
        fixture.services.connectGate = reconnectGate;

        final reconnect = fixture.controller.reconnect();
        await _eventually(
          () => fixture.controller.state == LauncherState.connecting,
        );
        await fixture.controller.stop().timeout(
          const Duration(milliseconds: 250),
        );
        fixture.services.connectGate = null;

        final uriB = Uri.parse('ws://127.0.0.1:43001/owned-token-b/ws');
        final replacementStart = fixture.controller.start();
        await _eventually(() => fixture.worker.startCalls == 2);
        final replacementRunId = fixture.worker.currentRunId!;
        fixture.worker.emitStarted(
          sessionId: 'session-b',
          runId: replacementRunId,
        );
        fixture.worker.emitDebug(
          sessionId: 'session-b',
          runId: replacementRunId,
          uri: uriB,
        );
        await replacementStart;

        reconnectGate.complete();
        await reconnect.timeout(const Duration(milliseconds: 250));

        expect(fixture.controller.state, LauncherState.running);
        expect(fixture.controller.session?.sessionId, 'session-b');
        expect(fixture.controller.session?.managerPort, 42002);
        expect(fixture.controller.session?.workerUri, uriB);
        expect(fixture.controller.session?.reportPath, '/reports/session-b');
        expect(fixture.controller.ownsWorker, isTrue);
        expect(fixture.services.connected, isTrue);
        expect(fixture.services.boundPort, 42002);
        expect(fixture.services.connectUris, [uriA, uriA, uriB]);
        await fixture.controller.stop();
      },
    );

    test('rejects a second Start while the first is active', () async {
      final fixture = _Fixture();
      await _selectValid(fixture.controller);
      fixture.worker.startGate = Completer<void>();

      final firstStart = fixture.controller.start();
      await _eventually(() => fixture.worker.startCalls == 1);
      await fixture.controller.start();

      expect(fixture.controller.error?.code, LauncherErrorCode.busy);
      expect(fixture.worker.startCalls, 1);
      fixture.worker.startGate!.complete();
      await _eventually(() => fixture.worker.owned);
      final stop = fixture.controller.stop();
      await stop;
      await firstStart;
    });

    test(
      'uses distinct session endpoints and ignores previous-run events',
      () async {
        final fixture = _Fixture(sessionIds: ['session-a', 'session-b']);
        await _selectValid(fixture.controller);

        final firstStart = fixture.controller.start();
        await _eventually(() => fixture.worker.startCalls == 1);
        final firstRun = fixture.worker.currentRunId!;
        fixture.worker.emitStarted(sessionId: 'session-a', runId: firstRun);
        fixture.worker.emitDebug(
          sessionId: 'session-a',
          runId: firstRun,
          uri: Uri.parse('ws://127.0.0.1:41001/token-a/ws'),
        );
        await firstStart;
        expect(fixture.controller.state, LauncherState.running);
        expect(fixture.controller.session?.managerPort, 42001);
        expect(fixture.controller.session?.reportPath, '/reports/session-a');
        await fixture.controller.stop();

        final secondStart = fixture.controller.start();
        await _eventually(() => fixture.worker.startCalls == 2);
        final secondRun = fixture.worker.currentRunId!;
        fixture.worker.emitDebug(
          sessionId: 'session-a',
          runId: firstRun,
          uri: Uri.parse('ws://127.0.0.1:49999/stale/ws'),
        );
        fixture.worker.emitStarted(sessionId: 'session-b', runId: secondRun);
        fixture.worker.emitDebug(
          sessionId: 'session-b',
          runId: secondRun,
          uri: Uri.parse('ws://localhost:41002/token-b/ws'),
        );
        await secondStart;

        expect(fixture.controller.state, LauncherState.running);
        expect(fixture.controller.session?.managerPort, 42002);
        expect(fixture.controller.session?.workerUri?.port, 41002);
        expect(fixture.controller.session?.reportPath, '/reports/session-b');
        expect(fixture.services.reportPaths, [
          '/reports/session-a',
          '/reports/session-b',
        ]);
        expect(fixture.services.connectUris, [
          Uri.parse('ws://127.0.0.1:41001/token-a/ws'),
          Uri.parse('ws://localhost:41002/token-b/ws'),
        ]);
        await fixture.controller.stop();
      },
    );

    test(
      'rejects a non-loopback endpoint and unwinds owned resources',
      () async {
        final fixture = _Fixture();
        await _selectValid(fixture.controller);

        final start = fixture.controller.start();
        await _eventually(() => fixture.worker.startCalls == 1);
        final runId = fixture.worker.currentRunId!;
        fixture.worker.emitStarted(sessionId: 'session-1', runId: runId);
        fixture.worker.emitDebug(
          sessionId: 'session-1',
          runId: runId,
          uri: Uri.parse('ws://192.0.2.1:43000/auth/ws'),
        );
        await start;

        expect(fixture.controller.state, LauncherState.failed);
        expect(
          fixture.controller.error?.code,
          LauncherErrorCode.invalidWorkerEndpoint,
        );
        expect(fixture.services.connectUris, isEmpty);
        expect(fixture.worker.owned, isFalse);
        expect(fixture.services.boundPort, isNull);
      },
    );

    test('rejects a plain /ws endpoint reported by an owned launch', () async {
      final fixture = _Fixture();
      await _selectValid(fixture.controller);

      final start = fixture.controller.start();
      await _eventually(() => fixture.worker.startCalls == 1);
      final runId = fixture.worker.currentRunId!;
      fixture.worker.emitStarted(sessionId: 'session-1', runId: runId);
      fixture.worker.emitDebug(
        sessionId: 'session-1',
        runId: runId,
        uri: Uri.parse('ws://127.0.0.1:43000/ws'),
      );
      await start;

      expect(fixture.controller.state, LauncherState.failed);
      expect(
        fixture.controller.error?.code,
        LauncherErrorCode.invalidWorkerEndpoint,
      );
      expect(fixture.services.connectUris, isEmpty);
      expect(fixture.worker.owned, isFalse);
      expect(fixture.services.boundPort, isNull);
    });

    test('Stop during validation prevents binding and spawning', () async {
      final validateGate = Completer<String>();
      final discovery = _FakeDiscovery()
        ..validate = (_, _) => validateGate.future;
      final fixture = _Fixture(discovery: discovery);
      await _selectValid(fixture.controller);

      final start = fixture.controller.start();
      await _eventually(
        () => fixture.controller.state == LauncherState.validating,
      );
      expect(fixture.controller.canCancelLaunch, isTrue);
      final stop = fixture.controller.stop();
      await stop;

      expect(fixture.controller.state, LauncherState.idle);
      expect(fixture.controller.canStart, isTrue);
      expect(fixture.services.bindPorts, isEmpty);
      expect(fixture.worker.startCalls, 0);

      validateGate.complete('integration_test/example_test.dart');
      await start;
    });

    test('Stop during spawn invalidates later process events', () async {
      final fixture = _Fixture();
      await _selectValid(fixture.controller);
      fixture.worker.startGate = Completer<void>();

      final start = fixture.controller.start();
      await _eventually(() => fixture.worker.startCalls == 1);
      expect(fixture.controller.canCancelLaunch, isTrue);
      final runId = fixture.worker.currentRunId!;
      final stop = fixture.controller.stop();
      fixture.worker.startGate!.complete();
      await Future.wait([start, stop]);
      fixture.worker.emitDebug(
        sessionId: 'session-1',
        runId: runId,
        uri: Uri.parse('ws://127.0.0.1:43000/auth/ws'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(fixture.controller.state, LauncherState.idle);
      expect(fixture.services.connectUris, isEmpty);
      expect(fixture.worker.owned, isFalse);
    });

    test('connection failure cleans up after a valid debug event', () async {
      final services = _FakeSessionServices()
        ..readyError = TimeoutException('ready');
      final fixture = _Fixture(services: services);
      await _selectValid(fixture.controller);

      final start = fixture.controller.start();
      await _eventually(() => fixture.worker.startCalls == 1);
      final runId = fixture.worker.currentRunId!;
      fixture.worker.emitStarted(sessionId: 'session-1', runId: runId);
      fixture.worker.emitDebug(
        sessionId: 'session-1',
        runId: runId,
        uri: Uri.parse('ws://127.0.0.1:43000/auth/ws'),
      );
      await start;

      expect(fixture.controller.state, LauncherState.failed);
      expect(
        fixture.controller.error?.code,
        LauncherErrorCode.connectionFailure,
      );
      expect(fixture.worker.owned, isFalse);
      expect(
        services.operations,
        containsAllInOrder(['connect', 'wait', 'disconnect', 'shutdown']),
      );
    });

    test(
      'VM initialization shares the readiness deadline and cannot outlive its session',
      () async {
        final stalledConnect = Completer<void>();
        final services = _FakeSessionServices()..connectGate = stalledConnect;
        final fixture = _Fixture(
          services: services,
          readinessTimeout: const Duration(milliseconds: 10),
        );
        await _selectValid(fixture.controller);

        final firstStart = fixture.controller.start();
        await _eventually(() => fixture.worker.startCalls == 1);
        final firstRun = fixture.worker.currentRunId!;
        fixture.worker.emitStarted(sessionId: 'session-1', runId: firstRun);
        fixture.worker.emitDebug(
          sessionId: 'session-1',
          runId: firstRun,
          uri: Uri.parse('ws://127.0.0.1:43000/first/ws'),
        );
        await firstStart.timeout(const Duration(milliseconds: 250));

        expect(fixture.controller.state, LauncherState.failed);
        expect(
          fixture.controller.error?.code,
          LauncherErrorCode.connectionFailure,
        );
        expect(fixture.worker.owned, isFalse);
        expect(services.boundPort, isNull);
        expect(services.operations, containsAll(['disconnect', 'shutdown']));

        services.connectGate = null;
        final secondStart = fixture.controller.start();
        await _eventually(() => fixture.worker.startCalls == 2);
        final secondRun = fixture.worker.currentRunId!;
        fixture.worker.emitStarted(sessionId: 'session-2', runId: secondRun);
        fixture.worker.emitDebug(
          sessionId: 'session-2',
          runId: secondRun,
          uri: Uri.parse('ws://127.0.0.1:43001/second/ws'),
        );
        await secondStart;
        stalledConnect.complete();
        await Future<void>.delayed(Duration.zero);

        expect(fixture.controller.state, LauncherState.running);
        expect(fixture.controller.session?.sessionId, 'session-2');
        expect(
          services.operations.where((operation) => operation == 'wait'),
          hasLength(1),
        );
        await fixture.controller.stop();
      },
    );

    test(
      'choosing a project supersedes an in-flight restore cleanly',
      () async {
        final preferences = _FakePreferences()
          ..loadGate = Completer<LaunchConfiguration?>();
        final fixture = _Fixture(preferences: preferences);

        final restore = fixture.controller.restore();
        await _eventually(() => fixture.controller.selection.restoring);
        await fixture.controller.chooseProject('/projects/new');
        preferences.loadGate!.complete(
          _configuration(project: '/projects/old'),
        );
        await restore;

        expect(fixture.controller.selection.restoring, isFalse);
        expect(fixture.controller.selection.projectDirectory, '/projects/new');
      },
    );

    test('exposes a reserved define as a typed diagnostic', () async {
      final worker = _FakeWorkerProcess()
        ..startError = WorkerProcessException(
          WorkerFailureCode.reservedDartDefine,
          details: const {'key': 'CONVENIENT_TEST_MANAGER_PORT'},
        );
      final fixture = _Fixture(worker: worker);
      await _selectValid(fixture.controller);

      await fixture.controller.start();

      expect(fixture.controller.state, LauncherState.failed);
      expect(fixture.controller.error?.code, LauncherErrorCode.reservedDefine);
      expect(
        fixture.controller.error?.arguments['key'],
        'CONVENIENT_TEST_MANAGER_PORT',
      );
    });

    test('partial cleanup retains ownership and permits Stop retry', () async {
      final fixture = _Fixture();
      await _selectValid(fixture.controller);
      final start = fixture.controller.start();
      await _eventually(() => fixture.worker.startCalls == 1);
      final runId = fixture.worker.currentRunId!;
      fixture.worker.emitStarted(sessionId: 'session-1', runId: runId);
      fixture.worker.emitDebug(
        sessionId: 'session-1',
        runId: runId,
        uri: Uri.parse('ws://127.0.0.1:43000/auth/ws'),
      );
      await start;
      fixture.worker.stopError = StateError('still alive');

      await fixture.controller.stop();

      expect(fixture.controller.state, LauncherState.failed);
      expect(fixture.controller.error?.code, LauncherErrorCode.cleanupFailure);
      expect(fixture.controller.canStop, isTrue);
      expect(fixture.controller.canRetryCleanup, isTrue);
      expect(fixture.services.boundPort, isNotNull);

      fixture.worker.stopError = null;
      await fixture.controller.stop();
      expect(fixture.controller.state, LauncherState.idle);
      expect(fixture.worker.owned, isFalse);
      expect(fixture.services.boundPort, isNull);
    });

    test(
      'failed Stop suppresses late connection events until cleanup retry',
      () async {
        final fixture = _Fixture();
        await _selectValid(fixture.controller);
        final start = fixture.controller.start();
        await _eventually(() => fixture.worker.owned);
        final runId = fixture.worker.currentRunId!;
        fixture.worker.stopError = StateError('still alive');

        await fixture.controller.stop();
        fixture.worker.emitStarted(sessionId: 'session-1', runId: runId);
        fixture.worker.emitDebug(
          sessionId: 'session-1',
          runId: runId,
          uri: Uri.parse('ws://127.0.0.1:43000/late/ws'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(fixture.controller.state, LauncherState.failed);
        expect(fixture.controller.canRetryCleanup, isTrue);
        expect(fixture.controller.canStop, isTrue);
        expect(fixture.services.connectUris, isEmpty);

        fixture.worker.stopError = null;
        await fixture.controller.stop();
        await start;
      },
    );

    test('shutdown releases the owned process, VM, and listener', () async {
      final fixture = _Fixture();
      await _selectValid(fixture.controller);
      final start = fixture.controller.start();
      await _eventually(() => fixture.worker.startCalls == 1);
      final runId = fixture.worker.currentRunId!;
      fixture.worker.emitStarted(sessionId: 'session-1', runId: runId);
      fixture.worker.emitDebug(
        sessionId: 'session-1',
        runId: runId,
        uri: Uri.parse('ws://127.0.0.1:43000/auth/ws'),
      );
      await start;

      await fixture.controller.shutdown();

      expect(fixture.controller.state, LauncherState.idle);
      expect(fixture.worker.owned, isFalse);
      expect(fixture.services.connected, isFalse);
      expect(fixture.services.boundPort, isNull);
    });

    test('shutdown closes admission synchronously and is idempotent', () async {
      final fixture = _Fixture();
      await _selectValid(fixture.controller);
      final disposeGate = Completer<void>();
      fixture.worker.disposeGate = disposeGate;

      final shutdown = fixture.controller.shutdown();
      expect(fixture.controller.canStart, isFalse);
      await fixture.controller.chooseProject('/projects/rejected');
      expect(fixture.controller.selection.projectDirectory, '/projects/app');
      await fixture.controller.start();
      await fixture.controller.connectExternal(
        managerPort: 45000,
        workerUri: Uri.parse('ws://127.0.0.1:44000/external/ws'),
      );
      expect(fixture.controller.error?.code, LauncherErrorCode.busy);
      expect(fixture.worker.startCalls, 0);
      expect(fixture.services.bindPorts, isEmpty);
      await _eventually(() => fixture.worker.disposeCalls == 1);

      final repeated = fixture.controller.shutdown();
      disposeGate.complete();
      await Future.wait([shutdown, repeated]);
      await fixture.controller.connectExternal(
        managerPort: 45001,
        workerUri: Uri.parse('ws://127.0.0.1:44001/external/ws'),
      );
      await fixture.controller.shutdown();

      expect(fixture.controller.canStart, isFalse);
      expect(fixture.controller.error?.code, LauncherErrorCode.busy);
      expect(fixture.services.bindPorts, isEmpty);
      expect(fixture.worker.disposeCalls, 1);
    });

    test('does not admit reconnect during shutdown', () async {
      final fixture = _Fixture();
      await _selectValid(fixture.controller);
      final uri = Uri.parse('ws://127.0.0.1:43000/owned-token/ws');
      final start = fixture.controller.start();
      await _eventually(() => fixture.worker.startCalls == 1);
      final runId = fixture.worker.currentRunId!;
      fixture.worker.emitStarted(sessionId: 'session-1', runId: runId);
      fixture.worker.emitDebug(sessionId: 'session-1', runId: runId, uri: uri);
      await start;
      final disposeGate = Completer<void>();
      fixture.worker.disposeGate = disposeGate;

      final shutdown = fixture.controller.shutdown();
      await _eventually(() => fixture.worker.disposeCalls == 1);
      expect(fixture.controller.canReconnect, isFalse);
      await fixture.controller.reconnect();

      expect(fixture.controller.error?.code, LauncherErrorCode.busy);
      expect(fixture.services.connectUris, [uri]);
      disposeGate.complete();
      await shutdown;
    });

    test(
      'shutdown retries retained cleanup before disposing streams',
      () async {
        final fixture = _Fixture();
        await _selectValid(fixture.controller);
        final start = fixture.controller.start();
        await _eventually(() => fixture.worker.startCalls == 1);
        final runId = fixture.worker.currentRunId!;
        fixture.worker.emitStarted(sessionId: 'session-1', runId: runId);
        fixture.worker.emitDebug(
          sessionId: 'session-1',
          runId: runId,
          uri: Uri.parse('ws://127.0.0.1:43000/auth/ws'),
        );
        await start;
        fixture.worker.stopError = StateError('still alive');

        await fixture.controller.shutdown();

        expect(fixture.controller.state, LauncherState.failed);
        expect(fixture.controller.canRetryCleanup, isTrue);
        expect(fixture.controller.canStart, isFalse);
        expect(fixture.worker.disposeCalls, 0);

        fixture.worker.stopError = null;
        await fixture.controller.shutdown();
        await fixture.controller.shutdown();

        expect(fixture.controller.state, LauncherState.idle);
        expect(fixture.worker.owned, isFalse);
        expect(fixture.services.boundPort, isNull);
        expect(fixture.worker.disposeCalls, 1);
        expect(fixture.controller.canStart, isFalse);
      },
    );
  });

  group('LauncherController external sessions', () {
    test(
      'reconnects an external session with its complete saved URI',
      () async {
        final fixture = _Fixture();
        final uri = Uri.parse('wss://localhost:44000/external-token/ws');

        await fixture.controller.connectExternal(
          managerPort: 45000,
          workerUri: uri,
        );
        final session = fixture.controller.session!;

        expect(fixture.controller.canReconnect, isTrue);
        await fixture.controller.reconnect();

        expect(fixture.services.connectUris, [uri, uri]);
        expect(fixture.controller.session?.external, isTrue);
        expect(fixture.controller.session?.sessionId, session.sessionId);
        expect(fixture.controller.session?.workerUri, uri);
        expect(fixture.controller.session?.reportPath, session.reportPath);
        expect(fixture.worker.startCalls, 0);
        expect(fixture.worker.stopCalls, 0);
        await fixture.controller.stop();
      },
    );

    test(
      'binds before connect and never owns or stops an external worker',
      () async {
        final fixture = _Fixture();
        final uri = Uri.parse('ws://127.0.0.1:44000/token/ws');

        await fixture.controller.connectExternal(
          managerPort: 45000,
          workerUri: uri,
        );

        expect(fixture.controller.state, LauncherState.running);
        expect(fixture.controller.session?.external, isTrue);
        expect(fixture.controller.session?.workerUri, uri);
        expect(fixture.controller.canStop, isFalse);
        expect(fixture.worker.startCalls, 0);
        expect(fixture.worker.stopCalls, 0);
        expect(fixture.services.connectUris, [uri]);
        expect(
          fixture.services.operations,
          containsAllInOrder(['bind:45000', 'prepare', 'connect', 'wait']),
        );

        await fixture.controller.stop();
        expect(fixture.worker.stopCalls, 0);
        expect(
          fixture.services.operations,
          containsAllInOrder(['disconnect', 'shutdown']),
        );
      },
    );

    test(
      'reports an occupied external port and releases retry state',
      () async {
        final services = _FakeSessionServices()
          ..bindError = StateError('occupied');
        final fixture = _Fixture(services: services);

        await fixture.controller.connectExternal(
          managerPort: 45000,
          workerUri: Uri.parse('ws://127.0.0.1:44000/token/ws'),
        );

        expect(fixture.controller.state, LauncherState.failed);
        expect(fixture.controller.error?.code, LauncherErrorCode.portConflict);
        expect(fixture.controller.session, isNull);
        expect(fixture.services.boundPort, isNull);
        expect(fixture.worker.stopCalls, 0);
      },
    );

    test('external VM initialization shares the readiness deadline', () async {
      final stalledConnect = Completer<void>();
      final services = _FakeSessionServices()..connectGate = stalledConnect;
      final fixture = _Fixture(
        services: services,
        readinessTimeout: const Duration(milliseconds: 10),
      );

      await fixture.controller
          .connectExternal(
            managerPort: 45000,
            workerUri: Uri.parse('ws://127.0.0.1:44000/first/ws'),
          )
          .timeout(const Duration(milliseconds: 250));

      expect(fixture.controller.state, LauncherState.failed);
      expect(
        fixture.controller.error?.code,
        LauncherErrorCode.connectionFailure,
      );
      expect(fixture.controller.session, isNull);
      expect(services.boundPort, isNull);

      services.connectGate = null;
      await fixture.controller.connectExternal(
        managerPort: 45001,
        workerUri: Uri.parse('ws://127.0.0.1:44001/second/ws'),
      );
      stalledConnect.complete();
      await Future<void>.delayed(Duration.zero);

      expect(fixture.controller.state, LauncherState.running);
      expect(fixture.controller.session?.managerPort, 45001);
      expect(
        services.operations.where((operation) => operation == 'wait'),
        hasLength(1),
      );
      await fixture.controller.stop();
    });

    test('accepts an explicit external loopback /ws endpoint', () async {
      final fixture = _Fixture();
      final uri = Uri.parse('ws://127.0.0.1:44000/ws');

      await fixture.controller.connectExternal(
        managerPort: 45000,
        workerUri: uri,
      );

      expect(fixture.controller.state, LauncherState.running);
      expect(fixture.controller.session?.external, isTrue);
      expect(fixture.controller.session?.workerUri, uri);
      expect(fixture.services.connectUris, [uri]);
      expect(fixture.worker.startCalls, 0);
      expect(fixture.worker.stopCalls, 0);

      await fixture.controller.stop();
      expect(fixture.worker.stopCalls, 0);
    });

    test(
      'rejects invalid explicit external endpoints before binding',
      () async {
        final invalidUris = <Uri>[
          Uri.parse('ws://192.0.2.1:44000/ws'),
          Uri.parse('ws://user@127.0.0.1:44000/ws'),
          Uri.parse('ws://127.0.0.1:44000/ws?token=value'),
          Uri.parse('ws://127.0.0.1:44000/ws#fragment'),
        ];

        for (final uri in invalidUris) {
          final fixture = _Fixture();

          await fixture.controller.connectExternal(
            managerPort: 45000,
            workerUri: uri,
          );

          expect(
            fixture.controller.error?.code,
            LauncherErrorCode.invalidWorkerEndpoint,
            reason: '$uri must not be accepted',
          );
          expect(fixture.services.bindPorts, isEmpty);
          expect(fixture.services.connectUris, isEmpty);
        }
      },
    );
  });

  group('LauncherController offline reports', () {
    test('loads a report without binding, connecting, or spawning', () async {
      final fixture = _Fixture();
      await _selectValid(fixture.controller);
      String? loadedPath;

      expect(fixture.controller.canLoadReport, isTrue);
      await fixture.controller.loadReport(
        choosePath: () async => '/reports/offline.bin',
        readReport: (path, _) async => loadedPath = path,
      );

      expect(loadedPath, '/reports/offline.bin');
      expect(fixture.controller.isLoadingReport, isFalse);
      expect(fixture.controller.canLoadReport, isTrue);
      expect(fixture.controller.selection.projectDirectory, '/projects/app');
      expect(fixture.worker.startCalls, 0);
      expect(fixture.services.bindPorts, isEmpty);
      expect(fixture.services.connectUris, isEmpty);
      expect(fixture.services.boundPort, isNull);
    });

    test(
      'rejects report loading with owned, external, or failed-cleanup resources',
      () async {
        var pickerCalls = 0;

        final owned = _Fixture();
        await _selectValid(owned.controller);
        final ownedStart = owned.controller.start();
        await _eventually(() => owned.worker.startCalls == 1);
        final ownedRunId = owned.worker.currentRunId!;
        owned.worker.emitStarted(sessionId: 'session-1', runId: ownedRunId);
        owned.worker.emitDebug(
          sessionId: 'session-1',
          runId: ownedRunId,
          uri: Uri.parse('ws://127.0.0.1:43000/owned/ws'),
        );
        await ownedStart;
        await owned.controller.loadReport(
          choosePath: () async {
            pickerCalls++;
            return '/reports/owned.bin';
          },
          readReport: (_, _) async {},
        );
        expect(owned.controller.canLoadReport, isFalse);
        expect(owned.controller.error?.code, LauncherErrorCode.busy);

        final external = _Fixture();
        await external.controller.connectExternal(
          managerPort: 45000,
          workerUri: Uri.parse('ws://127.0.0.1:44000/external/ws'),
        );
        await external.controller.loadReport(
          choosePath: () async {
            pickerCalls++;
            return '/reports/external.bin';
          },
          readReport: (_, _) async {},
        );
        expect(external.controller.canLoadReport, isFalse);
        expect(external.controller.error?.code, LauncherErrorCode.busy);

        owned.worker.stopError = StateError('still alive');
        await owned.controller.stop();
        expect(owned.controller.canRetryCleanup, isTrue);
        await owned.controller.loadReport(
          choosePath: () async {
            pickerCalls++;
            return '/reports/residue.bin';
          },
          readReport: (_, _) async {},
        );

        expect(pickerCalls, 0);
        expect(owned.controller.error?.code, LauncherErrorCode.busy);
        owned.worker.stopError = null;
        await owned.controller.stop();
        await external.controller.stop();
      },
    );

    test(
      'pending picker closes admission and cancellation reopens it',
      () async {
        final fixture = _Fixture();
        await _selectValid(fixture.controller);
        final picker = Completer<String?>();
        final originalProject = fixture.controller.selection.projectDirectory;

        final load = fixture.controller.loadReport(
          choosePath: () => picker.future,
          readReport: (_, _) async {},
        );
        expect(fixture.controller.isLoadingReport, isTrue);
        expect(fixture.controller.canStart, isFalse);
        await fixture.controller.start();
        await fixture.controller.connectExternal(
          managerPort: 45000,
          workerUri: Uri.parse('ws://127.0.0.1:44000/external/ws'),
        );
        await fixture.controller.chooseProject('/projects/rejected');

        expect(fixture.worker.startCalls, 0);
        expect(fixture.services.bindPorts, isEmpty);
        expect(fixture.controller.selection.projectDirectory, originalProject);
        picker.complete(null);
        await load;

        expect(fixture.controller.isLoadingReport, isFalse);
        expect(fixture.controller.canLoadReport, isTrue);
        expect(fixture.controller.canStart, isTrue);
      },
    );

    test('shutdown invalidates a pending picker without awaiting it', () async {
      final fixture = _Fixture();
      final picker = Completer<String?>();
      var readCalls = 0;
      final load = fixture.controller.loadReport(
        choosePath: () => picker.future,
        readReport: (_, _) async => readCalls++,
      );
      expect(fixture.controller.isLoadingReport, isTrue);

      await fixture.controller.shutdown().timeout(
        const Duration(milliseconds: 250),
      );
      picker.complete('/reports/too-late.bin');
      await load;

      expect(readCalls, 0);
      expect(fixture.controller.isLoadingReport, isFalse);
      expect(fixture.controller.canLoadReport, isFalse);
      expect(fixture.services.bindPorts, isEmpty);
      expect(fixture.worker.startCalls, 0);
    });

    test('shutdown invalidates an already-started report read', () async {
      final fixture = _Fixture();
      final readStarted = Completer<void>();
      final readGate = Completer<void>();
      var storeMutated = false;
      final load = fixture.controller.loadReport(
        choosePath: () async => '/reports/stalled.bin',
        readReport: (_, isCurrent) async {
          readStarted.complete();
          await readGate.future;
          if (isCurrent()) storeMutated = true;
        },
      );
      await readStarted.future;

      await fixture.controller.shutdown().timeout(
        const Duration(milliseconds: 250),
      );
      readGate.complete();
      await load;

      expect(storeMutated, isFalse);
      expect(fixture.controller.isLoadingReport, isFalse);
      expect(fixture.controller.canLoadReport, isFalse);
      expect(fixture.services.bindPorts, isEmpty);
      expect(fixture.worker.startCalls, 0);
    });

    test('turns picker and reader failures into typed diagnostics', () async {
      final pickerFailure = _Fixture();

      await pickerFailure.controller.loadReport(
        choosePath: () async => throw StateError('picker failed'),
        readReport: (_, _) async {},
      );

      expect(
        pickerFailure.controller.error?.code,
        LauncherErrorCode.reportLoadFailure,
      );
      expect(pickerFailure.controller.isLoadingReport, isFalse);

      final readerFailure = _Fixture();
      await readerFailure.controller.loadReport(
        choosePath: () async => '/reports/broken.bin',
        readReport: (_, _) async => throw StateError('read failed'),
      );

      expect(
        readerFailure.controller.error?.code,
        LauncherErrorCode.reportLoadFailure,
      );
      expect(
        readerFailure.controller.error?.arguments['path'],
        '/reports/broken.bin',
      );
      expect(readerFailure.controller.isLoadingReport, isFalse);
    });
  });
}

Future<void> _selectValid(LauncherController controller) async {
  await controller.chooseProject('/projects/app');
  await controller.chooseEntrypoint('integration_test/example_test.dart');
  await controller.chooseDevice('device-1');
  await controller.setDartDefines({'PROFILE': 'gui test'});
  expect(controller.canStart, isTrue);
}

LaunchConfiguration _configuration({String project = '/projects/app'}) =>
    LaunchConfiguration(
      projectDirectory: project,
      entrypoint: 'integration_test/example_test.dart',
      flutterExecutable: '/sdk/flutter',
      deviceId: 'device-1',
      dartDefines: const {'PROFILE': 'gui test'},
    );

Future<void> _eventually(bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue);
}

class _Fixture {
  _Fixture({
    _FakeDiscovery? discovery,
    _FakePreferences? preferences,
    _FakeWorkerProcess? worker,
    _FakeSessionServices? services,
    List<String> sessionIds = const ['session-1', 'session-2'],
    Duration readinessTimeout = const Duration(milliseconds: 100),
    DeviceDiscoveryQuery Function(String flutterExecutable)?
    deviceDiscoveryQueryFactory,
  }) : discovery = discovery ?? _FakeDiscovery(),
       preferences = preferences ?? _FakePreferences(),
       worker = worker ?? _FakeWorkerProcess(),
       services = services ?? _FakeSessionServices() {
    final ids = sessionIds.iterator;
    controller = LauncherController(
      discovery: this.discovery,
      preferences: this.preferences,
      process: this.worker,
      sessionServices: this.services,
      reportRootDirectory: '/reports',
      readinessTimeout: readinessTimeout,
      deviceDiscoveryQueryFactory: deviceDiscoveryQueryFactory,
      sessionIdFactory: () {
        if (!ids.moveNext()) throw StateError('session ID exhausted');
        return ids.current;
      },
    );
  }

  final _FakeDiscovery discovery;
  final _FakePreferences preferences;
  final _FakeWorkerProcess worker;
  final _FakeSessionServices services;
  late final LauncherController controller;
}

class _FakeDeviceDiscoveryQuery implements DeviceDiscoveryQuery {
  _FakeDeviceDiscoveryQuery.pending({
    this.cancelGate,
    List<bool> cancelResults = const <bool>[true],
  }) : _cancelResults = List<bool>.of(cancelResults);

  _FakeDeviceDiscoveryQuery.completed()
    : cancelGate = null,
      _cancelResults = <bool>[] {
    _ownsProcess = false;
    _result.complete([(id: 'device-1', name: 'Device one')]);
  }

  final Completer<bool>? cancelGate;
  final List<bool> _cancelResults;
  final Completer<List<({String id, String name})>> _result =
      Completer<List<({String id, String name})>>();
  bool _ownsProcess = true;
  int cancelCalls = 0;

  @override
  int? get ownedPid => _ownsProcess ? 2468 : null;

  @override
  bool get ownsProcess => _ownsProcess;

  @override
  Future<List<({String id, String name})>> get result => _result.future;

  @override
  Future<bool> cancel() async {
    cancelCalls++;
    final gate = cancelGate;
    final cleaned = gate != null
        ? await gate.future
        : _cancelResults.removeAt(0);
    if (cleaned) {
      _ownsProcess = false;
      if (!_result.isCompleted) {
        _result.completeError(
          const ProjectDiscoveryException(
            ProjectDiscoveryError.deviceDiscoveryFailed,
            details: <String, Object?>{'cancelled': true},
          ),
        );
      }
    }
    return cleaned;
  }
}

class _FakeDiscovery implements ProjectDiscovery {
  Future<String> Function(String) canonicalProject = Future.value;
  Future<String> Function(String, String?, String?) resolveSdk =
      (_, explicit, saved) => Future.value(explicit ?? saved ?? '/sdk/flutter');
  Future<String> Function(String, String) validate = (project, entrypoint) =>
      Future.value(entrypoint);
  Future<List<({String id, String name})>> Function(String) discoverDevices =
      (_) => Future.value([(id: 'device-1', name: 'Device one')]);

  @override
  Future<String> canonicalProjectDirectory(String projectDirectory) =>
      canonicalProject(projectDirectory);

  @override
  Future<List<({String id, String name})>> devices(String flutterExecutable) =>
      discoverDevices(flutterExecutable);

  @override
  Future<List<String>> entrypoints(String projectDirectory) async => [
    'integration_test/example_test.dart',
  ];

  @override
  Future<String> resolveFlutterExecutable({
    required String projectDirectory,
    String? explicitFlutterExecutable,
    String? savedFlutterExecutable,
  }) => resolveSdk(
    projectDirectory,
    explicitFlutterExecutable,
    savedFlutterExecutable,
  );

  @override
  Future<String> validateEntrypoint(
    String projectDirectory,
    String entrypoint,
  ) => validate(projectDirectory, entrypoint);
}

class _FakePreferences implements LauncherPreferences {
  LaunchConfiguration? value;
  Completer<LaunchConfiguration?>? loadGate;
  int saveCalls = 0;

  @override
  LauncherPreferencesDiagnostic? diagnostic;

  @override
  String get filePath => '/preferences.json';

  @override
  Future<LaunchConfiguration?> load() async =>
      await (loadGate?.future ?? value);

  @override
  Future<void> save(LaunchConfiguration configuration) async {
    saveCalls++;
    value = configuration;
  }
}

class _FakeWorkerProcess implements LauncherWorkerProcess {
  final _events = StreamController<WorkerEvent>.broadcast(sync: true);
  int startCalls = 0;
  int stopCalls = 0;
  int _runId = 0;
  bool _owned = false;
  bool _stopRequested = false;
  Completer<void>? startGate;
  Completer<void>? disposeGate;
  Object? stopError;
  Object? startError;
  int disposeCalls = 0;
  LaunchConfiguration? configuration;
  String? sessionId;
  int? managerPort;

  @override
  Stream<WorkerEvent> get events => _events.stream;

  @override
  List<WorkerLogEvent> get logs => const [];

  @override
  int? get currentRunId => _runId == 0 ? null : _runId;

  @override
  bool get owned => _owned;

  @override
  int? get ownedPid => _owned ? 12345 : null;

  @override
  Future<void> start(
    LaunchConfiguration configuration, {
    required String sessionId,
    required int managerPort,
  }) async {
    startCalls++;
    _runId++;
    _stopRequested = false;
    this.configuration = configuration;
    this.sessionId = sessionId;
    this.managerPort = managerPort;
    final error = startError;
    if (error != null) throw error;
    await startGate?.future;
    _owned = !_stopRequested;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _stopRequested = true;
    final error = stopError;
    if (error != null) throw error;
    _owned = false;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await disposeGate?.future;
    await stop();
    await _events.close();
  }

  void emitStarted({required String sessionId, required int runId}) {
    _events.add(
      WorkerAppStartedEvent(
        runId: runId,
        sessionId: sessionId,
        appId: 'app-$runId',
      ),
    );
  }

  void emitDebug({
    required String sessionId,
    required int runId,
    required Uri uri,
  }) {
    _events.add(
      WorkerDebugPortEvent(
        runId: runId,
        sessionId: sessionId,
        appId: 'app-$runId',
        vmServiceUri: uri,
        baseUri: null,
        port: uri.port,
      ),
    );
  }
}

class _FakeSessionServices implements LauncherSessionServices {
  final operations = <String>[];
  final bindPorts = <int>[];
  final reportPaths = <String>[];
  final connectUris = <Uri>[];
  final _managedPorts = <int>[42001, 42002, 42003];
  int _generation = 0;
  Object? bindError;
  Object? readyError;
  Completer<void>? connectGate;

  @override
  int? boundPort;

  @override
  bool connected = false;

  @override
  Future<int> bind({required int port}) async {
    operations.add('bind:$port');
    bindPorts.add(port);
    final error = bindError;
    if (error != null) throw error;
    boundPort = port == 0 ? _managedPorts.removeAt(0) : port;
    return boundPort!;
  }

  @override
  Future<int> prepareSession({required String reportPath}) async {
    operations.add('prepare');
    reportPaths.add(reportPath);
    return ++_generation;
  }

  @override
  Future<void> connect({required Uri uri}) async {
    operations.add('connect');
    connectUris.add(uri);
    await connectGate?.future;
    connected = true;
  }

  @override
  Future<void> waitUntilReady({
    required int generation,
    required Duration timeout,
  }) async {
    operations.add('wait');
    final error = readyError;
    if (error != null) throw error;
  }

  @override
  Future<void> disconnect() async {
    operations.add('disconnect');
    connected = false;
  }

  @override
  Future<void> shutdownListener() async {
    operations.add('shutdown');
    boundPort = null;
  }

  @override
  Future<void> restoreGlobalConfiguration() async {
    operations.add('restore-config');
  }
}
