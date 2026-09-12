import 'package:convenient_test_common_dart/convenient_test_common_dart.dart';
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
}
