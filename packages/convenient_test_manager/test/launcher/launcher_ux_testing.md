# Launcher UX automation

The launcher has two complementary automated UX layers.

## Fast host regressions

Run from `packages/convenient_test_manager`:

```zsh
flutter test \
  test/launcher/launcher_panel_test.dart \
  test/launcher/project_discovery_test.dart
```

`launcher_panel_test.dart` renders the real `LauncherPanel` with the real
`LauncherController`. It drives project, entrypoint, and device controls through
their semantics identifiers, verifies the selected nested test and iOS simulator
reach the managed-launch boundary, observes the running session, and stops it.

`project_discovery_test.dart` runs the real host-side discovery code. Its machine
output fixture contains macOS, iOS simulator, physical iOS, Android, web,
unsupported, unknown, and incomplete targets. Only macOS and iOS simulators may
reach the launcher, with a stable name-then-ID order.

## Convenient Test harness

`integration_test/launcher_convenient_test.dart` is a runnable
`convenient_test` entrypoint. The app under test is the real launcher panel and
controller. Its path picker, discovery result, worker process, persistence, and
session services are deterministic test boundaries. In particular, the inner
launcher binds no socket and starts no native process.

For the reproducible host run, create a fresh report root and run the widget-mode
entrypoint from `packages/convenient_test_manager`:

```zsh
report_root="$(mktemp -d /tmp/convenient-launcher-host.XXXXXX)"
flutter test \
  --dart-define="CONVENIENT_TEST_WIDGET_TEST_REPORT_SAVER_DIRECTORY=$report_root" \
  test/launcher/launcher_convenient_host_test.dart
find "$report_root/ConvenientTestWidgetTest" -type f -name 'WIDGET-TEST-*.bin' -print
```

`launcher_convenient_host_test.dart` selects the supported
`ExecutionEnv.widgetTest` path but delegates to the same Convenient Test body as
the device entrypoint. This produces the Convenient Test action screenshots and
binary report without launching a native runner. The device entrypoint retains
`ExecutionEnv.deviceTest` as its default.

The device-mode commands below are optional; the launcher UX journey was
verified in host mode. Native worker support is verified by the disposable
runner in the next section.

Use an outer headless manager on ports that are not used by another manager or
worker. For example, from `packages/convenient_test_manager_dart`:

```zsh
dart \
  --define=CONVENIENT_TEST_MANAGER_PORT=3581 \
  --define=CONVENIENT_TEST_WORKER_PORT=9763 \
  run bin/convenient_test_manager_dart.dart \
  --report-save-path /tmp/convenient-launcher-ux-report
```

Then, from `packages/convenient_test_manager`, run either macOS:

```zsh
flutter run -d macos integration_test/launcher_convenient_test.dart \
  --host-vmservice-port 9763 \
  --disable-service-auth-codes \
  --dart-define CONVENIENT_TEST_MANAGER_PORT=3581 \
  --dart-define "CONVENIENT_TEST_APP_CODE_DIR=$PWD"
```

or an already-booted iOS simulator:

```zsh
flutter run -d <simulator-id> \
  integration_test/launcher_convenient_test.dart \
  --host-vmservice-port 9763 \
  --disable-service-auth-codes \
  --dart-define CONVENIENT_TEST_MANAGER_PORT=3581 \
  --dart-define "CONVENIENT_TEST_APP_CODE_DIR=$PWD"
```

The headless manager's `calcExitCode=0`, report, and action history are the
manager-level proof that the convenient test completed. Use a different manager
port, worker VM-service port, and report directory for every concurrent run.

## Real macOS and iOS simulator workers

From the repository root:

```zsh
./tool/test_macos_launcher.zsh --macos-only
xcrun simctl list devices available
./tool/test_macos_launcher.zsh --ios-udid 'YOUR_SIMULATOR_UDID'
```

The last command runs both macOS and the selected simulator. Add `--ios-only`
to run only the simulator. Set `FLUTTER_EXECUTABLE` if Flutter is not on PATH.
An iOS simulator ID is required explicitly, or through `IOS_SIMULATOR_UDID`.

The runner generates a disposable app from `tool/launcher_fixture`, uses the
production launcher controller and authenticated dynamic loopback ports, runs
the real convenient-test smoke, and asserts successful suite state, saved
reports, and worker/listener cleanup. It prints the retained evidence location.
It removes the disposable build root and its own simulator app, and shuts down
the simulator only when it booted it. `--keep-work-root` retains the build root
for diagnosis. This command requires a local Flutter SDK and Xcode simulator
runtime. It does not change macOS privacy permissions or test Finder startup.

## Mutation coverage

The assertions are intended to catch these regressions:

- the project picker no longer updates the visible selected project;
- the test dropdown forwards the wrong nested entrypoint;
- the device dropdown forwards a display name or the wrong device ID;
- Start skips dynamic listener allocation or passes a different port/session to
  the worker boundary;
- readiness events fail to produce a running owned session and an enabled Stop;
- Stop leaves the controller running or retains the session;
- discovery admits physical iOS, Android, web, unsupported, unknown, or malformed
  targets;
- equal-name simulator ordering stops using the stable device-ID tie-break.

This harness does **not** prove `flutter run`, process-group ownership, native
termination, VM-service authentication, or a real macOS/iOS worker connection.
Those require the separate native worker acceptance harness.
