import 'dart:async';

import 'package:convenient_test/convenient_test.dart';
import 'package:convenient_test_dev/convenient_test_dev.dart';
import 'package:convenient_test_manager/build/generated/launcher_l10n/launcher_localizations.dart';
import 'package:convenient_test_manager/launcher/flutter_worker_process.dart';
import 'package:convenient_test_manager/launcher/launch_configuration.dart';
import 'package:convenient_test_manager/launcher/launcher_controller.dart';
import 'package:convenient_test_manager/launcher/launcher_panel.dart';
import 'package:convenient_test_manager/launcher/launcher_preferences.dart';
import 'package:convenient_test_manager/launcher/launcher_session_bar.dart';
import 'package:convenient_test_manager/launcher/launcher_session_services.dart';
import 'package:convenient_test_manager/launcher/project_discovery.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> main() => runLauncherConvenientTest();

Future<void> runLauncherConvenientTest({
  ExecutionEnv executionEnv = ExecutionEnv.deviceTest,
}) async {
  final slot = _LauncherConvenientTestSlot();

  await convenientTestMain(slot, () {
    tTestWidgets(
      'project, nested test and iOS simulator start an isolated session',
      (t) async {
        await find.bySemanticsIdentifier('launcher.project.choose').tap();
        await find.text('/fixtures/launcher_project').should(findsOneWidget);

        await find.bySemanticsIdentifier('launcher.test.select').tap();
        await find
            .text('integration_test/nested/launcher_test.dart')
            .last
            .tap();
        await find.bySemanticsIdentifier('launcher.device.select').tap();
        await find.text('iPhone 16 Pro').last.tap();
        await find.bySemanticsIdentifier('launcher.start').tap();
        await find
            .bySemanticsIdentifier('launcher.stop')
            .should(findsOneWidget);

        final harness = slot.harness;
        expect(harness.controller.state, LauncherState.running);
        expect(harness.controller.session?.external, isFalse);
        expect(harness.controller.session?.managerPort, 46123);
        expect(harness.services.requestedPorts, const <int>[0]);
        expect(
          harness.worker.startedConfiguration,
          LaunchConfiguration(
            projectDirectory: '/fixtures/launcher_project',
            entrypoint: 'integration_test/nested/launcher_test.dart',
            flutterExecutable: '/fixtures/flutter/bin/flutter',
            deviceId: 'ios-simulator',
          ),
        );
        expect(harness.worker.startedManagerPort, 46123);
        expect(harness.worker.startedSessionId, 'launcher-ux-session');

        await find.bySemanticsIdentifier('launcher.stop').tap();
        await find
            .bySemanticsIdentifier('launcher.start')
            .should(findsOneWidget);
        expect(harness.controller.state, LauncherState.idle);
        expect(harness.controller.session, isNull);
      },
    );
  }, executionEnv: executionEnv);
}

final class _LauncherConvenientTestSlot extends ConvenientTestSlot {
  final navigatorKey = GlobalKey<NavigatorState>();
  late _LauncherHarness harness;
  _LauncherHarness? _previousHarness;

  @override
  Future<void> appMain(AppMainExecuteMode mode) async {
    await _previousHarness?.dispose();
    harness = _LauncherHarness(navigatorKey: navigatorKey);
    _previousHarness = harness;
    runApp(harness.buildApp());
  }

  @override
  BuildContext? getNavContext(ConvenientTest t) => navigatorKey.currentContext;
}

final class _LauncherHarness {
  _LauncherHarness({required this.navigatorKey})
    : worker = _HarnessWorkerProcess(),
      services = _HarnessSessionServices() {
    controller = LauncherController(
      discovery: _HarnessDiscovery(),
      preferences: _HarnessPreferences(),
      process: worker,
      sessionServices: services,
      reportRootDirectory: '/fixtures/reports',
      readinessTimeout: const Duration(seconds: 2),
      sessionIdFactory: () => 'launcher-ux-session',
    );
  }

  final GlobalKey<NavigatorState> navigatorKey;
  final _HarnessWorkerProcess worker;
  final _HarnessSessionServices services;
  late final LauncherController controller;

