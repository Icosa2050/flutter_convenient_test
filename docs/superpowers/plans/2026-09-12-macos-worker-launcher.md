# macOS Worker Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Default to inline execution with aggregate checkpoints; do not dispatch implementation agents without authorization.

**Goal:** Launch a selected convenient-test worker directly from the installed macOS GUI and manage its lifetime safely.

**Architecture:** A GUI-owned controller coordinates project discovery, saved selections and a single Flutter machine-protocol process. Each launch owns a session ID, dynamically bound manager listener, VM endpoint and report directory. The existing test UI uses an explicitly selected runtime VM endpoint; CLI defaults remain unchanged. This provides CLI coexistence without a separate daemon.

**Tech Stack:** Flutter/Dart, existing file_picker/path_provider/GetIt, dart:io Process, Flutter machine protocol, flutter_localizations/gen-l10n, flutter_test and convenient_test_dev.

**Spec:** `docs/superpowers/specs/2026-09-12-macos-worker-launcher.md`

## Execution status

The user subsequently authorized implementation in separate Codex CLI runs.
Selection, localization and UI use Sol Medium; process/session work uses Sol
High; independent reviews use Astra Medium. Detailed run artifacts are local
under `/tmp/convenient-launcher-cli-20260912/`.

Implementation and native GUI/CLI coexistence are exercised. Native checks
covered SDK recovery, build failure/cancellation, external attachment, occupied
ports, report loading, Cmd-Q and last-window close. Independent reviews drove
fixes for process containment, session/report authority, discovery deadlines,
shutdown and cleanup retry. The subsequent requested testing pass passed131
GUI tests (including a Convenient Test host journey) and13 shared-manager tests
with clean analysis. The repeatable native runner passed macOS and iOS 26.5
simulator workers, report saving, and Stop cleanup with distinct session IDs.

The arm64 bundle is installed locally. Finder-launched Flutter discovery still
hits an unresolved macOS file-access boundary; timeout and quit now cleanly
release its owned query. No privacy permissions were changed. See the native
acceptance notes for that remaining verification limit and one intermittent
hot-restart observation. The detailed unchecked steps below are the original
planning checklist, not a current completion ledger; this status and the
acceptance notes supersede them. No commit or remote publication was performed.

## Global Constraints

- macOS GUI; one owned worker with isolated ports; preserve CLI defaults 3579/9753.
- v1 device list includes macOS and iOS simulators only. Filter SDK device metadata
  before discarding targetPlatform/emulator fields; physical phones, Android and
  web require separate networking support and must not be offered as working targets.
- Allocate a unique session ID and report path for each GUI launch. No automatic
  reuse of a CLI listener or endpoint. Network isolation does not guarantee
  isolation of worker devices, app databases or files in the selected checkout.
- At most five authored/generated repository files per task. File ownership is
  listed below; split a task before expanding its file list beyond five.
- Preserve existing work. Recheck branch, SHA and status before implementation.
  Planning baseline was `fee7e85` with a clean working tree; live state wins.
- No implementation, commit or push is authorized by this planning document.
  During a later authorized implementation, prepare reviewed local changes;
  keep any requested push restricted to `Icosa2050/flutter_convenient_test`.
- Before editing screens, discuss the concrete UI approach with available PAL,
  Codex CLI or Claude CLI as required by the user's AGENTS instructions. Read-only
  consultation must cover ownership, startup conflict states and accessibility.
- Graph-first structural discovery with coverage verification. Serena is active.
  Task-master tools were unavailable during planning; use them if available at
  execution. Save important decisions through second-brain when appropriate.
- Prefer `.tools/testing/flutter_errors_lib_only.py` and
  `flutter_errors_test_only.py` when present. This repository had no
  `.tools/testing` during inspection; use scoped Flutter analyze/test commands
  and report that fallback. Do not run the Riverpod checker for this non-Riverpod change.
- No new hard-coded product copy. Localize only the new launcher and its errors.
- Keep the installed arm64 packaging script. Do not claim ports owned by an
  active Nebrivo test run or terminate that run. Concurrent acceptance uses
  dedicated disposable workers with isolated checkout/device/data resources.

