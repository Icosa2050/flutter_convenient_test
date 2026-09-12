import 'package:convenient_test/convenient_test.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const LauncherFixtureApp());
}

class LauncherFixtureApp extends StatelessWidget {
  const LauncherFixtureApp({super.key});

  static final navigatorKey = GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return ConvenientTestWrapperWidget(
      child: MaterialApp(
        navigatorKey: navigatorKey,
        home: const _ReadyScreen(),
      ),
    );
  }
}

class _ReadyScreen extends StatelessWidget {
  const _ReadyScreen();

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    return Scaffold(
      body: Center(
        child: Semantics(
          identifier: 'launcher.fixture.ready',
          label: localizations.okButtonLabel,
          child: ExcludeSemantics(child: Text(localizations.okButtonLabel)),
        ),
      ),
    );
  }
}