  Widget buildApp() => ConvenientTestWrapperWidget(
    child: MaterialApp(
      navigatorKey: navigatorKey,
      locale: const Locale('en'),
      localizationsDelegates: LauncherLocalizations.localizationsDelegates,
      supportedLocales: LauncherLocalizations.supportedLocales,
      home: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            children: <Widget>[
              LauncherSessionBar(controller: controller),
              Expanded(
                child: LauncherPanel(
                  controller: controller,
                  chooseProjectDirectory: () async =>
                      '/fixtures/launcher_project',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> dispose() => controller.shutdown();
}

final class _HarnessDiscovery implements ProjectDiscovery {
  @override
  Future<String> canonicalProjectDirectory(String projectDirectory) async =>
      projectDirectory;

  @override
  Future<List<String>> entrypoints(String projectDirectory) async =>
      const <String>[
        'integration_test/a_test.dart',
        'integration_test/nested/launcher_test.dart',
      ];

  @override
  Future<String> resolveFlutterExecutable({
    required String projectDirectory,
    String? explicitFlutterExecutable,
    String? savedFlutterExecutable,
  }) async => '/fixtures/flutter/bin/flutter';

  @override
  Future<List<({String id, String name})>> devices(
    String flutterExecutable,
  ) async => const <({String id, String name})>[
    (id: 'ios-simulator', name: 'iPhone 16 Pro'),
    (id: 'macos', name: 'Local macOS'),
  ];

  @override
  Future<String> validateEntrypoint(
    String projectDirectory,
    String entrypoint,
  ) async => entrypoint;
}

final class _HarnessPreferences implements LauncherPreferences {
  @override
  LauncherPreferencesDiagnostic? diagnostic;

  @override
  String get filePath => '/fixtures/launcher_preferences.json';

  @override
  Future<LaunchConfiguration?> load() async => null;

  @override
  Future<void> save(LaunchConfiguration configuration) async {}
}

final class _HarnessWorkerProcess implements LauncherWorkerProcess {
  final _events = StreamController<WorkerEvent>.broadcast(sync: true);
  var _runId = 0;
  var _owned = false;
  String? _sessionId;

  LaunchConfiguration? startedConfiguration;
  String? startedSessionId;
  int? startedManagerPort;

  @override
  Stream<WorkerEvent> get events => _events.stream;

  @override
  int? get currentRunId => _runId == 0 ? null : _runId;

  @override
  List<WorkerLogEvent> get logs => const <WorkerLogEvent>[];

  @override
  bool get owned => _owned;

  @override
  int? get ownedPid => _owned ? 4123 : null;

  @override
  Future<void> start(
    LaunchConfiguration configuration, {
    required String sessionId,
    required int managerPort,
  }) async {
    startedConfiguration = configuration;
    startedSessionId = sessionId;
    startedManagerPort = managerPort;
    _sessionId = sessionId;
    _runId++;
    _owned = true;
    scheduleMicrotask(() {
      if (_events.isClosed || !_owned) return;
      _events
        ..add(
          WorkerAppStartedEvent(
            runId: _runId,
            sessionId: _sessionId!,
            appId: 'launcher-harness-app',
          ),
        )
        ..add(
          WorkerDebugPortEvent(
            runId: _runId,
            sessionId: _sessionId!,
            appId: 'launcher-harness-app',
            vmServiceUri: Uri.parse('ws://127.0.0.1:48123/token/ws'),
            baseUri: null,
            port: 48123,
          ),
        );
    });
  }

  @override
  Future<void> stop() async => _owned = false;

  @override
  Future<void> dispose() async {
    _owned = false;
    await _events.close();
  }
}

final class _HarnessSessionServices implements LauncherSessionServices {
  final requestedPorts = <int>[];
  var _generation = 0;

  @override
  int? boundPort;

  @override
  bool connected = false;

  @override
  Future<int> bind({required int port}) async {
    requestedPorts.add(port);
    boundPort = 46123;
    return boundPort!;
  }

  @override
  Future<int> prepareSession({required String reportPath}) async =>
      ++_generation;

  @override
  Future<void> connect({required Uri uri}) async => connected = true;

  @override
  Future<void> waitUntilReady({
    required int generation,
    required Duration timeout,
  }) async {}

  @override
  Future<void> disconnect() async => connected = false;

  @override
  Future<void> shutdownListener() async => boundPort = null;

  @override
  Future<void> restoreGlobalConfiguration() async {}
}