## Evidence and implementation decisions

- `HomePage._Body._buildBody` currently returns a disconnected hint; the launcher
  replaces that branch, with a status control retained when connected.
- Golden Diff already uses `FilePicker.platform.getDirectoryPath()` and report
  loading uses `pickFiles`; no new native picker dependency is needed.
- `RealVmServiceWrapperService()` currently connects in its constructor.
  `connect()` catches failures and returns normally; do not equate its completion
  with readiness. Require `connected` plus suite information before showing Ready.
- Shared setup unconditionally starts gRPC. `serve()` currently discards its
  future; change this so bind failures are testable and GUI-visible.
- Existing GUI test setup starts that real listener even with a fake VM wrapper.
  Provide a no-server setup path before running widget tests beside other work.
- Release remains unsandboxed. Native testing showed file_picker requires the
  user-selected read-only entitlement even in this configuration; add it while
  preserving allow-jit. Test Finder launch because terminal PATH assumptions
  are insufficient.
- Existing GUI contains hard-coded English and no app localization delegate.
  Add English resources/delegate for this feature without translating old screens.
- Use `flutter run --machine` with separate executable/argument vectors and
  `runInShell: false`. Parse JSON protocol messages as well as plain build output.
  Verify the actual selected SDK's protocol before implementation of shutdown;
  do not rely on text matching “VM Service” as the sole readiness signal. Verify
  `--host-vmservice-port 0` against the selected SDK; the returned debug-port URI
  is authoritative only when emitted by this session's owned process.

## Task 1: Selection data, discovery and saved configuration (4 files)

**Files, relative to `packages/convenient_test_manager/`:**
- Create `lib/launcher/launch_configuration.dart`
- Create `lib/launcher/project_discovery.dart`
- Create `lib/launcher/launcher_preferences.dart`
- Create `test/launcher/project_discovery_test.dart`

**Interfaces:**
```dart
class LaunchConfiguration {
  final String projectDirectory; // canonical absolute path
  final String entrypoint; // project-relative path
  final String flutterExecutable; // absolute executable path
  final String deviceId;
  final Map<String, String> dartDefines;
  // Explicit constructor plus versioned toJson/fromJson.
}
class ProjectDiscovery {
  Future<List<String>> entrypoints(String projectDirectory);
  Future<List<({String id, String name})>> devices(String flutterExecutable);
}
class LauncherPreferences {
  Future<LaunchConfiguration?> load();
  Future<void> save(LaunchConfiguration configuration);
}
```

- [ ] Write tests using temporary directories for absent pubspec, empty tests,
  nested entrypoints, paths with spaces, symlinks outside the project, stale
  saved paths and malformed JSON. Use an injected process runner for devices.
- [ ] Run `flutter test test/launcher/project_discovery_test.dart`; confirm the
  new behavior fails before implementing it.
- [ ] Implement sorted discovery without following external directory symlinks.
  Validate entrypoint containment again at launch, not only when listing.
- [ ] Resolve SDK in this order: explicitly chosen SDK, project `.fvm/flutter_sdk`,
  saved valid SDK, PATH. Expose failure for manual selection; never invoke a shell
  startup file to discover it. Call devices with `['devices', '--machine']`.
- [ ] Persist schema version 1 JSON atomically in the manager's application-support
  directory, separate from `.config/convenient_test.json`. Treat unknown versions
  and invalid data as no saved selection with a displayable diagnostic.
- [ ] Run focused tests. Prove changing project cannot retain an invalid test path.

## Task 2: Owned worker process and protocol (4 files)

**Files, relative to `packages/convenient_test_manager/`:**
- Create `lib/launcher/flutter_worker_process.dart`
- Create `lib/launcher/flutter_machine_protocol.dart`
- Create `test/launcher/flutter_worker_process_test.dart`
- Create `test/launcher/flutter_machine_protocol_test.dart`

