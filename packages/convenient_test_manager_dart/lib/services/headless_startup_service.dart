import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';

const _kTag = 'HeadlessStartupService';

typedef RunHeadlessTestFn = void Function({required String filterNameRegex});

Future<void> performHeadlessStartup({
  required void Function() startMonitoringWorkerAvailability,
  required Future<void> Function() waitBeforeFirstTestRun,
  required Future<void> Function() awaitSuiteInfoNonEmpty,
  required RunHeadlessTestFn hotRestartAndRunTests,
  required String? runOnly,
}) async {
  startMonitoringWorkerAvailability();

  // The default controller already drives an initial suite-info-only
  // match-nothing pass, so reloading here only queues an extra restart.
  Log.i(_kTag, 'step extra sleep to avoid too quickly hot-restart worker');
  await waitBeforeFirstTestRun();

  Log.i(_kTag, 'step awaitSuiteInfoNonEmpty');
  await awaitSuiteInfoNonEmpty();

  Log.i(_kTag, 'step hotRestartAndRunTests');
  hotRestartAndRunTests(
    filterNameRegex: runOnly != null
        ? RegexUtils.matchPrefix(runOnly)
        : RegexUtils.kMatchEverything,
  );
}
