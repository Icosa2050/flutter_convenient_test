import 'package:convenient_test_dev/convenient_test_dev.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:launcher_fixture/main.dart' as app;
import 'package:launcher_fixture/main.dart';

void main() {
  convenientTestMain(NativeLauncherFixtureSlot(), () {
    tTestWidgets('launcher native smoke', (t) async {
      await find
          .bySemanticsIdentifier('launcher.fixture.ready')
          .should(findsOneWidget);
    });
  });
}

class NativeLauncherFixtureSlot extends ConvenientTestSlot {
  @override
  Future<void> appMain(AppMainExecuteMode mode) async => app.main();

  @override
  BuildContext? getNavContext(ConvenientTest t) =>
      LauncherFixtureApp.navigatorKey.currentContext;
}