**Interfaces:** `FlutterWorkerProcess.start(LaunchConfiguration, {required String sessionId, required int managerPort}) -> Future<void>`,
`stop() -> Future<void>`, `events -> Stream<WorkerEvent>`, `owned -> bool`.
Define `WorkerEvent` variants for log, appStarted/appId, debugPort, exited and
failure in `flutter_worker_process.dart`. Inject Process.start via a test seam.

- [ ] Confirm machine event/request shapes in the installed Flutter SDK source
  or official protocol documentation. Capture representative messages as inline
  test data, including fragmented UTF-8, multiple records, non-JSON lines and
  malformed messages. Preserve stderr output as diagnostics.
- [ ] Write tests for argv/cwd, duplicate starts, spawn failure, build failure,
  early exit, cancellation during build, graceful stop, stop timeout, and stale
  events from the previous run. First observe failures, then implement.
- [ ] Build arguments from structured fields:
  ```dart
  final arguments = <String>[
    'run', '--machine', '--debug', '-d', config.deviceId,
    config.entrypoint, '--host-vmservice-port', '0',
    '--dart-define', 'CONVENIENT_TEST_APP_CODE_DIR=${config.projectDirectory}',
    '--dart-define', 'CONVENIENT_TEST_MANAGER_HOST=127.0.0.1',
    '--dart-define', 'CONVENIENT_TEST_MANAGER_PORT=$managerPort',
    for (final entry in config.dartDefines.entries) ...[
      '--dart-define', '${entry.key}=${entry.value}',
    ],
  ];
  ```
  Reject user overrides for reserved source-directory/host/port keys. Keep
  user-provided values literal, including spaces, dollar signs and quotes.
- [ ] Prove port-zero behavior with the selected SDK. Flutter 3.47.4 was verified
  during CLI consultation; fail clearly for an unsupported SDK instead of adding
  a reserve/release port race. Preserve service authentication and propagate the
  owned process's full wsUri, including path/token and DDS endpoint. Do not use
  baseUri as the VM endpoint. Accept app.started/debugPort in either order.
- [ ] Start with `workingDirectory: config.projectDirectory`,
  `runInShell: false`; track an increasing run ID and the actual Process handle.
  Limit retained logs to 2,000 lines and truncate individual oversized records.
- [ ] Stop through the confirmed `app.stop` protocol using this run's appId.
  For cancellation before appId, signal only the owned Flutter process. Add a
  bounded escalation for that handle; never use pkill or port-owner killing.
  Do not report Idle until process termination is confirmed. On failed cleanup,
  show the owned PID and failure and block another launch; do not hide leftovers.
- [ ] Run `flutter test test/launcher/flutter_worker_process_test.dart
  test/launcher/flutter_machine_protocol_test.dart`.

## Task 3: Explicit startup and testable server ownership (5 files)

**Files:**
- Modify `packages/convenient_test_manager_dart/lib/services/convenient_test_manager_service.dart`
- Modify `packages/convenient_test_manager_dart/lib/services/real_vm_service_wrapper_service.dart`
- Modify `packages/convenient_test_manager_dart/lib/misc/setup.dart`
- Create `packages/convenient_test_manager_dart/test/manager_startup_test.dart`
- Modify `packages/convenient_test_manager/lib/misc/setup.dart`

- [ ] Add tests proving no bind/connect in deferred mode, awaited bind failures,
  default headless setup compatibility, and server shutdown releasing its port.
  Use an ephemeral test port for actual socket tests.
- [ ] Make `serve({int port = kConvenientTestManagerPort, String address = '0.0.0.0'})`
  return `Future<int>` with the actual bound port. Confirm grpc.Server's port
  accessor in the installed dependency. GUI calls it with port 0 and address
  127.0.0.1; preserve CLI defaults. Retain its server and add `shutdown()`.
  Reject or make repeat start
  idempotent explicitly; do not create untracked second listeners.
- [ ] Add `RealVmServiceWrapperService({bool autoConnect = true})`; preserve the
  current constructor default. No generated observable fields are required.
- [ ] Add `startManagerServer = true` and `autoConnectVm = true` setup options.
  Await serve when requested; retain current defaults for CLI callers.
