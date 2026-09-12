import 'dart:ui' show AppExitResponse;

import 'package:convenient_test_manager/build/generated/launcher_l10n/launcher_localizations.dart';
import 'package:convenient_test_manager/launcher/launcher_controller.dart';
import 'package:convenient_test_manager/misc/setup.dart';
import 'package:convenient_test_manager/pages/golden_diff_page.dart';
import 'package:convenient_test_manager/pages/home_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_portal/flutter_portal.dart';

Future<void> main() async {
  await setup();
  runApp(const MyApp());
}

typedef AppExitRequestHandler = Future<AppExitResponse> Function();

class MyApp extends StatefulWidget {
  final ThemeMode themeMode;
  final Widget Function(BuildContext context, Widget? child)? builder;
  final AppExitRequestHandler? onExitRequested;

  const MyApp({
    super.key,
    this.themeMode = ThemeMode.system,
    this.builder,
    this.onExitRequested,
  });

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _navigatorKey = GlobalKey<NavigatorState>();
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  late final AppLifecycleListener _lifecycleListener;

  @override
  void initState() {
    super.initState();
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: widget.onExitRequested ?? _handleExitRequested,
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    super.dispose();
  }

  ThemeData _getTheme({required Brightness brightness}) => ThemeData(
    brightness: brightness,
    colorSchemeSeed: Colors.blue,
    useMaterial3: false,
  );

  @override
  Widget build(BuildContext context) {
    return Portal(
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        scaffoldMessengerKey: _scaffoldMessengerKey,
        title: 'ConvenientTestManager',
        localizationsDelegates: LauncherLocalizations.localizationsDelegates,
        supportedLocales: LauncherLocalizations.supportedLocales,
        themeMode: widget.themeMode,
        theme: _getTheme(brightness: Brightness.light),
        darkTheme: _getTheme(brightness: Brightness.dark),
        // to allow test overriding of routes for getting all the benefits
        // of a MaterialApp (correct theme, Direction, etc).
        initialRoute: widget.builder == null ? HomePage.kRouteName : null,
        builder: widget.builder,
        routes: {
          HomePage.kRouteName: (_) => const HomePage(),
          GoldenDiffPage.kRouteName: (_) => const GoldenDiffPage(),
        },
      ),
    );
  }

  Future<AppExitResponse> _handleExitRequested() async {
    if (!getIt.isRegistered<LauncherController>()) {
      return AppExitResponse.exit;
    }
    final controller = getIt.get<LauncherController>();
    try {
      await controller.shutdown();
      if (!controller.ownsWorker && controller.session == null) {
        return AppExitResponse.exit;
      }
      _showCleanupError(controller.error?.arguments.values.join(', '));
    } on Object catch (error) {
      _showCleanupError(error);
    }
    return AppExitResponse.cancel;
  }

  void _showCleanupError(Object? details) {
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    final localizations = LauncherLocalizations.of(context);
    _scaffoldMessengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(
          localizations.launcherCleanupFailure(
            details?.toString() ?? localizations.launcherStopping,
          ),
        ),
      ),
    );
  }
}
