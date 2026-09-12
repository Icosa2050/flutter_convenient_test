import 'package:convenient_test_dev/convenient_test_dev.dart';

import '../../integration_test/launcher_convenient_test.dart' as launcher_test;

Future<void> main() => launcher_test.runLauncherConvenientTest(
  executionEnv: ExecutionEnv.widgetTest,
);