- [ ] Forward `startManagerServer` and `autoConnectVm` through GUI setup with
  defaults preserved for now. Task 4 changes production wiring and disables
  listeners in the existing GUI test setup. New launcher tests use no sockets.
- [ ] Run `dart test test/manager_startup_test.dart` in the Dart-manager package
  with ephemeral ports. Run existing GUI tests after Task 4's isolation change;
  investigate baseline golden drift without blindly replacing golden assets.

## Task 3B: Runtime VM endpoint and session detachment (4 files)

**Files:**
- Modify `packages/convenient_test_manager_dart/lib/services/vm_service_wrapper_service.dart`
- Modify `packages/convenient_test_manager_dart/lib/services/real_vm_service_wrapper_service.dart`
- Modify `packages/convenient_test_manager/test/fake_vm_service_wrapper.dart`
- Create `packages/convenient_test_manager_dart/test/vm_endpoint_test.dart`

- [ ] Change the abstract and concrete signature to `Future<void> connect({Uri? uri})`.
  Omitted URI retains the legacy compile-time endpoint for existing CLI callers.
  The GUI always supplies the owned session's verified loopback WebSocket URI.
- [ ] Add `Future<void> disconnect()` to the interface, real wrapper and fake.
  Dispose the VM client and subscriptions and invalidate connection generation
  before switching endpoints. Late events must not change the new connection.
- [ ] Test two distinct local endpoints, omitted-URI compatibility, rejected
  non-loopback GUI endpoints, stale events and repeated disconnect. Enforce
  loopback validation in the GUI path without breaking existing CLI remote-host
  support. Run `dart test test/vm_endpoint_test.dart` in the Dart-manager package.
- [ ] Verify hot restart continues using the active runtime connection. No
  UI-host/port changes should require recompiling the manager or worker protocol.

## Task 4: Launcher controller and GUI service registration (4 files)

**Files, relative to `packages/convenient_test_manager/`:**
- Create `lib/launcher/launcher_controller.dart`
- Create `test/launcher/launcher_controller_test.dart`
- Modify `lib/misc/setup.dart`
- Modify `test/main_test.dart`

**Interfaces:** `LauncherController extends ChangeNotifier`; expose immutable
selection/state snapshots, logs, `restore()`, `start()`, `stop()`,
`connectExternal({required int managerPort, required Uri workerUri})` and `shutdown()`.
States: idle, validating, starting,
connecting, running, stopping, failed. Expose error codes plus arguments; UI
maps them to localized copy. Construct it from discovery/preferences/process,
server-start/shutdown callbacks and the existing VM wrapper.

- [ ] Write state/ownership tests before implementation. Cover double-click
  Start, changing project/SDK during discovery, connect after stop, previous-run
  events, port conflicts, failed binding, and explicit external connection.
- [ ] GUI setup requests deferred server/VM startup, registers the controller,
  and restores selections. Do not automatically launch saved selections.
  Add `initializeLauncher = true` to GUI setup; disable it in existing tests
  together with `startManagerServer: false` and `autoConnectVm: false`.
- [ ] Before managed launch, allocate a fresh session ID and bind this GUI's
  loopback manager listener on port 0. Pass the returned port and session ID to
  the owned process. Connect only to the debug endpoint reported by that live
  session; validate loopback and reject events from an older generation.
- [ ] Reset run/suite/report state when switching sessions, preserving loaded
  offline reports as a separate mode. Assign a unique application-support report
  directory per session through existing report-save configuration. Never reuse
  a saved CLI report path for a GUI session. If store reset/report configuration
  needs additional source files, add a separate <=5-file task before implementation.
- [ ] Explicit external connect first binds the requested manager listener and
  fails clearly if owned elsewhere. The worker must already target that port.
  It does not claim process ownership and must never enable Stop for that process.
- [ ] After `connect()`, inspect `connected`; wait for suite info before Ready.
  Cap connection wait after debug readiness at 30 seconds. Build startup may
  take longer: display progress and allow cancellation instead of a short blind
  build timeout. Any failure retains useful logs and retry controls.
