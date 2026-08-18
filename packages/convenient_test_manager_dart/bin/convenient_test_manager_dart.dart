import 'dart:async';
import 'dart:io';

import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager_dart/misc/setup.dart';
import 'package:convenient_test_manager_dart/services/headless_exit_code_service.dart';
import 'package:convenient_test_manager_dart/services/headless_startup_service.dart';
import 'package:convenient_test_manager_dart/services/misc_dart_service.dart';
import 'package:convenient_test_manager_dart/services/status_periodic_logger.dart';
import 'package:convenient_test_manager_dart/services/vm_service_wrapper_service.dart';
import 'package:convenient_test_manager_dart/stores/global_config_store.dart';
import 'package:convenient_test_manager_dart/stores/suite_info_store.dart';
import 'package:convenient_test_manager_dart/stores/worker_super_run_store.dart';
import 'package:get_it/get_it.dart';
import 'package:mobx/mobx.dart';

const _kTag = 'main';

const kExitCodeWorkerDisappeared = 2;

Future<void> main(List<String> args) async {
  Log.i(_kTag, 'main start');

  await setup(headlessMode: true, args: args);

  Log.i(_kTag, 'step awaitWorkerAvailable');
  await _awaitWorkerAvailable();

  await performHeadlessStartup(
    startMonitoringWorkerAvailability: () =>
        unawaited(_monitorWorkerAvailable()),
    waitBeforeFirstTestRun: () =>
        Future<void>.delayed(const Duration(seconds: 6)),
    awaitSuiteInfoNonEmpty: _awaitSuiteInfoNonEmpty,
    hotRestartAndRunTests: GetIt.I.get<MiscDartService>().hotRestartAndRunTests,
    runOnly: GlobalConfigStore.config.runOnly,
  );

  StatusPeriodicLogger.run();

  Log.i(_kTag, 'step awaitSuperRunStatusTestAllDone');
  await _awaitSuperRunStatusTestAllDone();

  Log.i(_kTag, 'step exit');
  exit(_calcExitCode());
}

Future<void> _awaitWorkerAvailable() async {
  final vmServiceWrapperService = GetIt.I.get<VmServiceWrapperService>();

  Log.i(_kTag, 'waitWorkerAvailable start');

  while (true) {
    Log.i(_kTag, 'waitWorkerAvailable check');
    if (vmServiceWrapperService.hotRestartAvailable) {
      return;
    }

    // for example, manager has started + worker has not started. Then the initial `connect` will immediately fail.
    // without this re-connect, it will forever non-connected
    if (!vmServiceWrapperService.connected) {
      await vmServiceWrapperService.connect();
    }

    await Future<void>.delayed(const Duration(seconds: 3));
  }
}

Future<void> _monitorWorkerAvailable() async {
  final vmServiceWrapperService = GetIt.I.get<VmServiceWrapperService>();

  while (true) {
    Log.i(_kTag, 'monitorWorkerAvailable check');
    if (!vmServiceWrapperService.hotRestartAvailable) {
      Log.e(
        _kTag,
        'monitorWorkerAvailable see hot restart not available, thus exit with code=$kExitCodeWorkerDisappeared '
        '(vmServiceWrapperService.hotRestartAvailable=${vmServiceWrapperService.hotRestartAvailable}, '
        'vmServiceWrapperService.connected=${vmServiceWrapperService.connected})',
      );
      exit(kExitCodeWorkerDisappeared);
    }

    await Future<void>.delayed(const Duration(seconds: 5));
  }
}

Future<void> _awaitSuiteInfoNonEmpty() async {
  final suiteInfoStore = GetIt.I.get<SuiteInfoStore>();

  while (true) {
    final suiteInfo = suiteInfoStore.suiteInfo;
    final numGroupEntries = suiteInfo?.entryMap.length ?? 0;
    Log.i(
      _kTag,
      'awaitSuiteInfoNonEmpty check numGroupEntries=$numGroupEntries',
    );

    if (numGroupEntries > 0) return;

    await Future<void>.delayed(const Duration(seconds: 3));
  }
}

Future<void> _awaitSuperRunStatusTestAllDone() async {
  final workerSuperRunStore = GetIt.I.get<WorkerSuperRunStore>();

  if (workerSuperRunStore.currSuperRunController.superRunStatus ==
      WorkerSuperRunStatus.testAllDone) {
    throw AssertionError;
  }

  await asyncWhen(
    (_) =>
        workerSuperRunStore.currSuperRunController.superRunStatus ==
        WorkerSuperRunStatus.testAllDone,
  );
}

int _calcExitCode() {
  final suiteInfoStore = GetIt.I.get<SuiteInfoStore>();

  final stateCountMap = suiteInfoStore.calcStateCountMap(
    suiteInfoStore.suiteInfo!.rootGroup,
  );

  if (stateCountMap[SimplifiedStateEnum.completeSuccessButFlaky] > 0) {
    Log.w(_kTag, 'See flaky tests.');
  }

  final hasFailure =
      stateCountMap[SimplifiedStateEnum.completeFailureOrError] > 0;
  if (hasFailure) {
    Log.w(_kTag, 'See failed tests.');
  }

  final ans = calculateHeadlessExitCode(
    pendingCount: stateCountMap[SimplifiedStateEnum.pending],
    runningCount: stateCountMap[SimplifiedStateEnum.running],
    successCount: stateCountMap[SimplifiedStateEnum.completeSuccess],
    flakyCount: stateCountMap[SimplifiedStateEnum.completeSuccessButFlaky],
    skippedCount: stateCountMap[SimplifiedStateEnum.completeSkipped],
    failureCount:
        stateCountMap[SimplifiedStateEnum.completeFailureOrError],
    runOnly: GlobalConfigStore.config.runOnly,
  );
  Log.d(_kTag, 'calcExitCode=$ans');
  return ans;
}
