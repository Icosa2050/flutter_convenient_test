import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
import 'package:convenient_test_manager_dart/services/headless_exit_code_service.dart';
import 'package:convenient_test_manager_dart/services/headless_startup_service.dart';
import 'package:test/test.dart';

void main() {
  group('performHeadlessStartup', () {
    test('waits for suite info before scheduling the real test run', () async {
      final steps = <String>[];
      String? receivedFilter;

      await performHeadlessStartup(
        startMonitoringWorkerAvailability: () {
          steps.add('startMonitoringWorkerAvailability');
        },
        waitBeforeFirstTestRun: () async {
          steps.add('waitBeforeFirstTestRun');
        },
        awaitSuiteInfoNonEmpty: () async {
          steps.add('awaitSuiteInfoNonEmpty');
        },
        hotRestartAndRunTests: ({required filterNameRegex}) {
          steps.add('hotRestartAndRunTests');
          receivedFilter = filterNameRegex;
        },
        runOnly: null,
      );

      expect(steps, [
        'startMonitoringWorkerAvailability',
        'waitBeforeFirstTestRun',
        'awaitSuiteInfoNonEmpty',
        'hotRestartAndRunTests',
      ]);
      expect(receivedFilter, RegexUtils.kMatchEverything);
    });

    test('uses a runOnly prefix regex for the real test run', () async {
      String? receivedFilter;

      await performHeadlessStartup(
        startMonitoringWorkerAvailability: () {},
        waitBeforeFirstTestRun: () async {},
        awaitSuiteInfoNonEmpty: () async {},
        hotRestartAndRunTests: ({required filterNameRegex}) {
          receivedFilter = filterNameRegex;
        },
        runOnly: 'hello_convenient_test',
      );

      expect(receivedFilter, RegexUtils.matchPrefix('hello_convenient_test'));
    });
  });

  group('calculateHeadlessExitCode', () {
    int calculate({
      int pending = 0,
      int running = 0,
      int success = 0,
      int flaky = 0,
      int skipped = 0,
      int failure = 0,
      String? runOnly,
    }) => calculateHeadlessExitCode(
      pendingCount: pending,
      runningCount: running,
      successCount: success,
      flakyCount: flaky,
      skippedCount: skipped,
      failureCount: failure,
      runOnly: runOnly,
    );

    test('accepts unselected pending tests after a run-only success', () {
      expect(
        calculate(
          pending: 6,
          success: 1,
          runOnly: 'selected test',
        ),
        0,
      );
    });

    test('reports a selected run-only failure', () {
      expect(
        calculate(
          pending: 6,
          failure: 1,
          runOnly: 'selected test',
        ),
        kExitCodeFinishExecutionButHasFailure,
      );
    });

    test('rejects pending tests for an unfiltered run', () {
      expect(
        () => calculate(pending: 1, success: 1),
        throwsStateError,
      );
    });

    test('rejects a run-only filter that completed no test', () {
      expect(
        () => calculate(pending: 7, runOnly: 'does not match'),
        throwsStateError,
      );
    });
  });
}
