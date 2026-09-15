import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convenient_test_manager/launcher/flutter_worker_process.dart';
import 'package:convenient_test_manager/launcher/launch_configuration.dart';
import 'package:convenient_test_manager/launcher/owned_process_group.dart';
import 'package:flutter_test/flutter_test.dart';

extension _WhereTypeStream<T> on Stream<T> {
  Stream<R> whereType<R>() => where((event) => event is R).cast<R>();
}

void main() {
  group('FlutterWorkerProcess start', () {
    test(
      'uses vector arguments, cwd, port zero, and literal defines',
      () async {
        final harness = _ProcessHarness();
        final worker = FlutterWorkerProcess(processStarter: harness.start);
        final config = _configuration(
          projectDirectory: '/project with spaces',
          dartDefines: const <String, String>{
            'LITERAL': r'value with spaces $HOME "quotes"',
          },
        );

        await worker.start(config, sessionId: 'session-1', managerPort: 43123);

        expect(harness.executable, '/sdk with spaces/bin/flutter');
        expect(harness.workingDirectory, '/project with spaces');
        expect(harness.runInShell, isFalse);
        expect(harness.arguments, <String>[
          'run',
          '--machine',
          '--debug',
          '-d',
          'macos',
          'integration_test/flow with spaces.dart',
          '--host-vmservice-port',
          '0',
          '--dart-define',
          'CONVENIENT_TEST_APP_CODE_DIR=/project with spaces',
          '--dart-define',
          'CONVENIENT_TEST_MANAGER_HOST=127.0.0.1',
          '--dart-define',
          'CONVENIENT_TEST_MANAGER_PORT=43123',
          '--dart-define',
          r'LITERAL=value with spaces $HOME "quotes"',
        ]);
        expect(worker.owned, isTrue);
        expect(worker.ownedPid, 4100);

        harness.process.completeExit(0);
        await worker.events.whereType<WorkerExitedEvent>().first;
        await worker.dispose();
      },
    );

    test(
      'rejects zero and out-of-range manager ports before spawning',
      () async {
        final harness = _ProcessHarness();
        final worker = FlutterWorkerProcess(processStarter: harness.start);

        for (final port in <int>[0, -1, 65536]) {
          await expectLater(
            worker.start(
              _configuration(),
              sessionId: 'session',
              managerPort: port,
            ),
            throwsA(
              isA<WorkerProcessException>().having(
                (error) => error.code,
                'code',
                WorkerFailureCode.invalidManagerPort,
              ),
            ),
          );
        }
        expect(harness.startCount, 0);
        await worker.dispose();
      },
    );

    test('rejects empty session IDs and reserved define overrides', () async {
      final harness = _ProcessHarness();
      final worker = FlutterWorkerProcess(processStarter: harness.start);

      await expectLater(
        worker.start(_configuration(), sessionId: '', managerPort: 1234),
        throwsA(
          isA<WorkerProcessException>().having(
            (error) => error.code,
            'code',
            WorkerFailureCode.invalidSessionId,
          ),
        ),
      );
      for (final key in FlutterWorkerProcess.reservedDartDefineKeys) {
        await expectLater(
          worker.start(
            _configuration(dartDefines: <String, String>{key: 'override'}),
            sessionId: 'session',
            managerPort: 1234,
          ),
          throwsA(
            isA<WorkerProcessException>().having(
              (error) => error.code,
              'code',
              WorkerFailureCode.reservedDartDefine,
            ),
          ),
        );
      }
      expect(harness.startCount, 0);
      await worker.dispose();
    });

    test('rejects a second start while the owned process is live', () async {
      final harness = _ProcessHarness();
      final worker = FlutterWorkerProcess(processStarter: harness.start);
      await worker.start(_configuration(), sessionId: 'one', managerPort: 1234);

      await expectLater(
        worker.start(_configuration(), sessionId: 'two', managerPort: 1235),
        throwsA(
          isA<WorkerProcessException>().having(
            (error) => error.code,
            'code',
            WorkerFailureCode.alreadyRunning,
          ),
        ),
      );
      expect(harness.startCount, 1);

      harness.process.completeExit(0);
      await worker.events.whereType<WorkerExitedEvent>().first;
      await worker.dispose();
    });

    test('reports spawn failures without claiming ownership', () async {
      const error = ProcessException(
        '/sdk/bin/flutter',
        <String>[],
        'no executable',
      );
      final worker = FlutterWorkerProcess(
        processStarter:
            (
              _,
              _, {
              workingDirectory,
              environment,
              includeParentEnvironment = true,
              runInShell = false,
              mode = ProcessStartMode.normal,
            }) => Future<Process>.error(error),
      );
      final failure = worker.events.whereType<WorkerFailureEvent>().first;

      await expectLater(
        worker.start(_configuration(), sessionId: 'spawn', managerPort: 1234),
        throwsA(
          isA<WorkerProcessException>().having(
            (exception) => exception.code,
            'code',
            WorkerFailureCode.spawnFailed,
          ),
        ),
      );
      expect((await failure).code, WorkerFailureCode.spawnFailed);
      expect(worker.owned, isFalse);
      await worker.dispose();
    });

    test('reports process-group isolation startup failures', () async {
      const error = OwnedProcessGroupStartException('setsid failed');
      final worker = FlutterWorkerProcess(
        ownedProcessGroupStarter:
            (
              _,
              _, {
              workingDirectory,
              environment,
              includeParentEnvironment = true,
              runInShell = false,
              mode = ProcessStartMode.normal,
            }) => Future<OwnedProcessGroup>.error(error),
      );
      final failure = worker.events.whereType<WorkerFailureEvent>().first;

      await expectLater(
        worker.start(
          _configuration(),
          sessionId: 'isolation-failure',
          managerPort: 1234,
        ),
        throwsA(
          isA<WorkerProcessException>()
              .having(
                (exception) => exception.code,
                'code',
                WorkerFailureCode.spawnFailed,
              )
              .having(
                (exception) => exception.details['error'],
                'error',
                same(error),
              ),
        ),
      );
      expect((await failure).details['error'], same(error));
      expect(worker.owned, isFalse);
      await worker.dispose();
    });

    test(
      'pending stop contains cleanup ownership from failed startup',
      () async {
        final process = _FakeProcess(pid: 4202);
        final ownership = _FakeOwnedProcessGroup(process, groupId: 4202);
        final starterResult = Completer<OwnedProcessGroup>();
        final startupError = OwnedProcessGroupStartException(
          'readiness timed out and cleanup was not confirmed',
          cleanupOwnership: ownership,
        );
        final worker = FlutterWorkerProcess(
          ownedProcessGroupStarter:
              (
                _,
                _, {
                workingDirectory,
                environment,
                includeParentEnvironment = true,
                runInShell = false,
                mode = ProcessStartMode.normal,
              }) => starterResult.future,
        );
        ownership.onSignal = (signal) {
          if (signal == ProcessSignal.sigint) {
            process.completeExit(-9);
            ownership.completeExit();
          }
          return true;
        };

        final start = worker.start(
          _configuration(),
          sessionId: 'failed-pending-start',
          managerPort: 1234,
        );
        final stop = worker.stop();
        starterResult.completeError(startupError, StackTrace.current);

        await expectLater(
          start,
          throwsA(
            isA<WorkerProcessException>().having(
              (error) => error.code,
              'code',
              WorkerFailureCode.spawnFailed,
            ),
          ),
        );
        await stop;

        expect(ownership.signals, <ProcessSignal>[ProcessSignal.sigint]);
        expect(worker.owned, isFalse);
        await worker.dispose();
      },
    );

    test(
      'failed startup cleanup remains retryable after stop timeout',
      () async {
        final process = _FakeProcess(pid: 4203);
        final ownership = _FakeOwnedProcessGroup(process, groupId: 4203);
        final startupError = OwnedProcessGroupStartException(
          'readiness timed out and cleanup was not confirmed',
          cleanupOwnership: ownership,
        );
        final worker = FlutterWorkerProcess(
          ownedProcessGroupStarter:
              (
                _,
                _, {
                workingDirectory,
                environment,
                includeParentEnvironment = true,
                runInShell = false,
                mode = ProcessStartMode.normal,
              }) => Future<OwnedProcessGroup>.error(startupError),
          gracefulStopTimeout: const Duration(milliseconds: 5),
          terminateTimeout: const Duration(milliseconds: 5),
          killTimeout: const Duration(milliseconds: 5),
        );

        await expectLater(
          worker.start(
            _configuration(),
            sessionId: 'failed-startup-cleanup',
            managerPort: 1234,
          ),
          throwsA(isA<WorkerProcessException>()),
        );
        expect(worker.owned, isTrue);

        await expectLater(
          worker.stop(),
          throwsA(
            isA<WorkerProcessException>().having(
              (error) => error.code,
              'code',
              WorkerFailureCode.stopTimedOut,
            ),
          ),
        );
        expect(worker.owned, isTrue);

        ownership.onSignal = (signal) {
          if (signal == ProcessSignal.sigkill) {
            process.completeExit(-9);
            ownership.completeExit();
          }
          return true;
        };
        await worker.dispose();
        expect(worker.owned, isFalse);
      },
    );
  });

  group('FlutterWorkerProcess protocol and lifecycle', () {
    test(
      'emits appStarted and matching debugPort from fragmented stdout',
      () async {
        final harness = _ProcessHarness();
        final worker = FlutterWorkerProcess(processStarter: harness.start);
        final events = <WorkerEvent>[];
        final subscription = worker.events.listen(events.add);
        await worker.start(
          _configuration(),
          sessionId: 'owned-session',
          managerPort: 1234,
        );

        harness.process.stdoutBytes(_connected);
        harness.process.stdoutBytes(_appStart('app-1'));
        final debug = utf8.encode(
          _debugPort('app-1', 'ws://127.0.0.1:54321/token=/ws'),
        );
        harness.process.addStdoutChunk(debug.sublist(0, debug.length ~/ 2));
        harness.process.addStdoutChunk(debug.sublist(debug.length ~/ 2));
        harness.process.stdoutBytes(_appStarted('app-1'));
        await _flushEvents();

        final started = events.whereType<WorkerAppStartedEvent>().single;
        final debugPort = events.whereType<WorkerDebugPortEvent>().single;
        expect(started.appId, 'app-1');
        expect(started.sessionId, 'owned-session');
        expect(debugPort.appId, 'app-1');
        expect(
          debugPort.vmServiceUri,
          Uri.parse('ws://127.0.0.1:54321/token=/ws'),
        );
        expect(debugPort.baseUri, Uri.parse('http://127.0.0.1:55111/token=/'));

        harness.process.completeExit(0);
        await worker.events.whereType<WorkerExitedEvent>().first;
        await subscription.cancel();
        await worker.dispose();
      },
    );

    test('extracts structured build failure from stderr', () async {
      final harness = _ProcessHarness();
      final worker = FlutterWorkerProcess(processStarter: harness.start);
      final failure = worker.events.whereType<WorkerFailureEvent>().first;
      await worker.start(
        _configuration(),
        sessionId: 'build',
        managerPort: 1234,
      );

      harness.process.stderrBytes(_connected);
      harness.process.stderrBytes(
        '[{"event":"app.stop","params":{"appId":"app-build","error":"Build failed"}}]\n',
      );

      final event = await failure;
      expect(event.code, WorkerFailureCode.buildFailed);
      expect(event.details['error'], 'Build failed');
      expect(worker.owned, isTrue);

      harness.process.completeExit(1);
      await worker.events.whereType<WorkerExitedEvent>().first;
      await worker.dispose();
    });

    test(
      'reports an early exit and does not become idle before exit',
      () async {
        final harness = _ProcessHarness();
        final worker = FlutterWorkerProcess(processStarter: harness.start);
        final failures = <WorkerFailureEvent>[];
        final subscription = worker.events
            .whereType<WorkerFailureEvent>()
            .listen(failures.add);
        await worker.start(
          _configuration(),
          sessionId: 'early',
          managerPort: 1234,
        );
        harness.process.stderrBytes('compiler output\n');
        expect(worker.owned, isTrue);

        harness.process.completeExit(2);
        final exited = await worker.events.whereType<WorkerExitedEvent>().first;
        await _flushEvents();

        expect(exited.exitCode, 2);
        expect(exited.stopRequested, isFalse);
        expect(worker.owned, isFalse);
        expect(failures.single.code, WorkerFailureCode.exitedEarly);
        await subscription.cancel();
        await worker.dispose();
      },
    );

    test(
      'contains descendants before releasing a naturally exited root',
      () async {
        final process = _FakeProcess(pid: 4200);
        final ownership = _FakeOwnedProcessGroup(process, groupId: 4200);
        final worker = FlutterWorkerProcess(
          ownedProcessGroupStarter: ownership.start,
          terminateTimeout: const Duration(milliseconds: 5),
          killTimeout: const Duration(milliseconds: 20),
        );
        ownership.onSignal = (signal) {
          if (signal == ProcessSignal.sigkill) {
            ownership.completeExit();
          }
          return true;
        };
        await worker.start(
          _configuration(),
          sessionId: 'root-exit-with-descendants',
          managerPort: 1234,
        );
        final exited = worker.events.whereType<WorkerExitedEvent>().first;

        process.completeExit(0);
        await _flushEvents();
        expect(worker.owned, isTrue);

        expect((await exited).exitCode, 0);
        expect(ownership.signals, <ProcessSignal>[
          ProcessSignal.sigterm,
          ProcessSignal.sigkill,
        ]);
        expect(worker.owned, isFalse);
        await worker.dispose();
      },
    );

    test(
      'ignores mismatched app debug events and reports protocol failure',
      () async {
        final harness = _ProcessHarness();
        final worker = FlutterWorkerProcess(processStarter: harness.start);
        final events = <WorkerEvent>[];
        final subscription = worker.events.listen(events.add);
        await worker.start(
          _configuration(),
          sessionId: 'match',
          managerPort: 1234,
        );
        harness.process.stdoutBytes(_connected);
        harness.process.stdoutBytes(_appStart('owned'));
        harness.process.stdoutBytes(
          _debugPort('other', 'ws://127.0.0.1:5000/ws'),
        );
        await _flushEvents();

        expect(events.whereType<WorkerDebugPortEvent>(), isEmpty);
        expect(
          events.whereType<WorkerFailureEvent>().single.code,
          WorkerFailureCode.protocolViolation,
        );

        harness.process.completeExit(1);
        await worker.events.whereType<WorkerExitedEvent>().first;
        await subscription.cancel();
        await worker.dispose();
      },
    );

    test('rejects an unsupported daemon protocol generation', () async {
      final harness = _ProcessHarness();
      final worker = FlutterWorkerProcess(processStarter: harness.start);
      final events = <WorkerEvent>[];
      final subscription = worker.events.listen(events.add);
      await worker.start(
        _configuration(),
        sessionId: 'protocol',
        managerPort: 1234,
      );

      harness.process.stdoutBytes(
        '[{"event":"daemon.connected","params":{"version":"0.7.0"}}]\n',
      );
      harness.process.stdoutBytes(_appStart('must-not-start'));
      await _flushEvents();

      expect(events.whereType<WorkerAppStartedEvent>(), isEmpty);
      expect(
        events.whereType<WorkerFailureEvent>().map((event) => event.code),
        containsAll(<WorkerFailureCode>[
          WorkerFailureCode.unsupportedProtocol,
          WorkerFailureCode.protocolViolation,
        ]),
      );
      expect(worker.owned, isTrue);

      harness.process.completeExit(1);
      await worker.events.whereType<WorkerExitedEvent>().first;
      await subscription.cancel();
      await worker.dispose();
    });

    test('retains only the configured bounded logs', () async {
      final harness = _ProcessHarness();
      final worker = FlutterWorkerProcess(
        processStarter: harness.start,
        maxRetainedLogLines: 2,
      );
      await worker.start(
        _configuration(),
        sessionId: 'logs',
        managerPort: 1234,
      );
      harness.process.stdoutBytes('one\ntwo\nthree\n');
      await _flushEvents();

      expect(worker.logs.map((event) => event.message), <String>[
        'two',
        'three',
      ]);

      harness.process.completeExit(0);
      await worker.events.whereType<WorkerExitedEvent>().first;
      await worker.dispose();
    });

    test('stop before appId signals only the owned process', () async {
      final harness = _ProcessHarness();
      final worker = FlutterWorkerProcess(
        processStarter: harness.start,
        gracefulStopTimeout: const Duration(milliseconds: 30),
        terminateTimeout: const Duration(milliseconds: 30),
        killTimeout: const Duration(milliseconds: 30),
      );
      harness.process.onKill = (signal) {
        harness.process.completeExit(0);
        return true;
      };
      await worker.start(
        _configuration(),
        sessionId: 'cancel-build',
        managerPort: 1234,
      );

      await worker.stop();

      expect(harness.process.signals, <ProcessSignal>[ProcessSignal.sigint]);
      expect(harness.process.stdinText, isEmpty);
      expect(worker.owned, isFalse);
      await worker.dispose();
    });

    test('graceful stop sends app.stop with the owned appId', () async {
      final harness = _ProcessHarness();
      final worker = FlutterWorkerProcess(
        processStarter: harness.start,
        gracefulStopTimeout: const Duration(milliseconds: 100),
      );
      await worker.start(
        _configuration(),
        sessionId: 'graceful',
        managerPort: 1234,
      );
      harness.process.stdoutBytes(_connected);
      harness.process.stdoutBytes(_appStart('app-owned'));
      await _flushEvents();
      final stopFuture = worker.stop();
      await _flushEvents();

      final requests = const LineSplitter()
          .convert(harness.process.stdinText)
          .map(jsonDecode)
          .toList();
      expect(requests, <Object?>[
        <Object?>[
          <String, Object?>{
            'id': 1,
            'method': 'app.stop',
            'params': <String, Object?>{'appId': 'app-owned'},
          },
        ],
      ]);
      harness.process.stdoutBytes('[{"id":1,"result":true}]\n');
      await _flushEvents();
      expect(worker.owned, isTrue);
      harness.process.completeExit(0);
      await stopFuture;
      expect(worker.owned, isFalse);
      await worker.dispose();
    });

    test(
      'stop timeout retains ownership, emits PID, and permits retry',
      () async {
        final harness = _ProcessHarness();
        final worker = FlutterWorkerProcess(
          processStarter: harness.start,
          gracefulStopTimeout: const Duration(milliseconds: 5),
          terminateTimeout: const Duration(milliseconds: 5),
          killTimeout: const Duration(milliseconds: 5),
        );
        harness.process.onKill = (_) => false;
        final failures = <WorkerFailureEvent>[];
        final subscription = worker.events
            .whereType<WorkerFailureEvent>()
            .listen(failures.add);
        await worker.start(
          _configuration(),
          sessionId: 'timeout',
          managerPort: 1234,
        );
        harness.process.stdoutBytes(_connected);
        harness.process.stdoutBytes(_appStart('app-timeout'));
        await _flushEvents();

        await expectLater(
          worker.stop(),
          throwsA(
            isA<WorkerProcessException>().having(
              (error) => error.code,
              'code',
              WorkerFailureCode.stopTimedOut,
            ),
          ),
        );
        expect(worker.owned, isTrue);
        expect(failures.last.details['pid'], 4100);

        harness.process.onKill = (signal) {
          harness.process.completeExit(0);
          return true;
        };
        await worker.stop();
        expect(worker.owned, isFalse);
        expect(
          const LineSplitter().convert(harness.process.stdinText),
          hasLength(2),
        );
        await subscription.cancel();
        await worker.dispose();
      },
    );

    test(
      'late events from an old run cannot contaminate the new run',
      () async {
        final first = _FakeProcess(pid: 4101);
        final second = _FakeProcess(pid: 4102);
        final processes = <_FakeProcess>[first, second];
        var index = 0;
        final worker = FlutterWorkerProcess(
          processStarter:
              (
                _,
                _, {
                workingDirectory,
                environment,
                includeParentEnvironment = true,
                runInShell = false,
                mode = ProcessStartMode.normal,
              }) async => processes[index++],
        );
        final events = <WorkerEvent>[];
        final subscription = worker.events.listen(events.add);
        await worker.start(
          _configuration(),
          sessionId: 'old',
          managerPort: 1234,
        );
        first.completeExit(0);
        await worker.events.whereType<WorkerExitedEvent>().first;
        await worker.start(
          _configuration(),
          sessionId: 'new',
          managerPort: 1235,
        );

        first.stdoutBytes(_connected);
        first.stdoutBytes(_appStart('stale'));
        second.stdoutBytes(_connected);
        second.stdoutBytes(_appStart('fresh'));
        second.stdoutBytes(_appStarted('fresh'));
        await _flushEvents();

        expect(
          events.whereType<WorkerAppStartedEvent>().map((event) => event.appId),
          <String>['fresh'],
        );
        expect(
          events.whereType<WorkerAppStartedEvent>().single.sessionId,
          'new',
        );

        final secondExit = worker.events
            .whereType<WorkerExitedEvent>()
            .firstWhere((event) => event.sessionId == 'new');
        second.completeExit(0);
        await secondExit;
        await subscription.cancel();
        await worker.dispose();
      },
    );

    test('idle dispose rejects a simultaneous start before spawning', () async {
      var startCount = 0;
      final worker = FlutterWorkerProcess(
        processStarter:
            (
              _,
              _, {
              workingDirectory,
              environment,
              includeParentEnvironment = true,
              runInShell = false,
              mode = ProcessStartMode.normal,
            }) {
              startCount++;
              throw StateError('process starter must not be invoked');
            },
      );

      final dispose = worker.dispose();
      await expectLater(
        worker.start(
          _configuration(),
          sessionId: 'dispose-race',
          managerPort: 1234,
        ),
        throwsA(
          isA<WorkerProcessException>().having(
            (error) => error.code,
            'code',
            WorkerFailureCode.disposed,
          ),
        ),
      );
      await dispose;

      expect(startCount, 0);
    });

    test('dispose waits for a pending spawn and reaps its process', () async {
      final process = _FakeProcess(pid: 4103);
      final starterResult = Completer<Process>();
      var starterCalled = false;
      final worker = FlutterWorkerProcess(
        processStarter:
            (
              _,
              _, {
              workingDirectory,
              environment,
              includeParentEnvironment = true,
              runInShell = false,
              mode = ProcessStartMode.normal,
            }) {
              starterCalled = true;
              return starterResult.future;
            },
      );
      process.onKill = (_) {
        process.completeExit(0);
        return true;
      };

      final start = worker.start(
        _configuration(),
        sessionId: 'pending-spawn',
        managerPort: 1234,
      );
      expect(starterCalled, isTrue);
      final dispose = worker.dispose();
      var disposeCompleted = false;
      unawaited(dispose.then((_) => disposeCompleted = true));
      await _flushEvents();
      expect(disposeCompleted, isFalse);

      starterResult.complete(process);
      await start;
      await dispose;

      expect(process.signals, <ProcessSignal>[ProcessSignal.sigint]);
      expect(worker.owned, isFalse);
    });

    test(
      'stop waits for pending owned-group startup and contains it',
      () async {
        final process = _FakeProcess(pid: 4201);
        final ownership = _FakeOwnedProcessGroup(process, groupId: 4201);
        final starterResult = Completer<OwnedProcessGroup>();
        final worker = FlutterWorkerProcess(
          ownedProcessGroupStarter:
              (
                _,
                _, {
                workingDirectory,
                environment,
                includeParentEnvironment = true,
                runInShell = false,
                mode = ProcessStartMode.normal,
              }) => starterResult.future,
        );
        ownership.onSignal = (signal) {
          if (signal == ProcessSignal.sigint) {
            process.completeExit(0);
            ownership.completeExit();
          }
          return true;
        };

        final start = worker.start(
          _configuration(),
          sessionId: 'pending-owned-start',
          managerPort: 1234,
        );
        final stop = worker.stop();
        var stopCompleted = false;
        unawaited(stop.then((_) => stopCompleted = true));
        await _flushEvents();
        expect(stopCompleted, isFalse);

        starterResult.complete(ownership);
        await start;
        await stop;

        expect(ownership.signals, <ProcessSignal>[ProcessSignal.sigint]);
        expect(worker.owned, isFalse);
        await worker.dispose();
      },
    );

    test('dispose can retry cleanup after a stop timeout', () async {
      final harness = _ProcessHarness();
      final worker = FlutterWorkerProcess(
        processStarter: harness.start,
        gracefulStopTimeout: const Duration(milliseconds: 5),
        terminateTimeout: const Duration(milliseconds: 5),
        killTimeout: const Duration(milliseconds: 5),
      );
      harness.process.onKill = (_) => false;
      await worker.start(
        _configuration(),
        sessionId: 'dispose-retry',
        managerPort: 1234,
      );

      await expectLater(
        worker.dispose(),
        throwsA(
          isA<WorkerProcessException>().having(
            (error) => error.code,
            'code',
            WorkerFailureCode.stopTimedOut,
          ),
        ),
      );
      expect(worker.owned, isTrue);

      harness.process.onKill = (_) {
        harness.process.completeExit(0);
        return true;
      };
      await worker.dispose();
      expect(worker.owned, isFalse);
    });

    test(
      'exit before app.stop response completes without protocol failure',
      () async {
        final harness = _ProcessHarness();
        final worker = FlutterWorkerProcess(processStarter: harness.start);
        final events = <WorkerEvent>[];
        final subscription = worker.events.listen(events.add);
        await worker.start(
          _configuration(),
          sessionId: 'exit-before-response',
          managerPort: 1234,
        );
        harness.process.stdoutBytes(_connected);
        harness.process.stdoutBytes(_appStart('app-exiting'));
        await _flushEvents();

        final stop = worker.stop();
        await _flushEvents();
        harness.process.completeExit(0);
        await stop;
        harness.process.stdoutBytes('[{"id":1,"result":true}]\n');
        await _flushEvents();

        expect(events.whereType<WorkerFailureEvent>(), isEmpty);
        final exited = events.whereType<WorkerExitedEvent>().single;
        expect(exited.stopRequested, isTrue);
        expect(exited.appStopRequested, isTrue);
        expect(worker.owned, isFalse);
        await subscription.cancel();
        await worker.dispose();
      },
    );

    test(
      'dispose stops the worker, closes events, and is idempotent',
      () async {
        final harness = _ProcessHarness();
        final worker = FlutterWorkerProcess(processStarter: harness.start);
        harness.process.onKill = (_) {
          harness.process.completeExit(0);
          return true;
        };
        await worker.start(
          _configuration(),
          sessionId: 'dispose',
          managerPort: 1234,
        );
        final done = worker.events.drain<void>();

        await worker.dispose();
        await worker.dispose();

        await done;
        expect(worker.owned, isFalse);
        await expectLater(
          worker.start(_configuration(), sessionId: 'after', managerPort: 1234),
          throwsA(
            isA<WorkerProcessException>().having(
              (error) => error.code,
              'code',
              WorkerFailureCode.disposed,
            ),
          ),
        );
      },
    );
  });
}

