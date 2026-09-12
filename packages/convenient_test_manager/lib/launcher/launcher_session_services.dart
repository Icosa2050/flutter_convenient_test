import 'dart:async';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager/stores/home_page_store.dart';
import 'package:convenient_test_manager_dart/services/convenient_test_manager_service.dart';
import 'package:convenient_test_manager_dart/services/misc_dart_service.dart';
import 'package:convenient_test_manager_dart/services/report_saver_service.dart';
import 'package:convenient_test_manager_dart/services/vm_service_wrapper_service.dart';
import 'package:convenient_test_manager_dart/stores/global_config_store.dart';
import 'package:convenient_test_manager_dart/stores/suite_info_store.dart';
import 'package:convenient_test_manager_dart/stores/worker_super_run_store.dart';
import 'package:get_it/get_it.dart';

/// Runtime operations needed by [LauncherController] without exposing GetIt.
///
/// A session generation is returned by [prepareSession]. Callers must pass that
/// generation to [waitUntilReady], so a wait from an older reset cannot observe
/// the next session's suite.
abstract interface class LauncherSessionServices {
  int? get boundPort;
  bool get connected;

  Future<int> bind({required int port});
  Future<int> prepareSession({required String reportPath});
  Future<void> connect({required Uri uri});
  Future<void> waitUntilReady({
    required int generation,
    required Duration timeout,
  });
  Future<void> disconnect();
  Future<void> shutdownListener();
  Future<void> restoreGlobalConfiguration();
}

final class LauncherSessionInvalidatedException implements Exception {
  const LauncherSessionInvalidatedException();
}

/// Production adapter for the already-registered manager runtime services.
///
/// Construction and [boundPort] are side-effect free. A listener is opened only
/// by [bind], which keeps widget tests socket-free when launcher initialization
/// is disabled.
final class GetItLauncherSessionServices implements LauncherSessionServices {
  GetItLauncherSessionServices({
    ConvenientTestManagerService? manager,
    VmServiceWrapperService? vmService,
    MiscDartService? miscService,
    ManagerReportSaverService? reportSaver,
    SuiteInfoStore? suiteInfoStore,
    WorkerSuperRunStore? workerSuperRunStore,
    HomePageStore? homePageStore,
    this.readinessPollInterval = const Duration(milliseconds: 25),
  }) : _manager = manager ?? GetIt.I.get<ConvenientTestManagerService>(),
       _vmService = vmService ?? GetIt.I.get<VmServiceWrapperService>(),
       _miscService = miscService ?? GetIt.I.get<MiscDartService>(),
       _reportSaver = reportSaver ?? GetIt.I.get<ManagerReportSaverService>(),
       _suiteInfoStore = suiteInfoStore ?? GetIt.I.get<SuiteInfoStore>(),
       _workerSuperRunStore =
           workerSuperRunStore ?? GetIt.I.get<WorkerSuperRunStore>(),
       _homePageStore = homePageStore ?? GetIt.I.get<HomePageStore>() {
    if (readinessPollInterval <= Duration.zero) {
      throw ArgumentError.value(
        readinessPollInterval,
        'readinessPollInterval',
        'must be positive',
      );
    }
  }

  final ConvenientTestManagerService _manager;
  final VmServiceWrapperService _vmService;
  final MiscDartService _miscService;
  final ManagerReportSaverService _reportSaver;
  final SuiteInfoStore _suiteInfoStore;
  final WorkerSuperRunStore _workerSuperRunStore;
  final HomePageStore _homePageStore;
  final Duration readinessPollInterval;

  var _generation = 0;
  bool? _savedReportSaverEnabled;
  String? _savedReportPath;
  var _hasSavedGlobalConfiguration = false;

  @override
  int? get boundPort => _manager.boundPort;

  @override
  bool get connected => _vmService.connected;

  @override
  Future<int> bind({required int port}) =>
      _manager.serve(port: port, address: '127.0.0.1');

  @override
  Future<int> prepareSession({required String reportPath}) async {
    final generation = ++_generation;
    if (!_hasSavedGlobalConfiguration) {
      _savedReportSaverEnabled = GlobalConfigStore.config.enableReportSaver;
      _savedReportPath = GlobalConfigStore.config.reportSavePath;
      _hasSavedGlobalConfiguration = true;
    }

    GlobalConfigStore.config
      ..enableReportSaver = true
      ..reportSavePath = reportPath;

    _homePageStore.displayLoadedReportMode = false;
    _miscService.clearAll();
    _workerSuperRunStore.setControllerIntegrationTest(
      filterNameRegex: RegexUtils.kMatchNothing,
    );
    await _reportSaver.clear();
    return generation;
  }

  @override
  Future<void> connect({required Uri uri}) => _vmService.connect(uri: uri);

  @override
  Future<void> waitUntilReady({
    required int generation,
    required Duration timeout,
  }) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    final stopwatch = Stopwatch()..start();
    while (true) {
      if (generation != _generation) {
        throw const LauncherSessionInvalidatedException();
      }
      if (_vmService.connected && _suiteInfoStore.suiteInfo != null) {
        return;
      }
      if (stopwatch.elapsed >= timeout) {
        throw TimeoutException(
          'launcher session did not become ready',
          timeout,
        );
      }
      await Future<void>.delayed(readinessPollInterval);
    }
  }

  @override
  Future<void> disconnect() async {
    _generation++;
    await _vmService.disconnect();
  }

  @override
  Future<void> shutdownListener() => _manager.shutdown();

  @override
  Future<void> restoreGlobalConfiguration() async {
    if (!_hasSavedGlobalConfiguration) return;
    GlobalConfigStore.config
      ..enableReportSaver = _savedReportSaverEnabled!
      ..reportSavePath = _savedReportPath;
    _savedReportSaverEnabled = null;
    _savedReportPath = null;
    _hasSavedGlobalConfiguration = false;
  }
}
