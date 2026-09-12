const kExitCodeFinishExecutionButHasFailure = 1;

int calculateHeadlessExitCode({
  required int pendingCount,
  required int runningCount,
  required int successCount,
  required int flakyCount,
  required int skippedCount,
  required int failureCount,
  required String? runOnly,
}) {
  final completed = successCount + flakyCount + skippedCount + failureCount;

  if (runningCount > 0) {
    throw StateError('Cannot calculate an exit code while tests are running.');
  }
  if (pendingCount > 0 && runOnly == null) {
    throw StateError('Unfiltered test runs cannot finish with pending tests.');
  }
  if (runOnly != null && completed == 0) {
    throw StateError('The run-only filter did not complete any test.');
  }

  return failureCount > 0 ? kExitCodeFinishExecutionButHasFailure : 0;
}
