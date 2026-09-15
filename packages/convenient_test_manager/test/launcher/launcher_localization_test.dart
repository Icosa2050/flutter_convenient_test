import 'package:convenient_test_manager/build/generated/launcher_l10n/launcher_localizations.dart';
import 'package:convenient_test_manager/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('MyApp resolves launcher controls and parameterized errors', (
    tester,
  ) async {
    late LauncherLocalizations localizations;

    await tester.pumpWidget(
      MyApp(
        builder: (context, _) {
          localizations = LauncherLocalizations.of(context);
          return Scaffold(
            body: Column(
              children: [
                Text(localizations.launcherProjectChoose),
                Text(localizations.launcherEntrypointSelect),
                Text(localizations.launcherDeviceSelect),
                Text(localizations.launcherRefreshDevices),
                Text(localizations.launcherSdkChoose),
                Text(localizations.launcherPickerFailure),
                Text(localizations.launcherStart),
                Text(localizations.launcherReconnect),
                Text(localizations.launcherLoadReport),
                Text(localizations.launcherLoadingReport),
                Text(localizations.launcherStop),
                Text(localizations.launcherDisconnect),
                Text(localizations.launcherConnectExisting),
                Text(localizations.launcherNoTestsFound('/tmp/sample app')),
                Text(
                  localizations.launcherEntrypointUnavailable(
                    'smoke_test.dart',
                  ),
                ),
                Text(localizations.launcherPortConflict(3579)),
                Text(localizations.launcherProcessFailure('spawn denied')),
                Text(localizations.launcherProcessExited(65)),
                Text(localizations.launcherReportLoadFailure('invalid data')),
              ],
            ),
          );
        },
      ),
    );

    expect(
      Localizations.localeOf(tester.element(find.byType(Scaffold))),
      const Locale('en'),
    );
    expect(LauncherLocalizations.supportedLocales, const [Locale('en')]);
    expect(find.text('Choose project'), findsOneWidget);
    expect(find.text('Select test'), findsOneWidget);
    expect(find.text('Select device'), findsOneWidget);
    expect(find.text('Refresh devices'), findsOneWidget);
    expect(find.text('Choose Flutter SDK'), findsOneWidget);
    expect(
      find.text(
        'Could not open the file picker. '
        'Check macOS file access permissions and try again.',
      ),
      findsOneWidget,
    );
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Reconnect VM'), findsOneWidget);
    expect(find.text('Load Report'), findsOneWidget);
    expect(find.text('Loading report…'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
    expect(find.text('Connect to existing worker'), findsOneWidget);
    expect(
      find.text('No integration tests were found in /tmp/sample app.'),
      findsOneWidget,
    );
    expect(
      find.text('Test entrypoint smoke_test.dart is no longer available.'),
      findsOneWidget,
    );
    expect(find.text('Port 3579 is already in use.'), findsOneWidget);
    expect(find.text('The worker failed: spawn denied'), findsOneWidget);
    expect(find.text('The worker exited with code 65.'), findsOneWidget);
    expect(
      find.text('The selected report could not be loaded: invalid data'),
      findsOneWidget,
    );
  });
}