LaunchConfiguration _configuration({
  String projectDirectory = '/project',
  Map<String, String> dartDefines = const <String, String>{},
}) => LaunchConfiguration(
  projectDirectory: projectDirectory,
  entrypoint: 'integration_test/flow with spaces.dart',
  flutterExecutable: '/sdk with spaces/bin/flutter',
  deviceId: 'macos',
  dartDefines: dartDefines,
);

const _connected =
    '[{"event":"daemon.connected","params":{"version":"0.6.1","pid":9123}}]\n';

String _appStart(String appId) =>
    '[{"event":"app.start","params":{"appId":"$appId","deviceId":"macos",'
    '"directory":"/project","supportsRestart":true,"launchMode":"run",'
    '"mode":"debug"}}]\n';

String _appStarted(String appId) =>
    '[{"event":"app.started","params":{"appId":"$appId"}}]\n';

String _debugPort(String appId, String wsUri) =>
    '[{"event":"app.debugPort","params":{"appId":"$appId","port":54321,'
    '"wsUri":"$wsUri","baseUri":"http://127.0.0.1:55111/token=/"}}]\n';

Future<void> _flushEvents() => Future<void>.delayed(Duration.zero);

class _ProcessHarness {
  final process = _FakeProcess(pid: 4100);
  int startCount = 0;
  String? executable;
  List<String>? arguments;
  String? workingDirectory;
  bool? runInShell;

