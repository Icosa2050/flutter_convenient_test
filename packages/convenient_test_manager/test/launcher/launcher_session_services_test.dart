import 'dart:async';
import 'dart:io';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager/launcher/launcher_session_services.dart';
import 'package:convenient_test_manager/misc/setup.dart';
import 'package:convenient_test_manager/stores/home_page_store.dart';
import 'package:convenient_test_manager_dart/services/convenient_test_manager_service.dart';
import 'package:convenient_test_manager_dart/services/vm_service_wrapper_service.dart';
import 'package:convenient_test_manager_dart/stores/global_config_store.dart';
import 'package:convenient_test_manager_dart/stores/log_store.dart';
import 'package:convenient_test_manager_dart/stores/suite_info_store.dart';
import 'package:convenient_test_manager_dart/stores/worker_super_run_store.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobx/mobx.dart';

import '../fake_vm_service_wrapper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeVmServiceWrapper vm;
  late Directory temporaryDirectory;

  setUpAll(() async {
    await setup(
      registerVmServiceWrapper: false,
      startManagerServer: false,
      autoConnectVm: false,
      initializeLauncher: false,
      initVLC: false,
      parseConfigFile: false,
    );
    vm = FakeVmServiceWrapper();
    getIt.registerSingleton<VmServiceWrapperService>(vm);
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'launcher-session-services-',
    );
  });

  tearDownAll(() async {
    await getIt.get<ConvenientTestManagerService>().shutdown();
    await vm.disconnect();
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('LogStore.clear removes every forward and reverse lookup', () {
    final store = LogStore();
    store.logEntryInTest.addRelation(1, 2);
    store.testIdOfLogEntry[2] = 1;
    store.logSubEntryInEntry.addRelation(2, 3);
    store.logEntryIdOfLogSubEntry[3] = 2;
    store.logSubEntryMap[3] = LogSubEntry(id: Int64(3), time: Int64(4));
    store.logSubEntryIdOfTime[4] = 3;
    store.snapshotInLog[2] = ObservableMap();

    store.clear();

    expect(store.logEntryInTest, isEmpty);
    expect(store.testIdOfLogEntry, isEmpty);
    expect(store.logSubEntryInEntry, isEmpty);
    expect(store.logEntryIdOfLogSubEntry, isEmpty);
    expect(store.logSubEntryMap, isEmpty);
    expect(store.logSubEntryIdOfTime, isEmpty);
    expect(store.snapshotInLog, isEmpty);
  });

  test(
    'reset creates a fresh run and old suite data cannot satisfy Ready',
    () async {
      final suiteStore = getIt.get<SuiteInfoStore>();
      final runStore = getIt.get<WorkerSuperRunStore>();
      final homePageStore = getIt.get<HomePageStore>();
      final services = GetItLauncherSessionServices(
        readinessPollInterval: const Duration(milliseconds: 1),
      );
      final oldController = runStore.currSuperRunController;
      final oldSuite = SuiteInfo.fromProto(SuiteInfoProto());
      suiteStore.suiteInfo = oldSuite;
      homePageStore.displayLoadedReportMode = true;
      GlobalConfigStore.config
        ..enableReportSaver = false
        ..reportSavePath = '/original/report/path';
      await vm.disconnect();
      final reportPath = '${temporaryDirectory.path}/session-a';

      final generation = await services.prepareSession(reportPath: reportPath);

      expect(suiteStore.suiteInfo, isNull);
      expect(homePageStore.displayLoadedReportMode, isFalse);
      expect(runStore.currSuperRunController, isNot(same(oldController)));
      expect(GlobalConfigStore.config.enableReportSaver, isTrue);
      expect(GlobalConfigStore.config.reportSavePath, reportPath);

      await vm.connect(uri: Uri.parse('ws://127.0.0.1:1/auth/ws'));
      await expectLater(
        services.waitUntilReady(
          generation: generation,
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(isA<TimeoutException>()),
      );

      suiteStore.suiteInfo = SuiteInfo.fromProto(SuiteInfoProto());
      await services.waitUntilReady(
        generation: generation,
        timeout: const Duration(milliseconds: 50),
      );
      await services.restoreGlobalConfiguration();
      expect(GlobalConfigStore.config.enableReportSaver, isFalse);
      expect(GlobalConfigStore.config.reportSavePath, '/original/report/path');
    },
  );

  test(
    'simulated CLI and GUI listeners stop independently in both orders',
    () async {
      final cliManager = ConvenientTestManagerService();
      final guiManager = ConvenientTestManagerService();
      final cliPort = await cliManager.serve(port: 0, address: '127.0.0.1');
      final guiPort = await guiManager.serve(port: 0, address: '127.0.0.1');
      expect(guiPort, isNot(cliPort));

      await guiManager.shutdown();
      await _expectListening(cliPort);

      final restartedGuiPort = await guiManager.serve(
        port: 0,
        address: '127.0.0.1',
      );
      await cliManager.shutdown();
      await _expectListening(restartedGuiPort);

      await guiManager.shutdown();
    },
  );
}

Future<void> _expectListening(int port) async {
  final socket = await Socket.connect(
    InternetAddress.loopbackIPv4,
    port,
    timeout: const Duration(seconds: 1),
  );
  await socket.close();
}
