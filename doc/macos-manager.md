# Apple Silicon GUI manager

## Build and install locally

From this repository:

```zsh
./tool/macos_manager.zsh build
# Quit the installed GUI before replacing it:
./tool/macos_manager.zsh install
./tool/macos_manager.zsh verify
```

The script also works when invoked by absolute path from another directory.
It uses Flutter on PATH and the current checkout, including uncommitted edits.
It never commits or pushes. Keep fork-only changes in your own fork.

The build command creates
`packages/convenient_test_manager/build/apple-silicon/Convenient Test Manager.app`.
It copies the release build, removes Intel slices from every universal Mach-O
binary, applies a local ad-hoc signature preserving entitlements, and checks
every binary and the complete signature. The original Flutter build is retained.
This is a local installation, not a notarized distribution package.

The install command defaults to `/Applications/Convenient Test Manager.app`.
An optional second argument specifies another absolute `.app` path. An existing
installation is moved to a timestamped sibling backup before replacement.
The destination's parent directory must exist and be writable. For example:

```zsh
mkdir -p "$HOME/Applications"
./tool/macos_manager.zsh install "$HOME/Applications/Convenient Test Manager.app"
```

Prerequisites: native Apple Silicon terminal, Flutter, Xcode command-line tools,
Python 3, and CocoaPods while this project retains its Podfile. Current project
settings target arm64; Flutter 3.47 migrated the minimum macOS version to 12.0.
Launching a macOS worker also requires `/usr/bin/python3`, supplied here by
Apple/Xcode tools. The launcher uses it to create an isolated process group
before executing Flutter, so cancellation can clean up build descendants.
If isolation cannot be established, launch fails with a visible error.
Flutter may update configuration/dependency files during a build; inspect your
diff before committing to your fork.

## Launch a test worker from the GUI

Open **Convenient Test Manager** from Spotlight or Finder. Its working directory
does not select the application being tested. Choose the Flutter project folder
in the launcher, then an entrypoint under `integration_test/` and a device.
The entrypoint must call `convenientTestMain`; an ordinary `testWidgets` file or
`lib/main.dart` does not provide a convenient-test worker.

Use **Start** to build and launch the selected worker. Once the suite appears,
select tests or use **Run All**. **Stop** terminates the Flutter process owned by
this GUI session. Normal app quit also waits for that cleanup. The GUI remembers
selections but does not automatically start a worker when reopened.

The first version supports local macOS workers and iOS simulators. Android,
physical phones, and web devices are excluded from the chooser because their
network routing needs additional configuration. Your project must support the
selected platform. Flutter 3.47.4 was used for development and native checks.

If Flutter is not found, choose the SDK's `bin/flutter` executable. Resolution
checks an explicit choice, project FVM configuration, a valid saved choice, then
PATH. A GUI opened from Finder may have a smaller PATH than your terminal.
macOS also attributes child-process file access to the launching app. A Flutter
command working in a terminal does not prove that the Finder-launched manager
has the same file access. If discovery fails or times out only from Finder,
inspect the manager's macOS privacy permissions and the diagnostic logs.
Advanced settings accept one `KEY=VALUE` Dart define per line; preserve your
application's seed/profile defines. The launcher supplies its own manager host,
manager port and source-directory defines and rejects attempts to override them.

Project paths and entrypoints are revalidated before launching. Paths with spaces
are passed as process arguments. A build can take time; inspect the launch logs
for compiler errors, dependency resolution, device issues or a wrong SDK.
Cancelling a file chooser keeps the previous selection.

## GUI and CLI isolation

Each GUI-owned launch uses a new loopback manager port, a dynamically allocated
worker VM port, the worker's authenticated WebSocket URI, and a separate session
ID/report directory. It does not claim the CLI's default ports or attach to a
running CLI worker at startup. No separate background daemon is needed.

The headless CLI retains its existing defaults: manager port **3579** and worker
VM port **9753**. Separate ports do not isolate build directories, databases,
accounts or devices: use separate app checkouts and data/resources for concurrent
runs. Two managers must not control the same worker.

Session diagnostics show the GUI's endpoints and report location. **Load Report**
is available while idle for offline inspection of saved GUI or CLI reports.
Stop an owned worker or Disconnect an external worker before loading a report.

## Connect an independently launched worker

Use the explicit **Connect existing worker** controls only for a worker intended
for this GUI. Enter its manager port and full WebSocket URI, including any
authentication path. The GUI binds that manager port before connecting. It does
not own or terminate this external worker. A port already occupied by another
manager produces an error; leave that manager running and use another port.

For a manually launched local worker, this example uses the conventional ports.
Do not use these ports while a headless manager owns them:

```zsh
cd /absolute/path/to/your/flutter-app
flutter run -d macos integration_test/your_convenient_test.dart \
  --debug --host-vmservice-port 9753 --disable-service-auth-codes \
  --dart-define CONVENIENT_TEST_MANAGER_HOST=127.0.0.1 \
  --dart-define CONVENIENT_TEST_MANAGER_PORT=3579 \
  --dart-define "CONVENIENT_TEST_APP_CODE_DIR=$PWD"
```

Then enter manager port `3579` and worker URI `ws://127.0.0.1:9753/ws` in the GUI.
If the worker started before the GUI listener and reports no tests, use
**Reload Info** after attaching to request its suite information again.
That manual compatibility example disables VM authentication for a predictable
local URI; GUI-owned launches retain authentication automatically.

If connection readiness fails, check that the chosen entrypoint reports a
convenient-test suite, that the worker is still running in debug mode, and that
its manager port matches the GUI. Use Stop to clean up a failed owned launch
before retrying. Do not reconnect to an unrelated worker just because it is
listening on a familiar port.
If Flutter hot restart stalls, use Stop and Start to create a fresh owned worker.

## Verification

Native results and remaining limitations are recorded in
[launcher acceptance notes](../packages/convenient_test_manager/test/launcher/native_launch_acceptance.md).

For the repeatable Convenient Test UI journey and native macOS/iOS simulator
smoke runner, see [launcher UX testing](../packages/convenient_test_manager/test/launcher/launcher_ux_testing.md).