  Future<Process> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async {
    startCount++;
    this.executable = executable;
    this.arguments = List<String>.of(arguments);
    this.workingDirectory = workingDirectory;
    this.runInShell = runInShell;
    return process;
  }
}

class _FakeProcess implements Process {
  _FakeProcess({required this.pid});

  @override
  final int pid;

  final _stdout = StreamController<List<int>>(sync: true);
  final _stderr = StreamController<List<int>>(sync: true);
  final Completer<int> _exitCode = Completer<int>();
  final _consumer = _RecordingConsumer();
  // The fake closes this from _createStdin when its exit future completes.
  // ignore: close_sinks
  late final IOSink _stdin = _createStdin();
  final signals = <ProcessSignal>[];
  bool Function(ProcessSignal signal)? onKill;

  String get stdinText => utf8.decode(_consumer.bytes);

  void stdoutBytes(String value) => _stdout.add(utf8.encode(value));
  void stderrBytes(String value) => _stderr.add(utf8.encode(value));
  void addStdoutChunk(List<int> value) => _stdout.add(value);

  void completeExit(int code) {
    if (!_exitCode.isCompleted) {
      _exitCode.complete(code);
    }
  }

  IOSink _createStdin() {
    final sink = IOSink(_consumer);
    unawaited(_exitCode.future.whenComplete(sink.close));
    return sink;
  }

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  IOSink get stdin => _stdin;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    return onKill?.call(signal) ?? true;
  }
}

class _FakeOwnedProcessGroup implements OwnedProcessGroup {
  _FakeOwnedProcessGroup(this.process, {required this.groupId});

  @override
  final _FakeProcess process;

  @override
  final int groupId;

  final _exit = Completer<void>();
  final signals = <ProcessSignal>[];
  bool Function(ProcessSignal signal)? onSignal;

  Future<OwnedProcessGroup> start(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
    bool includeParentEnvironment = true,
    bool runInShell = false,
    ProcessStartMode mode = ProcessStartMode.normal,
  }) async => this;

  void completeExit() {
    if (!_exit.isCompleted) {
      _exit.complete();
    }
  }

  @override
  Stream<List<int>> get stdout => process.stdout;

  @override
  Stream<List<int>> get stderr => process.stderr;

  @override
  bool signal(ProcessSignal signal) {
    signals.add(signal);
    return onSignal?.call(signal) ?? true;
  }

  @override
  Future<bool> waitForExit(Duration timeout) async {
    if (_exit.isCompleted) {
      return true;
    }
    try {
      await _exit.future.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

class _RecordingConsumer implements StreamConsumer<List<int>> {
  final bytes = <int>[];

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      bytes.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {}
}
