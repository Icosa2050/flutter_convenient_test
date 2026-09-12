import 'package:convenient_test_dev/convenient_test_dev.dart';
import 'package:convenient_test_example/main.dart' as app;
import 'package:convenient_test_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A deterministic entrypoint without the full sample suite's deliberate failures.
void main() {
  convenientTestMain(LauncherSmokeSlot(), () {
    tTestWidgets('launcher smoke', (t) async {
      await find.text('HomePage').should(findsOneWidget);
    });
  });
}

class LauncherSmokeSlot extends ConvenientTestSlot {
  @override
  Future<void> appMain(AppMainExecuteMode mode) async => app.main();

  @override
  BuildContext? getNavContext(ConvenientTest t) =>
      MyApp.navigatorKey.currentContext;
}