- [ ] Keep Stop available after the disconnected page disappears. On owned stop,
  disconnect the VM and release only this session's listener after worker exit.
  On GUI shutdown release its resources. Do not reset or signal other managers.
- [ ] Controller tests run two simulated sessions with distinct endpoints and
  report directories and prove stopping one never disconnects the other. Include
  a CLI-default listener already present during GUI allocation/start.
- [ ] Run `flutter test test/launcher/launcher_controller_test.dart`.

## Task 5: Launcher localization infrastructure (5 files)

**Files, relative to `packages/convenient_test_manager/`:**
- Modify `pubspec.yaml`
- Create `l10n.yaml`
- Create `lib/l10n/launcher_en.arb`
- Modify `lib/main.dart`
- Create `test/launcher/launcher_localization_test.dart`

- [ ] Add the SDK flutter_localizations dependency and `flutter: generate: true`.
  Configure `arb-dir: lib/l10n`, `template-arb-file: launcher_en.arb`,
  `output-dir: lib/build/generated/launcher_l10n`,
  `output-localization-file: launcher_localizations.dart`,
  `output-class: LauncherLocalizations`. Generated outputs remain ignored; use
  `package:convenient_test_manager/build/generated/launcher_l10n/launcher_localizations.dart`.
  Execution validated that root build output cannot be imported as a Dart package
  library; lib/build retains package imports and is ignored by the existing rule.
- [ ] Add resources for project/test/device/SDK selection, Start/Stop/Retry,
  connect-existing, logs, restoring/saving, empty test list, invalid SDK/project,
  reserved defines, port conflict, session diagnostics, shared-resource warning,
  external manager-port/worker-endpoint labels, process failure, cleanup failure and quit.
  Use ARB placeholders for ports, filenames and exit codes.
- [ ] Register the generated delegates/locales in MyApp. Preserve existing theme,
  routes and test builder. No translation of unrelated existing screens.
- [ ] Add a widget test proving delegates resolve required launcher strings and
  interpolated errors without missing-localization exceptions.
- [ ] Run `flutter gen-l10n` then
  `flutter test test/launcher/launcher_localization_test.dart`.

## Task 6: Launcher UI, connection status and normal close (5 files)

**Files, relative to `packages/convenient_test_manager/`:**
- Create `lib/launcher/launcher_panel.dart`
- Create `lib/launcher/launcher_session_bar.dart`
- Modify `lib/pages/home_page.dart`
- Modify `lib/main.dart`
- Create `test/launcher/launcher_panel_test.dart`

- [ ] Complete the mandated read-only PAL/Codex/Claude consultation before editing
  screens. Record any concrete lifecycle or UX correction in this plan.
  Completed Sol High CLI consultation is recorded in
  `/tmp/convenient-launcher-cli-20260912/00-consult.result.md`. Its UI advice:
  hide disconnected Run/Halt controls, keep owned Stop outside the body switch,
  and use a single AppLifecycleListener for bounded shutdown on normal quit.
- [ ] Write widget tests for chooser cancellation, missing test, state-dependent
  buttons, stale device refresh, errors, external ownership and narrow layouts.
  Inject chooser callbacks so tests do not open native dialogs.
- [ ] Build project chooser + relative test dropdown + device dropdown; Advanced
  contains SDK chooser and key/value Dart defines. Start delegates to controller.
  Do not allow arbitrary shell command text or parse shell quoting.
- [ ] Show automatically assigned ports/session ID in diagnostics. External
  connection expands explicit manager-port and worker-URI fields, initially
  3579 and ws://127.0.0.1:9753/ws. Editing these changes only external attachment.
  Explain that separate ports do not prevent shared checkout/device/data conflicts.
- [ ] Add stable semantics identifiers: `launcher.project.choose`,
  `launcher.test.select`, `launcher.device.select`, `launcher.sdk.choose`,
  `launcher.start`, `launcher.stop`, `launcher.connect_external`, `launcher.logs`.
  Pair IDs with localized accessible labels; distinguish identifiers from copy.
