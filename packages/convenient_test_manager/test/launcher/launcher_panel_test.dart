import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:convenient_test_manager/build/generated/launcher_l10n/launcher_localizations.dart';
import 'package:convenient_test_manager/launcher/flutter_worker_process.dart';
import 'package:convenient_test_manager/launcher/launch_configuration.dart';
import 'package:convenient_test_manager/launcher/launcher_controller.dart';
import 'package:convenient_test_manager/launcher/launcher_panel.dart';
import 'package:convenient_test_manager/launcher/launcher_preferences.dart';
import 'package:convenient_test_manager/launcher/launcher_session_bar.dart';
import 'package:convenient_test_manager/launcher/launcher_session_services.dart';
import 'package:convenient_test_manager/launcher/project_discovery.dart';
import 'package:convenient_test_manager/main.dart';
import 'package:convenient_test_manager/misc/setup.dart';
import 'package:convenient_test_manager/pages/home_page.dart';
import 'package:convenient_test_manager/services/misc_flutter_service.dart';
import 'package:convenient_test_manager/stores/home_page_store.dart';
import 'package:convenient_test_manager_dart/services/vm_service_wrapper_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../fake_vm_service_wrapper.dart';

void main() {
  late FakeVmServiceWrapper appVmService;

  setUpAll(() async {
    await setup(
      registerVmServiceWrapper: false,
      startManagerServer: false,
      autoConnectVm: false,
      initializeLauncher: false,
      parseConfigFile: false,
      initVLC: false,
    );
    appVmService = FakeVmServiceWrapper();
    getIt.registerSingleton<VmServiceWrapperService>(appVmService);
  });

  tearDown(() async {
    getIt.get<HomePageStore>().displayLoadedReportMode = false;
    if (getIt.isRegistered<LauncherController>()) {
      final controller = getIt.get<LauncherController>();
      await controller.stop();
      await getIt.unregister<LauncherController>();
    }
    await appVmService.connect();
  });

  testWidgets('localized controls expose stable semantics and cancellation', (
    tester,
  ) async {
    final fixture = _Fixture();
    fixture.worker.logs.add(_logEvent());
    final semantics = tester.ensureSemantics();
    try {
      await _pumpLauncher(
        tester,
        fixture.controller,
        chooseProjectDirectory: () async => null,
      );

      expect(find.text('Worker launcher'), findsOneWidget);
      expect(find.bySemanticsIdentifier('launcher.project.choose'), findsOne);
      expect(find.bySemanticsIdentifier('launcher.test.select'), findsOne);
      expect(find.bySemanticsIdentifier('launcher.device.select'), findsOne);
      expect(find.bySemanticsIdentifier('launcher.load_report'), findsOne);
      expect(find.bySemanticsIdentifier('launcher.start'), findsOne);
      expect(find.bySemanticsIdentifier('launcher.logs'), findsOne);

      await tester.tap(find.bySemanticsIdentifier('launcher.project.choose'));
      await tester.pump();
      expect(find.text('Selection cancelled.'), findsOneWidget);
      expect(fixture.discovery.projectRequests, isEmpty);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('picker failure is handled and preserves the selection', (
    tester,
  ) async {
    final fixture = _Fixture();
    await _selectValid(fixture.controller);
    final projectDirectory = fixture.controller.selection.projectDirectory;
    final flutterExecutable = fixture.controller.selection.flutterExecutable;
    await _pumpLauncher(
      tester,
      fixture.controller,
      chooseProjectDirectory: () async => throw PlatformException(
        code: 'ENTITLEMENT_NOT_FOUND',
        message: 'sensitive native details',
      ),
    );

    await tester.tap(find.bySemanticsIdentifier('launcher.project.choose'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'Could not open the file picker. '
        'Check macOS file access permissions and try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Selection cancelled.'), findsNothing);
    expect(find.textContaining('sensitive native details'), findsNothing);
    expect(tester.takeException(), isNull);
    expect(fixture.controller.selection.projectDirectory, projectDirectory);
    expect(fixture.controller.selection.flutterExecutable, flutterExecutable);
  });

  testWidgets('pending picker disables both picker actions and ignores taps', (
    tester,
  ) async {
    final fixture = _Fixture();
    await _selectValid(fixture.controller);
    final projectDirectory = fixture.controller.selection.projectDirectory;
    final flutterExecutable = fixture.controller.selection.flutterExecutable;
    final picker = Completer<String?>();
    var pickerCalls = 0;
    await _pumpLauncher(
      tester,
      fixture.controller,
      chooseProjectDirectory: () {
        pickerCalls++;
        return picker.future;
      },
    );
    await tester.tap(find.text('SDK and Dart defines'));
    await tester.pumpAndSettle();

    final projectButton = find.widgetWithText(OutlinedButton, 'Choose project');
    final sdkButton = find.widgetWithText(OutlinedButton, 'Choose Flutter SDK');
    await tester.tap(projectButton);
    await tester.pump();

    expect(pickerCalls, 1);
    expect(tester.widget<OutlinedButton>(projectButton).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(sdkButton).onPressed, isNull);
    await tester.tap(projectButton);
    await tester.pump();
    expect(pickerCalls, 1);

    picker.complete(null);
    await tester.pumpAndSettle();

    expect(find.text('Selection cancelled.'), findsOneWidget);
    expect(tester.widget<OutlinedButton>(projectButton).onPressed, isNotNull);
    expect(tester.widget<OutlinedButton>(sdkButton).onPressed, isNotNull);
    expect(fixture.controller.selection.projectDirectory, projectDirectory);
    expect(fixture.controller.selection.flutterExecutable, flutterExecutable);
  });

  testWidgets('project, SDK, test and device selection enable Start', (
    tester,
  ) async {
    final fixture = _Fixture();
    await _pumpLauncher(
      tester,
      fixture.controller,
      chooseProjectDirectory: () async => '/projects/app',
      chooseFlutterExecutable: () async => '/alternate/flutter',
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Choose project'));
    await tester.pumpAndSettle();
    expect(find.text('/projects/app'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>).at(0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('integration_test/example_test.dart').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('SDK and Dart defines'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsIdentifier('launcher.sdk.choose'), findsOne);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Choose Flutter SDK'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(DropdownButtonFormField<String>).at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Local macOS').last);
    await tester.pumpAndSettle();

    expect(
      fixture.controller.selection.flutterExecutable,
      '/alternate/flutter',
    );
    expect(fixture.controller.canStart, isTrue);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets(
    'pending Dart-define save keeps focus, persists latest text, and blocks Start',
    (tester) async {
      final fixture = _Fixture();
      await _selectValid(fixture.controller);
      fixture.preferences
        ..savedConfigurations.clear()
        ..saveGate = Completer<void>();
      await _pumpLauncher(tester, fixture.controller);
      await tester.tap(find.text('SDK and Dart defines'));
      await tester.pumpAndSettle();
      final definesField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Dart defines',
      );

      await tester.tap(definesField);
      await tester.enterText(definesField, 'PROFILE=');
      await tester.pump();

      expect(fixture.controller.selection.saving, isTrue);
      expect(tester.widget<TextField>(definesField).enabled, isTrue);
      expect(
        tester.widget<TextField>(definesField).focusNode!.hasFocus,
        isTrue,
      );
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
            .onPressed,
        isNull,
      );

      await tester.enterText(definesField, 'PROFILE=gui test');
      await tester.pump();

      expect(
        tester.widget<TextField>(definesField).controller!.text,
        'PROFILE=gui test',
      );
      expect(
        tester.widget<TextField>(definesField).focusNode!.hasFocus,
        isTrue,
      );
      expect(fixture.controller.selection.dartDefines, {'PROFILE': 'gui test'});

      fixture.preferences.saveGate!.complete();
      await _pumpUntil(tester, () => !fixture.controller.selection.saving);
      await tester.pump();

      expect(
        fixture.preferences.savedConfigurations.map(
          (configuration) => configuration.dartDefines,
        ),
        [
          {'PROFILE': ''},
          {'PROFILE': 'gui test'},
        ],
      );
      expect(fixture.preferences.value?.dartDefines, {'PROFILE': 'gui test'});
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'selected nested test and iOS simulator reach one managed launch',
    (tester) async {
      final fixture = _Fixture(
        discovery: _FakeDiscovery(
          entrypointResults: const <String>[
            'integration_test/a_test.dart',
            'integration_test/nested/launcher_test.dart',
          ],
          deviceResults: const <({String id, String name})>[
            (id: 'ios-simulator', name: 'iPhone 16 Pro'),
            (id: 'macos', name: 'Local macOS'),
          ],
        ),
      );
      await _pumpLauncher(
        tester,
        fixture.controller,
        chooseProjectDirectory: () async => '/projects/app',
      );

      await tester.tap(find.bySemanticsIdentifier('launcher.project.choose'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsIdentifier('launcher.test.select'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.text('integration_test/nested/launcher_test.dart').last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsIdentifier('launcher.device.select'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('iPhone 16 Pro').last);
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsIdentifier('launcher.start'));
      await _pumpUntil(
        tester,
        () => fixture.worker.startedConfiguration != null,
      );
      fixture.worker.emitReady();
      await tester.pumpAndSettle();

      expect(fixture.controller.state, LauncherState.running);
      expect(fixture.controller.session?.external, isFalse);
      expect(fixture.controller.session?.managerPort, 46000);
      expect(fixture.services.bindPorts, const <int>[0]);
      expect(
        fixture.worker.startedConfiguration,
        LaunchConfiguration(
          projectDirectory: '/projects/app',
          entrypoint: 'integration_test/nested/launcher_test.dart',
          flutterExecutable: '/sdk/flutter',
          deviceId: 'ios-simulator',
        ),
      );
      expect(fixture.worker.startedManagerPort, 46000);
      expect(fixture.worker.startedSessionId, isNotEmpty);
      expect(find.bySemanticsIdentifier('launcher.stop'), findsOneWidget);

      await tester.tap(find.bySemanticsIdentifier('launcher.stop'));
      await tester.pumpAndSettle();
      expect(fixture.controller.state, LauncherState.idle);
      expect(fixture.controller.session, isNull);
    },
  );

  testWidgets(
    'disconnected Load Report reads the tracked report without a session',
    (tester) async {
      final fixture = _Fixture();
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final reportPath = File('test/report.bin').absolute.path;
      expect(File(reportPath).existsSync(), isTrue);
      getIt.registerSingleton<LauncherController>(fixture.controller);
      await appVmService.disconnect();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: LauncherLocalizations.localizationsDelegates,
          supportedLocales: LauncherLocalizations.supportedLocales,
          home: HomePage(
            chooseReportPath: () async => reportPath,
            readReport: (path, isCurrent) async {
              await getIt
                  .get<MiscFlutterService>()
                  .pickFileAndReadReportWithAuthority(
                    pathOverride: path,
                    readSync: true,
                    clear: false,
                    isCurrent: isCurrent,
                  );
            },
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(LauncherPanel), findsOneWidget);
      final loadReport = find.bySemanticsIdentifier('launcher.load_report');
      await tester.ensureVisible(loadReport);
      await tester.tap(loadReport);
      await _pumpUntil(tester, () => !fixture.controller.isLoadingReport);
      await tester.pump();

      expect(find.text('Loaded Report Displayer'), findsOneWidget);
      expect(find.byType(LauncherPanel), findsNothing);
      expect(fixture.worker.startCalls, 0);
      expect(fixture.services.bindPorts, isEmpty);
      expect(fixture.services.connectUris, isEmpty);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(LauncherPanel), findsOneWidget);
      expect(find.bySemanticsIdentifier('launcher.load_report'), findsOne);
    },
  );

  testWidgets(
    'production report reader keeps malformed-report failure and retry visible',
    (tester) async {
      final fixture = _Fixture();
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final directory = Directory.systemTemp.createTempSync(
        'launcher-malformed-report-',
      );
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final reportPath = '${directory.path}/malformed.bin';
      File(reportPath).writeAsBytesSync([0x80]);
      getIt.registerSingleton<LauncherController>(fixture.controller);
      await appVmService.disconnect();

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: LauncherLocalizations.localizationsDelegates,
          supportedLocales: LauncherLocalizations.supportedLocales,
          home: HomePage(chooseReportPath: () async => reportPath),
        ),
      );
      await tester.pump();

      await tester.runAsync(
        () => fixture.controller.loadReport(
          choosePath: () async => reportPath,
          readReport: readLauncherReport,
        ),
      );
      await tester.pump();

      expect(
        find.textContaining('The selected report could not be loaded:'),
        findsOneWidget,
      );
      expect(getIt.get<HomePageStore>().displayLoadedReportMode, isFalse);
      expect(find.byType(LauncherPanel), findsOneWidget);
      expect(find.bySemanticsIdentifier('launcher.load_report'), findsOne);
      expect(fixture.controller.canLoadReport, isTrue);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Load Report'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('report picker cancellation preserves launcher selections', (
    tester,
  ) async {
    final fixture = _Fixture();
    await _selectValid(fixture.controller);
    final before = fixture.controller.selection;
    var reads = 0;
    await _pumpLauncher(
      tester,
      fixture.controller,
      chooseReportPath: () async => null,
      readReport: (_, _) async => reads++,
    );

    await tester.tap(find.bySemanticsIdentifier('launcher.load_report'));
    await tester.pumpAndSettle();

    expect(reads, 0);
    _expectSelectionUnchanged(fixture.controller.selection, before);
    expect(fixture.controller.error, isNull);
    expect(fixture.controller.canLoadReport, isTrue);
  });

  testWidgets('report read failure is localized and preserves selections', (
    tester,
  ) async {
    final fixture = _Fixture();
    await _selectValid(fixture.controller);
    final before = fixture.controller.selection;
    await _pumpLauncher(
      tester,
      fixture.controller,
      chooseReportPath: () async => '/reports/broken.bin',
      readReport: (_, _) async =>
          throw const FormatException('invalid payload'),
    );

    await tester.tap(find.bySemanticsIdentifier('launcher.load_report'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('The selected report could not be loaded:'),
      findsOneWidget,
    );
    expect(find.textContaining('invalid payload'), findsOneWidget);
    _expectSelectionUnchanged(fixture.controller.selection, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending report picker disables launcher actions', (
    tester,
  ) async {
    final fixture = _Fixture();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _selectValid(fixture.controller);
    final picker = Completer<String?>();
    await _pumpLauncher(
      tester,
      fixture.controller,
      chooseReportPath: () => picker.future,
      readReport: (_, _) async {},
    );
    await tester.tap(find.text('Existing worker connection'));
    await tester.pumpAndSettle();

    await tester.tap(find.bySemanticsIdentifier('launcher.load_report'));
    await tester.pump();

    expect(fixture.controller.isLoadingReport, isTrue);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Choose project'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Connect to existing worker'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Loading report…'),
          )
          .onPressed,
      isNull,
    );

    picker.complete(null);
    await tester.pumpAndSettle();
    expect(fixture.controller.canStart, isTrue);
    expect(fixture.controller.canLoadReport, isTrue);
  });

  testWidgets('busy state disables mutation and Start while Stop remains', (
    tester,
  ) async {
    final fixture = _Fixture();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _selectValid(fixture.controller);
    await _pumpLauncher(tester, fixture.controller);
    await tester.tap(find.text('SDK and Dart defines'));
    await tester.pumpAndSettle();
    final definesField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField && widget.decoration?.labelText == 'Dart defines',
    );

    unawaited(fixture.controller.start());
    await tester.pump();
    await tester.pump();

    expect(fixture.controller.state, LauncherState.starting);
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Choose project'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'))
          .onPressed,
      isNull,
    );
    expect(tester.widget<TextField>(definesField).enabled, isFalse);
    expect(find.bySemanticsIdentifier('launcher.stop'), findsOne);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Stop'))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
    await tester.pumpAndSettle();
    expect(fixture.controller.state, LauncherState.idle);
  });

  testWidgets('cleanup failure keeps diagnostics and a working retry', (
    tester,
  ) async {
    final fixture = _Fixture();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _selectValid(fixture.controller);
    await _pumpLauncher(tester, fixture.controller);
    unawaited(fixture.controller.start());
    await tester.pump();
    await tester.pump();
    fixture.worker.failStop = true;

    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
    await tester.pumpAndSettle();

    expect(fixture.controller.state, LauncherState.failed);
    expect(fixture.controller.canRetryCleanup, isTrue);
    expect(find.textContaining('Owned process 12345'), findsWidgets);
    expect(find.widgetWithText(OutlinedButton, 'Retry'), findsOneWidget);

    fixture.worker.failStop = false;
    await tester.tap(find.widgetWithText(OutlinedButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(fixture.controller.state, LauncherState.idle);
    expect(fixture.controller.session, isNull);
  });

  testWidgets('external connection is explicit and disconnects without Stop', (
    tester,
  ) async {
    final fixture = _Fixture();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpLauncher(tester, fixture.controller);
    expect(fixture.services.bindPorts, isEmpty);

    await tester.tap(find.text('Existing worker connection'));
    await tester.pumpAndSettle();
    expect(find.text('3579'), findsOneWidget);
    expect(find.text('ws://127.0.0.1:9753/ws'), findsOneWidget);
    expect(find.bySemanticsIdentifier('launcher.connect_external'), findsOne);

    await tester.enterText(
      find.byType(TextField).at(1),
      'ws://127.0.0.1:9753/auth-token/ws',
    );

    final connectButton = find.widgetWithText(
      OutlinedButton,
      'Connect to existing worker',
    );
    await tester.ensureVisible(connectButton);
    final onConnect = tester.widget<OutlinedButton>(connectButton).onPressed;
    expect(onConnect, isNotNull);
    onConnect!();
    await tester.pumpAndSettle();

    expect(fixture.services.bindPorts, [3579]);
    expect(fixture.worker.startCalls, 0);
    expect(fixture.controller.session?.external, isTrue);
    expect(fixture.controller.canStop, isFalse);
    expect(find.text('Disconnect'), findsOneWidget);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Disconnect'));
    await tester.pumpAndSettle();
    expect(fixture.worker.stopCalls, 0);
    expect(fixture.controller.state, LauncherState.idle);
  });

  testWidgets('connected HomePage keeps owned Stop above the test body', (
    tester,
  ) async {
    final fixture = _Fixture();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _selectValid(fixture.controller);
    final start = fixture.controller.start();
    await _pumpUntil(tester, () => fixture.worker.startCalls == 1);
    fixture.worker.emitReady();
    await start;
    getIt.registerSingleton<LauncherController>(fixture.controller);

    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.byType(LauncherPanel), findsNothing);
    expect(find.byType(LauncherSessionBar), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets(
    'connected header reconnects its session and keeps report loading disabled',
    (tester) async {
      final fixture = _Fixture();
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _selectValid(fixture.controller);
      final start = fixture.controller.start();
      await _pumpUntil(tester, () => fixture.worker.startCalls == 1);
      fixture.worker.emitReady();
      await start;
      final authenticatedSessionUri = fixture.controller.session!.workerUri!;
      final defaultFakeEndpointB = Uri.parse('ws://127.0.0.1:9753/ws');
      fixture.services.connectUris.clear();
      getIt.registerSingleton<LauncherController>(fixture.controller);

      await tester.pumpWidget(const MyApp());
      await tester.pump();

      expect(find.bySemanticsIdentifier('launcher.reconnect'), findsOne);
      expect(find.bySemanticsIdentifier('launcher.load_report'), findsOne);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Load Report'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.bySemanticsIdentifier('launcher.reconnect'));
      await tester.pumpAndSettle();

      expect(fixture.services.connectUris, [authenticatedSessionUri]);
      expect(
        fixture.services.connectUris,
        isNot(contains(defaultFakeEndpointB)),
      );
      expect(getIt.get<HomePageStore>().displayLoadedReportMode, isFalse);

      fixture.worker.failStop = true;
      await tester.tap(find.widgetWithText(OutlinedButton, 'Stop'));
      await tester.pumpAndSettle();

      expect(fixture.controller.canRetryCleanup, isTrue);
      expect(fixture.controller.canLoadReport, isFalse);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Load Report'))
            .onPressed,
        isNull,
      );
      expect(getIt.get<HomePageStore>().displayLoadedReportMode, isFalse);
    },
  );

  testWidgets('disconnected HomePage reconnects the current owned session', (
    tester,
  ) async {
    final fixture = _Fixture();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _selectValid(fixture.controller);
    final start = fixture.controller.start();
    await _pumpUntil(tester, () => fixture.worker.startCalls == 1);
    fixture.worker.emitReady();
    await start;
    final authenticatedSessionUri = fixture.controller.session!.workerUri!;
    fixture.services.connectUris.clear();
    getIt.registerSingleton<LauncherController>(fixture.controller);
    await appVmService.disconnect();

    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.byType(LauncherPanel), findsOneWidget);
    expect(find.bySemanticsIdentifier('launcher.reconnect'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Stop'), findsOneWidget);

    await tester.tap(find.bySemanticsIdentifier('launcher.reconnect'));
    await tester.pumpAndSettle();

    expect(fixture.services.connectUris, [authenticatedSessionUri]);
    expect(fixture.controller.session?.external, isFalse);
    expect(fixture.controller.ownsWorker, isTrue);
  });

  testWidgets(
    'disconnected HomePage reconnects an external session without Stop',
    (tester) async {
      final fixture = _Fixture();
      await tester.binding.setSurfaceSize(const Size(1600, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final authenticatedSessionUri = Uri.parse(
        'ws://127.0.0.1:9753/external-token/ws',
      );
      await fixture.controller.connectExternal(
        managerPort: 3579,
        workerUri: authenticatedSessionUri,
      );
      fixture.services.connectUris.clear();
      getIt.registerSingleton<LauncherController>(fixture.controller);
      await appVmService.disconnect();

      await tester.pumpWidget(const MyApp());
      await tester.pump();

      expect(find.byType(LauncherPanel), findsOneWidget);
      expect(find.bySemanticsIdentifier('launcher.reconnect'), findsOneWidget);
      expect(find.text('Stop'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Disconnect'), findsOneWidget);

      await tester.tap(find.bySemanticsIdentifier('launcher.reconnect'));
      await tester.pumpAndSettle();

      expect(fixture.services.connectUris, [authenticatedSessionUri]);
      expect(fixture.controller.session?.external, isTrue);
      expect(fixture.controller.ownsWorker, isFalse);
    },
  );

  testWidgets('offline report mode remains available while disconnected', (
    tester,
  ) async {
    final fixture = _Fixture();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    getIt.registerSingleton<LauncherController>(fixture.controller);
    getIt.get<HomePageStore>().displayLoadedReportMode = true;
    await appVmService.disconnect();

    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Loaded Report Displayer'), findsOneWidget);
    expect(find.byType(LauncherPanel), findsNothing);
  });

  testWidgets(
    'narrow window and large text remain scrollable without overflow',
    (tester) async {
      final fixture = _Fixture();
      await tester.binding.setSurfaceSize(const Size(340, 620));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: LauncherLocalizations.localizationsDelegates,
          supportedLocales: LauncherLocalizations.supportedLocales,
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(340, 620),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: LauncherPanel(controller: fixture.controller),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SingleChildScrollView), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('MyApp installs one asynchronous exit-request callback', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MyApp(
        onExitRequested: () async {
          calls++;
          return AppExitResponse.cancel;
        },
        builder: (_, _) => const Scaffold(),
      ),
    );

    final response = await tester.binding.handleRequestAppExit();

    expect(response, AppExitResponse.cancel);
    expect(calls, 1);
  });

  testWidgets('MyApp cancels exit when an owned worker cannot be cleaned up', (
    tester,
  ) async {
    final fixture = _Fixture();
    await tester.binding.setSurfaceSize(const Size(1600, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _selectValid(fixture.controller);
    final start = fixture.controller.start();
    await _pumpUntil(tester, () => fixture.worker.startCalls == 1);
    fixture.worker.emitReady();
    await start;
    fixture.worker.failStop = true;
    getIt.registerSingleton<LauncherController>(fixture.controller);
    addTearDown(() async {
      fixture.worker.failStop = false;
      await fixture.controller.stop();
    });

    await tester.pumpWidget(const MyApp());

    final response = await tester.binding.handleRequestAppExit();
    await tester.pumpAndSettle();

    expect(response, AppExitResponse.cancel);
    expect(fixture.controller.ownsWorker, isTrue);
    expect(find.textContaining('could not be stopped safely'), findsOneWidget);
  });
}

Future<void> _pumpLauncher(
  WidgetTester tester,
  LauncherController controller, {
  LauncherPathChooser? chooseProjectDirectory,
  LauncherPathChooser? chooseFlutterExecutable,
  LauncherPathChooser? chooseReportPath,
  LauncherReportReader? readReport,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: LauncherLocalizations.localizationsDelegates,
      supportedLocales: LauncherLocalizations.supportedLocales,
      home: Scaffold(
        body: ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Column(
            children: [
              LauncherSessionBar(controller: controller),
              Expanded(
                child: LauncherPanel(
                  controller: controller,
                  chooseProjectDirectory: chooseProjectDirectory,
                  chooseFlutterExecutable: chooseFlutterExecutable,
                  chooseReportPath: chooseReportPath,
                  readReport: readReport,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _selectValid(LauncherController controller) async {
  await controller.chooseProject('/projects/app');
  await controller.chooseEntrypoint('integration_test/example_test.dart');
  await controller.chooseDevice('macos');
}

void _expectSelectionUnchanged(
  LauncherSelectionSnapshot actual,
  LauncherSelectionSnapshot before,
) {
  expect(actual.projectDirectory, before.projectDirectory);
  expect(actual.entrypoints, before.entrypoints);
  expect(actual.entrypoint, before.entrypoint);
  expect(actual.flutterExecutable, before.flutterExecutable);
  expect(actual.devices, before.devices);
  expect(actual.deviceId, before.deviceId);
  expect(actual.dartDefines, before.dartDefines);
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var index = 0; index < 20 && !condition(); index++) {
    await tester.pump();
  }
  expect(condition(), isTrue);
}

WorkerLogEvent _logEvent() => const WorkerLogEvent(
  runId: 1,
  sessionId: 'session-1',
  source: WorkerLogSource.stdout,
  message: 'Building fixture',
  isError: false,
  malformedProtocol: false,
  truncated: false,
);

class _Fixture {
  _Fixture({_FakeDiscovery? discovery})
    : discovery = discovery ?? _FakeDiscovery(),
      preferences = _FakePreferences(),
      worker = _FakeWorkerProcess(),
      services = _FakeSessionServices() {
    controller = LauncherController(
      discovery: this.discovery,
      preferences: preferences,
      process: worker,
      sessionServices: services,
      reportRootDirectory: '/reports',
      readinessTimeout: const Duration(milliseconds: 100),
      sessionIdFactory: () => 'session-${++_sessionCounter}',
    );
  }

  static var _sessionCounter = 0;
  final _FakeDiscovery discovery;
  final _FakePreferences preferences;
  final _FakeWorkerProcess worker;
  final _FakeSessionServices services;
  late final LauncherController controller;
}

class _FakeDiscovery implements ProjectDiscovery {
  _FakeDiscovery({
    this.entrypointResults = const <String>[
      'integration_test/example_test.dart',
    ],
    this.deviceResults = const <({String id, String name})>[
      (id: 'macos', name: 'Local macOS'),
    ],
  });

  final projectRequests = <String>[];
  final List<String> entrypointResults;
  final List<({String id, String name})> deviceResults;

  @override
  Future<String> canonicalProjectDirectory(String projectDirectory) async {
    projectRequests.add(projectDirectory);
    return projectDirectory;
  }

  @override
  Future<List<({String id, String name})>> devices(
    String flutterExecutable,
  ) async => deviceResults;

  @override
  Future<List<String>> entrypoints(String projectDirectory) async =>
      entrypointResults;

  @override
  Future<String> resolveFlutterExecutable({
    required String projectDirectory,
    String? explicitFlutterExecutable,
    String? savedFlutterExecutable,
  }) async =>
      explicitFlutterExecutable ?? savedFlutterExecutable ?? '/sdk/flutter';

  @override
  Future<String> validateEntrypoint(
    String projectDirectory,
    String entrypoint,
  ) async => entrypoint;
}

class _FakePreferences implements LauncherPreferences {
  LaunchConfiguration? value;
  Completer<void>? saveGate;
  final savedConfigurations = <LaunchConfiguration>[];

  @override
  LauncherPreferencesDiagnostic? diagnostic;

  @override
  String get filePath => '/preferences.json';

  @override
  Future<LaunchConfiguration?> load() async => value;

  @override
  Future<void> save(LaunchConfiguration configuration) async {
    await saveGate?.future;
    value = configuration;
    savedConfigurations.add(configuration);
  }
}

class _FakeWorkerProcess implements LauncherWorkerProcess {
  final _events = StreamController<WorkerEvent>.broadcast(sync: true);
  @override
  final logs = <WorkerLogEvent>[];
  @override
  bool owned = false;
  bool failStop = false;
  int startCalls = 0;
  int stopCalls = 0;
  LaunchConfiguration? startedConfiguration;
  String? startedSessionId;
  int? startedManagerPort;
  int _runId = 0;
  String? _sessionId;

  @override
  Stream<WorkerEvent> get events => _events.stream;

  @override
  int? get currentRunId => _runId == 0 ? null : _runId;

  @override
  int? get ownedPid => owned ? 12345 : null;

  @override
  Future<void> start(
    LaunchConfiguration configuration, {
    required String sessionId,
    required int managerPort,
  }) async {
    startCalls++;
    startedConfiguration = configuration;
    startedSessionId = sessionId;
    startedManagerPort = managerPort;
    _runId++;
    _sessionId = sessionId;
    owned = true;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    if (failStop) throw StateError('cleanup blocked');
    owned = false;
  }

  @override
  Future<void> dispose() async {
    owned = false;
    await _events.close();
  }

  void emitReady() {
    _events
      ..add(
        WorkerAppStartedEvent(
          runId: _runId,
          sessionId: _sessionId!,
          appId: 'app-$_runId',
        ),
      )
      ..add(
        WorkerDebugPortEvent(
          runId: _runId,
          sessionId: _sessionId!,
          appId: 'app-$_runId',
          vmServiceUri: Uri.parse('ws://127.0.0.1:48000/token/ws'),
          baseUri: null,
          port: 48000,
        ),
      );
  }
}

class _FakeSessionServices implements LauncherSessionServices {
  final bindPorts = <int>[];
  final connectUris = <Uri>[];
  int _generation = 0;

  @override
  int? boundPort;

  @override
  bool connected = false;

  @override
  Future<int> bind({required int port}) async {
    bindPorts.add(port);
    boundPort = port == 0 ? 46000 : port;
    return boundPort!;
  }

  @override
  Future<int> prepareSession({required String reportPath}) async =>
      ++_generation;

  @override
  Future<void> connect({required Uri uri}) async {
    connectUris.add(uri);
    connected = true;
  }

  @override
  Future<void> waitUntilReady({
    required int generation,
    required Duration timeout,
  }) async {}

  @override
  Future<void> disconnect() async {
    connected = false;
  }

  @override
  Future<void> shutdownListener() async {
    boundPort = null;
  }

  @override
  Future<void> restoreGlobalConfiguration() async {}
}
