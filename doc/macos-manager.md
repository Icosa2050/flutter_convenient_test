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
Flutter may update configuration/dependency files during a build; inspect your
diff before committing to your fork.

## The manager does not select a project by its working directory

The GUI connects to a separately launched **debug test worker**. The worker is
your Flutter application started through an entrypoint that calls
`convenientTestMain`, not the ordinary `lib/main.dart` entrypoint.

The default connections in `consts.dart` are:

| Connection | Default | Purpose |
| --- | --- | --- |
| GUI to worker | `ws://127.0.0.1:9753/ws` | VM service and test control |
| Worker to manager | `127.0.0.1:3579` | Configuration and test reports |

Run the **worker** from the exact application checkout you want to test. Replace
the project path and journey filename below with your app and an existing
convenient-test entrypoint; retain any app-specific seed/profile Dart defines.

```zsh
cd /absolute/path/to/your/flutter-app
flutter run -d macos integration_test/your_convenient_test.dart \
  --debug \
  --host-vmservice-port 9753 \
  --disable-service-auth-codes \
  --dart-define "CONVENIENT_TEST_APP_CODE_DIR=$PWD"
```

Choose another device with `-d <device-id>` if the application does not support
macOS. The worker must run in debug mode for the VM service. The authentication
flag matches this manager's fixed `/ws` URL; keep this debugging service local.
The app-code directory define supplies the worker's source/golden-file context.

Open the GUI from any directory, or from Spotlight:

```zsh
open -a "Convenient Test Manager"
```

If it was opened before the worker became ready, click **Reconnect VM** (or
**Tap here to reconnect**). Once the test list appears, select tests or use
**Run All**. The GUI does not launch Flutter for you.

## When “VMService not connected” remains visible

Check both ports:

```zsh
lsof -nP -iTCP:9753 -iTCP:3579 -sTCP:LISTEN
```

- No listener on 9753: the worker has not started, exited, or uses another port.
- Worker uses a random port or authenticated URL: restart it with the flags above.
- A headless `convenient_test_manager_dart` process owns 3579: let that run finish
  before using the GUI on those ports. The GUI is itself a manager, not a viewer
  attached to the headless manager. Two managers must not control the same run.
- A worker on 9753 belongs to another checkout: do not connect to it accidentally.
  Check its terminal and process command before starting the GUI.

For Nebrivo, a managed test command can start its own headless manager. To use the
GUI interactively, launch just the selected convenient-test worker, preserving
the journey's required seed/profile arguments. Do not start both managers for
the same worker. You can inspect saved headless reports with **Load Report**
after the active run finishes.

Host/port constants use Dart compile-time environment values. Changing the
shell directory, exporting a variable before `open`, or passing `open --args`
does not reconfigure ports in the installed release GUI. Custom ports require
building the GUI with matching `--dart-define` values and starting a worker with
the same manager port and matching `--host-vmservice-port`. This packaging script
currently builds the standard default-port configuration.

## Source references

- `packages/convenient_test_common_dart/lib/src/consts.dart`: hosts and ports.
- `packages/convenient_test_manager_dart/lib/services/real_vm_service_wrapper_service.dart`:
  fixed WebSocket connection URL.
- `packages/convenient_test_manager_dart/lib/services/convenient_test_manager_service.dart`:
  manager's gRPC listener.
- `packages/convenient_test_dev/lib/src/support/static_config.dart`: source directory.
- `packages/convenient_test_manager/lib/main.dart` and `lib/misc/setup.dart`:
  GUI startup does not parse command-line arguments.
- Repository README, “Tutorial: Run examples” and “Getting started”: worker launch.