- [ ] Replace the disconnected hint only; retain saved-report mode and existing
  connected test UI. Display the session bar while an owned worker is active,
  including build/connection failure and stopping states.
- [ ] Use AppLifecycleListener/onExitRequested to await controller shutdown for
  normal app quit. Prove both Cmd-Q and last-window-close on macOS. If Cocoa
  bypasses that callback, stop at this gate and add a separately scoped native
  bridge task before claiming close behavior complete; do not assume it works.
- [ ] Run `flutter test test/launcher/launcher_panel_test.dart`, then all new
  launcher widget tests. Recheck text scaling and keyboard focus manually.

## Task 7: Native convenient-test proof and release delivery (4 files)

**Files:**
- Create `packages/convenient_test/example/integration_test/launcher_smoke_test.dart`
- Create `packages/convenient_test_manager/test/launcher/native_launch_acceptance.md`
- Modify `doc/macos-manager.md`
- Modify `README.md`

- [ ] Add a deterministic fixture using existing example app and slot contract:
  ```dart
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
  ```
  Import convenient_test_dev, flutter/material, flutter_test, and the example's
  main.dart both as `app` and for `MyApp`, matching existing main_test.dart.
  Avoid the existing sample suite's deliberately failing tests.
- [ ] Validate the fixture on an available supported example device. Do not
  generate a new macOS platform in the example just for this feature. If macOS
  worker proof is required, use an existing safe convenient-test entrypoint in
  an explicitly identified app checkout and preserve its seed/profile defines.
- [ ] Run scoped analyzers and new tests; run existing GUI and shared-manager
  regressions. New process tests must use fake processes or ephemeral ports.
- [ ] Capture the active checkout/device and allocated GUI session endpoints.
  Launch the release GUI through Finder/Spotlight, select the fixture, start,
  observe suite, run the test and capture the successful result/action screenshot.
  Stop, verify worker/app termination, restart successfully. Record commands,
  SDK, device, app/manager SHAs and screenshot/report paths in acceptance notes.
- [ ] Repeat native checks for invalid SDK, build failure, cancelled startup,
  explicit external connection, occupied manager/worker ports, and quit while
  running. Use only disposable test listeners/processes for conflict scenarios.
  A passing GUI flow is proven by displayed results/reports; do not claim a
  headless `calcExitCode=0` unless a separate headless run actually produced it.
- [ ] Run a dedicated CLI fixture on legacy 3579/9753 and a GUI fixture on its
  assigned ports simultaneously. Use separate checkout/device/data resources;
  avoid modifying or commandeering a user's existing run. Capture distinct
  manager PIDs, worker PIDs, endpoints, test identities and report paths.
- [ ] Stop the GUI session and observe another successful CLI action/test after
  that stop. Repeat with CLI stop and observe subsequent GUI progress. Reopen
  or restart GUI and prove it does not reconnect to the CLI endpoint. Record
  results and screenshots in native_launch_acceptance.md.
- [ ] Run `./tool/macos_manager.zsh build`; quit the GUI, run `install` and
  `verify`. Confirm four/all current Mach-O binaries are arm64-only and validly
  signed. Reopen installed app to verify persisted selections and startup.
- [ ] Document interactive usage, ownership, errors and advanced defines; link
  the guide from README. Record independently reviewed findings and resolution.
  Show final scoped diff and tests. No remote publication.

## Checkpoints and completion

- After Tasks 1–4 (including 3B): report process/controller tests, runtime endpoint
  compatibility and independent session ownership proof.
- After Tasks 5–6: report usable launcher and UI/localization verification.
- After Task 7: report native success, failure-path results, packaged installation,
  outstanding limitations and exact changed-file list.
- Do not declare completion for a chooser-only mockup, a spawned process without
  a connected suite, or a worker that cannot be safely stopped/restarted.
- Revised target: 3–5 hours of Astra execution, including runtime endpoints,
  coexistence review/tests and release verification. Native close integration,
  store reset and isolated real-app fixtures are the main schedule uncertainties.
