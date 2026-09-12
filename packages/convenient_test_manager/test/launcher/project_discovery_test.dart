import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:convenient_test_manager/launcher/launch_configuration.dart';
import 'package:convenient_test_manager/launcher/launcher_preferences.dart';
import 'package:convenient_test_manager/launcher/project_discovery.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'convenient test launcher ',
    );
  });

  tearDown(() async {
    if (temporaryDirectory.existsSync()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  Future<File> writeFile(String relativePath) async {
    final file = File(p.join(temporaryDirectory.path, relativePath));
    await file.create(recursive: true);
    await file.writeAsString('void main() {}');
    return file;
  }

  Future<String> createExecutable(String relativePath) async {
    final file = await writeFile(relativePath);
    final result = await Process.run('chmod', <String>['+x', file.path]);
    expect(result.exitCode, 0);
    return file.resolveSymbolicLinks();
  }

  group('ProjectDiscovery.entrypoints', () {
    test('rejects a directory without pubspec.yaml', () async {
      final discovery = ProjectDiscovery();

      await expectLater(
        discovery.entrypoints(temporaryDirectory.path),
        throwsA(
          isA<ProjectDiscoveryException>().having(
            (error) => error.code,
            'code',
            ProjectDiscoveryError.invalidProject,
          ),
        ),
      );
    });

    test('returns an empty list when integration_test is absent', () async {
      await _createProject(temporaryDirectory);

      expect(
        await ProjectDiscovery().entrypoints(temporaryDirectory.path),
        isEmpty,
      );
    });

    test('finds nested candidates in sorted project-relative form', () async {
      await _createProject(temporaryDirectory);
      await writeFile('integration_test/z test.dart');
      await writeFile('integration_test/nested/a_test.dart');
      await writeFile('integration_test/nested/not_a_test.txt');

      expect(
        await ProjectDiscovery().entrypoints(temporaryDirectory.path),
        <String>[
          'integration_test/nested/a_test.dart',
          'integration_test/z test.dart',
        ],
      );
    });

    test('does not list or validate a symlink outside the project', () async {
      await _createProject(temporaryDirectory);
      final externalDirectory = await Directory.systemTemp.createTemp(
        'convenient test external ',
      );
      addTearDown(() async {
        if (externalDirectory.existsSync()) {
          await externalDirectory.delete(recursive: true);
        }
      });
      final externalTest = File(p.join(externalDirectory.path, 'outside.dart'));
      await externalTest.writeAsString('void main() {}');
      final integrationDirectory = Directory(
        p.join(temporaryDirectory.path, 'integration_test'),
      );
      await integrationDirectory.create();
      await Link(
        p.join(integrationDirectory.path, 'external'),
      ).create(externalDirectory.path);
      await Link(
        p.join(integrationDirectory.path, 'outside.dart'),
      ).create(externalTest.path);
      final discovery = ProjectDiscovery();

      expect(await discovery.entrypoints(temporaryDirectory.path), isEmpty);
      await expectLater(
        discovery.validateEntrypoint(
          temporaryDirectory.path,
          'integration_test/outside.dart',
        ),
        throwsA(
          isA<ProjectDiscoveryException>().having(
            (error) => error.code,
            'code',
            ProjectDiscoveryError.entrypointOutsideProject,
          ),
        ),
      );
    });

    test('changing project cannot retain the old entrypoint', () async {
      final firstProject = Directory(p.join(temporaryDirectory.path, 'first'));
      final secondProject = Directory(
        p.join(temporaryDirectory.path, 'second'),
      );
      await _createProject(firstProject);
      await _createProject(secondProject);
      await File(
        p.join(firstProject.path, 'integration_test', 'worker.dart'),
      ).create(recursive: true);

      await expectLater(
        ProjectDiscovery().validateEntrypoint(
          secondProject.path,
          'integration_test/worker.dart',
        ),
        throwsA(
          isA<ProjectDiscoveryException>().having(
            (error) => error.code,
            'code',
            ProjectDiscoveryError.invalidEntrypoint,
          ),
        ),
      );
    });
  });

  group('ProjectDiscovery Flutter integration', () {
    test(
      'calls devices with machine arguments and returns sorted loopback targets',
      () async {
        final executable = await createExecutable('sdk/bin/flutter');
        late String capturedExecutable;
        late List<String> capturedArguments;
        late Map<String, String>? capturedEnvironment;
        late bool capturedIncludeParentEnvironment;
        late bool capturedRunInShell;
        final discovery = ProjectDiscovery(
          environment: const <String, String>{
            'HOME': '/Users/test',
            'PATH': '/usr/bin:/bin',
          },
          processStarter:
              (
                executable,
                arguments, {
                workingDirectory,
                environment,
                includeParentEnvironment = true,
                runInShell = false,
              }) async {
                capturedExecutable = executable;
                capturedArguments = arguments;
                capturedEnvironment = environment;
                capturedIncludeParentEnvironment = includeParentEnvironment;
                capturedRunInShell = runInShell;
                return _FakeProcess.completed(
                  stdout: jsonEncode(<Map<String, Object>>[
                    <String, Object>{
                      'id': 'macos',
                      'name': 'macOS',
                      'isSupported': true,
                      'targetPlatform': 'darwin',
                      'emulator': false,
                    },
                    <String, Object>{
                      'id': 'ios-simulator',
                      'name': 'iPhone 16 Pro',
                      'isSupported': true,
                      'targetPlatform': 'ios',
                      'emulator': true,
                    },
                    <String, Object>{
                      'id': 'physical-iphone',
                      'name': 'Bernhard’s iPhone',
                      'isSupported': true,
                      'targetPlatform': 'ios',
                      'emulator': false,
                    },
                    <String, Object>{
                      'id': 'android-emulator',
                      'name': 'sdk gphone64 arm64',
                      'isSupported': true,
                      'targetPlatform': 'android-arm64',
                      'emulator': true,
                    },
                    <String, Object>{
                      'id': 'chrome',
                      'name': 'Chrome',
                      'isSupported': true,
                      'targetPlatform': 'web-javascript',
                      'emulator': false,
                    },
                    <String, Object>{
                      'id': 'unsupported-macos',
                      'name': 'Unsupported macOS',
                      'isSupported': false,
                      'targetPlatform': 'darwin',
                      'emulator': false,
                    },
                    <String, Object>{
                      'id': 'unknown-platform',
                      'name': 'Unknown platform',
                      'isSupported': true,
                      'targetPlatform': 'unknown',
                      'emulator': false,
                    },
                    <String, Object>{
                      'id': 'missing-metadata',
                      'name': 'Missing metadata',
                    },
                  ]),
                );
              },
        );

        expect(
          await discovery.devices(executable),
          <({String id, String name})>[
            (id: 'ios-simulator', name: 'iPhone 16 Pro'),
            (id: 'macos', name: 'macOS'),
          ],
        );
        expect(capturedExecutable, executable);
        expect(capturedArguments, <String>['devices', '--machine']);
        expect(capturedEnvironment, <String, String>{
          'HOME': '/Users/test',
          'PATH': '/usr/bin:/bin',
        });
        expect(capturedIncludeParentEnvironment, isFalse);
        expect(capturedRunInShell, isFalse);
      },
    );

    test('orders equal-name simulator targets by stable device ID', () async {
      final executable = await createExecutable('sdk/bin/flutter');
      final discovery = ProjectDiscovery(
        processStarter:
            (
              executable,
              arguments, {
              workingDirectory,
              environment,
              includeParentEnvironment = true,
              runInShell = false,
            }) async => _FakeProcess.completed(
              stdout: jsonEncode(<Map<String, Object>>[
                <String, Object>{
                  'id': 'simulator-z',
                  'name': 'iPhone',
                  'isSupported': true,
                  'targetPlatform': 'ios',
                  'emulator': true,
                },
                <String, Object>{
                  'id': 'simulator-a',
                  'name': 'iPhone',
                  'isSupported': true,
                  'targetPlatform': 'ios',
                  'emulator': true,
                },
              ]),
            ),
      );

      expect(
        await discovery.devices(executable),
        const <({String id, String name})>[
          (id: 'simulator-a', name: 'iPhone'),
          (id: 'simulator-z', name: 'iPhone'),
        ],
      );
    });

    test('times out and terminates only its discovery process', () async {
      final executable = await createExecutable('sdk/bin/flutter');
      final process = _FakeProcess.hanging(exitAfterKills: 2);
      final discovery = ProjectDiscovery(
        processStarter:
            (
              executable,
              arguments, {
              workingDirectory,
              environment,
              includeParentEnvironment = true,
              runInShell = false,
            }) async => process,
        deviceDiscoveryTimeout: const Duration(milliseconds: 10),
        processTerminationTimeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        discovery.devices(executable),
        throwsA(
          isA<ProjectDiscoveryException>()
              .having(
                (error) => error.code,
                'code',
                ProjectDiscoveryError.deviceDiscoveryFailed,
              )
              .having((error) => error.details['path'], 'path', executable)
              .having(
                (error) => error.details['timeoutMilliseconds'],
                'timeoutMilliseconds',
                10,
              )
              .having(
                (error) => error.details['terminated'],
                'terminated',
                isTrue,
              ),
        ),
      );
      expect(process.killSignals, <ProcessSignal>[
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
      ]);
    });

    test('deadline includes a pending process starter', () async {
      final executable = await createExecutable('sdk/bin/flutter');
      final starter = Completer<Process>();
      final starterCalled = Completer<void>();
      final discovery = ProjectDiscovery(
        processStarter:
            (
              executable,
              arguments, {
              workingDirectory,
              environment,
              includeParentEnvironment = true,
              runInShell = false,
            }) {
              starterCalled.complete();
              return starter.future;
            },
        deviceDiscoveryTimeout: const Duration(milliseconds: 10),
        processTerminationTimeout: const Duration(milliseconds: 10),
      );
      final query = startDeviceDiscoveryQuery(discovery, executable);
      await starterCalled.future;

      await expectLater(
        query.result,
        throwsA(
          isA<ProjectDiscoveryException>()
              .having(
                (error) => error.details['timeoutMilliseconds'],
                'timeoutMilliseconds',
                10,
              )
              .having(
                (error) => error.details['terminated'],
                'terminated',
                isFalse,
              ),
        ),
      );

      expect(query.ownsProcess, isTrue);
      final lateProcess = _FakeProcess.hanging(exitAfterKills: 1);
      starter.complete(lateProcess);
      expect(await query.cancel(), isTrue);
      expect(query.ownsProcess, isFalse);
      expect(lateProcess.killSignals, [ProcessSignal.sigterm]);
    });

    test(
      'cancellation cleans a process whose starter completes late',
      () async {
        final executable = await createExecutable('sdk/bin/flutter');
        final starter = Completer<Process>();
        final starterCalled = Completer<void>();
        final discovery = ProjectDiscovery(
          processStarter:
              (
                executable,
                arguments, {
                workingDirectory,
                environment,
                includeParentEnvironment = true,
                runInShell = false,
              }) {
                starterCalled.complete();
                return starter.future;
              },
          deviceDiscoveryTimeout: const Duration(seconds: 1),
          processTerminationTimeout: const Duration(milliseconds: 10),
        );
        final query = startDeviceDiscoveryQuery(discovery, executable);
        final result = expectLater(
          query.result,
          throwsA(
            isA<ProjectDiscoveryException>().having(
              (error) => error.details['cancelled'],
              'cancelled',
              isTrue,
            ),
          ),
        );
        await starterCalled.future;

        expect(await query.cancel(), isFalse);
        expect(query.ownsProcess, isTrue);
        final lateProcess = _FakeProcess.hanging(exitAfterKills: 1);
        starter.complete(lateProcess);

        expect(await query.cancel(), isTrue);
        await result;
        expect(query.ownsProcess, isFalse);
        expect(lateProcess.killSignals, [ProcessSignal.sigterm]);
      },
    );

    test(
      'deadline covers a hanging stdin close and cleans the process',
      () async {
        final executable = await createExecutable('sdk/bin/flutter');
        final closeGate = Completer<void>();
        // The fake sink owns no resource; the query deliberately owns close.
        // ignore: close_sinks
        final sink = _FakeIoSink(closeGate: closeGate);
        final process = _FakeProcess.hanging(exitAfterKills: 1, stdin: sink);
        final discovery = ProjectDiscovery(
          processStarter:
              (
                executable,
                arguments, {
                workingDirectory,
                environment,
                includeParentEnvironment = true,
                runInShell = false,
              }) async => process,
          deviceDiscoveryTimeout: const Duration(milliseconds: 10),
          processTerminationTimeout: const Duration(milliseconds: 10),
        );

        await expectLater(
          discovery.devices(executable),
          throwsA(
            isA<ProjectDiscoveryException>().having(
              (error) => error.details['terminated'],
              'terminated',
              isTrue,
            ),
          ),
        );

        expect(sink.closeCalls, 1);
        expect(process.killSignals, [ProcessSignal.sigterm]);
        closeGate.complete();
      },
    );

    test('stdin close failure always cleans the acquired process', () async {
      final executable = await createExecutable('sdk/bin/flutter');
      final closeError = StateError('stdin close failed');
      // The fake sink owns no resource; the query deliberately owns close.
      // ignore: close_sinks
      final sink = _FakeIoSink(closeError: closeError);
      final process = _FakeProcess.hanging(exitAfterKills: 1, stdin: sink);
      final discovery = ProjectDiscovery(
        processStarter:
            (
              executable,
              arguments, {
              workingDirectory,
              environment,
              includeParentEnvironment = true,
              runInShell = false,
            }) async => process,
        deviceDiscoveryTimeout: const Duration(seconds: 1),
        processTerminationTimeout: const Duration(milliseconds: 10),
      );

      await expectLater(
        discovery.devices(executable),
        throwsA(
          isA<ProjectDiscoveryException>()
              .having(
                (error) => error.details['error'],
                'error',
                same(closeError),
              )
              .having(
                (error) => error.details['terminated'],
                'terminated',
                isTrue,
              ),
        ),
      );

      expect(process.killSignals, [ProcessSignal.sigterm]);
    });

    test(
      'unconfirmed termination retains ownership for cleanup retry',
      () async {
        final executable = await createExecutable('sdk/bin/flutter');
        final process = _FakeProcess.hanging(exitAfterKills: 4);
        final discovery = ProjectDiscovery(
          processStarter:
              (
                executable,
                arguments, {
                workingDirectory,
                environment,
                includeParentEnvironment = true,
                runInShell = false,
              }) async => process,
          deviceDiscoveryTimeout: const Duration(milliseconds: 10),
          processTerminationTimeout: const Duration(milliseconds: 10),
        );
        final query = startDeviceDiscoveryQuery(discovery, executable);

        await expectLater(
          query.result,
          throwsA(
            isA<ProjectDiscoveryException>().having(
              (error) => error.details['terminated'],
              'terminated',
              isFalse,
            ),
          ),
        );
        expect(query.ownsProcess, isTrue);

        expect(await query.cancel(), isTrue);
        expect(query.ownsProcess, isFalse);
        expect(process.killSignals, <ProcessSignal>[
          ProcessSignal.sigterm,
          ProcessSignal.sigkill,
          ProcessSignal.sigterm,
          ProcessSignal.sigkill,
        ]);
      },
    );

    test('resolves explicit, FVM, saved and PATH SDKs in order', () async {
      await _createProject(temporaryDirectory);
      final explicit = await createExecutable('explicit/flutter');
      final fvm = await createExecutable('.fvm/flutter_sdk/bin/flutter');
      final saved = await createExecutable('saved/flutter');
      final pathSdk = await createExecutable('path sdk/flutter');
      final discovery = ProjectDiscovery(
        environment: <String, String>{'PATH': p.dirname(pathSdk)},
      );

      expect(
        await discovery.resolveFlutterExecutable(
          projectDirectory: temporaryDirectory.path,
          explicitFlutterExecutable: explicit,
          savedFlutterExecutable: saved,
        ),
        await File(explicit).resolveSymbolicLinks(),
      );
      expect(
        await discovery.resolveFlutterExecutable(
          projectDirectory: temporaryDirectory.path,
          savedFlutterExecutable: saved,
        ),
        await File(fvm).resolveSymbolicLinks(),
      );
      await File(fvm).delete();
      expect(
        await discovery.resolveFlutterExecutable(
          projectDirectory: temporaryDirectory.path,
          savedFlutterExecutable: saved,
        ),
        await File(saved).resolveSymbolicLinks(),
      );
      await File(saved).delete();
      expect(
        await discovery.resolveFlutterExecutable(
          projectDirectory: temporaryDirectory.path,
        ),
        await File(pathSdk).resolveSymbolicLinks(),
      );
    });

    test('exposes failure when no Flutter SDK is available', () async {
      await _createProject(temporaryDirectory);
      final discovery = ProjectDiscovery(
        environment: <String, String>{'PATH': temporaryDirectory.path},
      );

      await expectLater(
        discovery.resolveFlutterExecutable(
          projectDirectory: temporaryDirectory.path,
          savedFlutterExecutable: p.join(temporaryDirectory.path, 'stale'),
        ),
        throwsA(isA<FlutterSdkNotFoundException>()),
      );
    });
  });

  group('LauncherPreferences', () {
    test('round-trips schema 1 and keeps Dart defines literal', () async {
      await _createProject(temporaryDirectory);
      final entrypoint = await writeFile('integration_test/a test.dart');
      final flutterExecutable = await createExecutable('sdk path/bin/flutter');
      final preferencesPath = p.join(
        temporaryDirectory.path,
        'application support',
        'launcher.json',
      );
      final preferences = LauncherPreferences(filePath: preferencesPath);
      final configuration = LaunchConfiguration(
        projectDirectory: await temporaryDirectory.resolveSymbolicLinks(),
        entrypoint: p.relative(entrypoint.path, from: temporaryDirectory.path),
        flutterExecutable: flutterExecutable,
        deviceId: 'macos',
        dartDefines: <String, String>{
          'DOLLAR': r'$HOME is literal',
          'QUOTED': '"two words"',
        },
      );

      await preferences.save(configuration);

      expect(await preferences.load(), configuration);
      expect(preferences.diagnostic, isNull);
      final decoded = jsonDecode(await File(preferencesPath).readAsString());
      expect(decoded, containsPair('schemaVersion', 1));
      expect(
        Directory(
          p.dirname(preferencesPath),
        ).listSync().where((entry) => entry.path.contains('.tmp-')),
        isEmpty,
      );
    });

    test('malformed JSON is ignored with a diagnostic', () async {
      final preferencesFile = File(
        p.join(temporaryDirectory.path, 'prefs.json'),
      );
      await preferencesFile.writeAsString('{broken');
      final preferences = LauncherPreferences(filePath: preferencesFile.path);

      expect(await preferences.load(), isNull);
      expect(
        preferences.diagnostic?.code,
        LauncherPreferencesDiagnosticCode.malformedJson,
      );
    });

    test('unknown schemas are ignored with a diagnostic', () async {
      final preferencesFile = File(
        p.join(temporaryDirectory.path, 'prefs.json'),
      );
      await preferencesFile.writeAsString(
        jsonEncode(<String, Object>{'schemaVersion': 99}),
      );
      final preferences = LauncherPreferences(filePath: preferencesFile.path);

      expect(await preferences.load(), isNull);
      expect(
        preferences.diagnostic?.code,
        LauncherPreferencesDiagnosticCode.unsupportedVersion,
      );
    });

    test('stale saved paths are ignored with a diagnostic', () async {
      final preferencesFile = File(
        p.join(temporaryDirectory.path, 'prefs.json'),
      );
      await preferencesFile.writeAsString(
        jsonEncode(<String, Object>{
          'schemaVersion': 1,
          'projectDirectory': p.join(temporaryDirectory.path, 'gone'),
          'entrypoint': 'integration_test/gone.dart',
          'flutterExecutable': p.join(temporaryDirectory.path, 'gone-flutter'),
          'deviceId': 'macos',
          'dartDefines': <String, String>{},
        }),
      );
      final preferences = LauncherPreferences(filePath: preferencesFile.path);

      expect(await preferences.load(), isNull);
      expect(
        preferences.diagnostic?.code,
        LauncherPreferencesDiagnosticCode.staleConfiguration,
      );
    });
  });
}

class _FakeProcess implements Process {
  _FakeProcess.completed({
    required String stdout,
    String stderr = '',
    IOSink? stdin,
  }) : _exitAfterKills = 0,
       _stdin = stdin ?? _FakeIoSink() {
    _stdout.add(systemEncoding.encode(stdout));
    _stderr.add(systemEncoding.encode(stderr));
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    _exitCode.complete(0);
  }

  _FakeProcess.hanging({required int exitAfterKills, IOSink? stdin})
    : assert(exitAfterKills > 0),
      _exitAfterKills = exitAfterKills,
      _stdin = stdin ?? _FakeIoSink();

  final int _exitAfterKills;
  final Completer<int> _exitCode = Completer<int>();
  // The fake sink owns no resource; its close method is deliberately a no-op.
  // ignore: close_sinks
  final IOSink _stdin;
  final StreamController<List<int>> _stdout = StreamController<List<int>>();
  final StreamController<List<int>> _stderr = StreamController<List<int>>();
  final List<ProcessSignal> killSignals = <ProcessSignal>[];

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 1234;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (_exitCode.isCompleted) {
      return false;
    }
    killSignals.add(signal);
    if (killSignals.length >= _exitAfterKills) {
      unawaited(_stdout.close());
      unawaited(_stderr.close());
      _exitCode.complete(-signal.signalNumber);
    }
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeIoSink implements IOSink {
  _FakeIoSink({this.closeGate, this.closeError});

  final Completer<void>? closeGate;
  final Object? closeError;
  int closeCalls = 0;

  @override
  Future<void> close() {
    closeCalls++;
    final error = closeError;
    if (error != null) return Future<void>.error(error);
    return closeGate?.future ?? Future<void>.value();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _createProject(Directory directory) async {
  await directory.create(recursive: true);
  await File(
    p.join(directory.path, 'pubspec.yaml'),
  ).writeAsString('name: launcher_fixture\n');
}
