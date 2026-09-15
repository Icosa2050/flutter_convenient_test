# Native launcher acceptance — 2026-09-12

Implementation is being verified locally on branch `codex/macos-worker-launcher`,
based on `b52fb98`, with Flutter 3.47.4 on Apple Silicon macOS. Source changes are
uncommitted; these results do not identify a published release.

## Disposable fixtures

Two independently generated macOS apps live outside the repository at
`/tmp/convenient-launcher-cli-20260912/worker a` and `worker b`. They have distinct
bundle identities and use the current checkout's convenient-test packages via
path dependencies. Each suite increments its own counter and checks the result.
The fixtures include `ConvenientTestWrapperWidget` for action screenshots.
Neither fixture accesses Nebrivo accounts or data.

The committed-source candidate fixture is
`packages/convenient_test/example/integration_test/launcher_smoke_test.dart`.
Its scoped analyzer passed. No macOS platform was generated in the example;
native macOS execution uses the disposable fixtures above.

## Completed evidence

- Native process probe launched fixture A using a loopback manager on port 0,
  received the full authenticated machine-protocol WebSocket endpoint, and
  stopped the owned Flutter/app process. An early-stop Flutter temporary-folder
  cleanup warning was observed, so this is only startup/ownership evidence.
- Standalone CLI baseline on manager **3579** and VM **9753** passed on
  2026-09-12 at **19:08:31 UTC**, with **`calcExitCode=0`** for
  **B launcher smoke**. Manager PID was 64354, Flutter PID 65637. The subsequent
  machine-protocol `app.stop` removed the worker app and DDS processes.
- CLI logs: `/tmp/convenient-launcher-cli-20260912/cli-baseline-manager.log` and
  `cli-baseline-worker.log`. Reports are under
  `/tmp/convenient-launcher-cli-20260912/cli-b-report.bin/` (the report-save
  argument is a directory despite that temporary path's suffix).
- The CLI run emitted existing integration-test plugin and iOS video-recorder
  warnings on macOS. Its convenient-test action/report and manager exit result
  passed; those warnings are not being treated as platform-video support proof.
- Astra reviewed the process/VM changes, found two disposal/cancellation races,
  and re-reviewed the fixes with no blocking findings. The focused recheck ran
  7 VM endpoint tests and 20 worker tests successfully.

## GUI and concurrent CLI evidence

Additional native evidence (source before the final picker/recovery corrections,
with the verified read-only entitlement applied to the test bundle):

- Project and SDK pickers opened. A non-project folder produced an explicit
  validation error. With minimal PATH `/usr/bin:/bin:/usr/sbin:/sbin`, selecting
  a valid project reported the missing Flutter executable; selecting the SDK's
  absolute `bin/flutter` path discovered macOS. The resulting missing-test-list
  recovery defect was reproduced and corrected with two new controller tests.
- GUI session `gui-1789241521037655-f801be6d80646043` used manager **49299** and
  authenticated VM **49389**; **A launcher smoke** displayed a green success
  result with TAP and ASSERT action rows. Its Stop removed the worker app/DDS
  and released both ports at **19:34:15 UTC**.
- During that Stop, CLI manager PID **40546** and Flutter PID **40594** used
  **3579/9753** for fixture B. It subsequently reported progress every five
  seconds and completed **B launcher smoke** with **`calcExitCode=0`** at
  **19:35:55 UTC**. Logs: `cli-coexistence-manager.log` and
  `cli-coexistence-worker.log` in the temporary artifact directory.
- GUI restarted while that CLI test was still active, using session
  `gui-1789241685269078-acb88119bcdc79dd`, manager **50039**, and authenticated
  VM **50091**. A listener inventory showed GUI PID **27504** on 50039 beside
  the CLI's listeners. The fresh GUI displayed only fixture A's suite.
- After the CLI finished, its Flutter worker was stopped through `app.stop`.
  No fixture-B app/DDS or legacy listener remained. The GUI then ran and passed
  another TAP/ASSERT smoke test at **19:36:48 UTC**.
- **Cmd-Q while owning a live worker passed** at **19:38:21 UTC**: manager PID
  27504, app PID 43262, and DDS PID 43267 exited; ports 50039/50091 were released.
  Evidence is in `gui-coexistence-manager.log` and the native process checks.
- GUI reports are beneath
  `~/Library/Application Support/com.example.convenientTestManager/launcher/sessions/`,
  in the two session-ID directories above, separate from the CLI report root.
- The first release package built successfully; all four Mach-O binaries were
  arm64-only and its ad-hoc signature verified. A final source rebuild/install
  will repeat this check.

## Installed-app boundary

The source through fixes21/23 was installed at
`/Applications/Convenient Test Manager.app`; the prior app was retained as
`/Applications/Convenient Test Manager.app.backup-20260912-223307-9816`.
Install and standalone verify confirmed all four Mach-O binaries arm64-only
and a valid local signature. The discovery lifecycle fixes were subsequently
installed, retaining another backup dated20260912-230336-69768. The final Stop
retry correction was installed at23:12 local time on2026-09-12 after its
regression proof. Standalone architecture and deep strict signature checks
passed for that installed bundle.

Finder/LaunchServices launch exposed an additional boundary: `flutter devices
--machine` stayed blocked in synchronous directory opening. The identical SDK
query completed from the terminal. An explicit project cwd did not resolve it.
macOS TCC logged a `kTCCServiceSystemPolicyAllFiles` preflight denial attributed
to the installed manager, while terminal-launched runs were attributed to
Ghostty. The exact blocked directory and causal permission requirement are not
proven. No privacy settings were changed. The sample and controlled-probe notes
are in `27-discovery-sample.txt` and `27-native-evidence.md` in the temporary
artifact directory.

Fix27 adds bounded discovery failure/retry; review28 found shutdown/late-start
ownership gaps, addressed by fix29. A pre27 installed-app quit left
its stuck discovery child alive; the parent identified and terminated only that
child. All diagnostic wrappers are deselected and the real SDK path restored.

The rebuilt installed app passed early quit during discovery: manager74290 and
owned query74296 both exited. A separate launch reached the discovery failure
state after its deadline, restored chooser/report controls, and left no query
running. Review30 found that Stop did not retry retained discovery; the parent
reproduced the missing second cancellation in a regression test, then fixed
Stop's resource guard and cleanup path, including stale selection suppression.
The strengthened test covers another failed retry followed by successful cleanup;
a second test covers Stop during active discovery. All40 controller tests and
all128 GUI/launcher/report tests passed afterward. Shared-manager13 tests and
analysis remained green; final GUI analysis and diff whitespace checks passed.

Latest combined checks: 128 GUI/launcher/report tests and13 shared-manager tests
passed; full GUI and shared-manager analysis found no issues. Astra cleared the
report/reconnect authority fixes and startup-timeout containment. Rebuilt GUI
cancelled session `gui-1789244337388361-39eda7395609a01a` during startup and
released55105 with no late fixture-A process. Idle native Load Report opened the
completed CLI B report and returned to the launcher.

A final native reconnect check exposed one hot-restart hang in session
`gui-1789244423197169-364e0591cbbcc7bf` on55979/56299. The fresh follow-up session
`gui-1789244588874870-92d453a342646f04` on58794/59058 passed both before reconnect
(20:23:36UTC) and after reconnect (20:24:02UTC); its initial UI snapshot showed
only a normal transient restart, not another hang. Authenticated endpoints were
preserved and independent CLI B remained on9753. A further fresh session
`gui-1789245027737216-fccb9ac553b52445` on50677/50778 also passed after reconnect
before its first Run All. Thus the first hang was not reproduced by either
follow-up sequence. Its cause remains unproven; Stop/Start recovered it.

Further failure-path findings:

- Closing the last manager window with a running owned worker passed: session
  `gui-1789242937312777-ca12d9b89da4579d`, manager PID55161, Flutter PID92870,
  app PID93471, manager55228 and authenticated VM55268 all disappeared after
  the native close-button action. No fixture-A process remained.
- An occupied explicit manager port53808 produced the expected error and left
  the original disposable listener PID77188 alive and listening.
- Explicit external attachment to fixture B on3579/9753 accepted the plain
  `/ws` URI. Because B started before the GUI listener, Reload Info requested
  its suite; the GUI then ran B to a green TAP/ASSERT result. Session
  `gui-1789242822433435-d8466980ba27b15d` Disconnect released3579 but left app
  PID86661, DDS PID86672 and9753 alive. The parent subsequently stopped B
  through its own CLI runner. Evidence: `gui-failures-external.log`.

- Corrected SDK recovery passed natively: with fresh task-owned preferences and
  minimal PATH, the test dropdown remained populated after SDK discovery failed;
  choosing the real Flutter executable recovered devices and enabled Start
  without reselecting the project.
- The deliberately invalid `integration_test/broken_test.dart` failed with exit
  code 1, exposed its compiler errors in launch logs, released port 52975, and
  allowed selection of the valid entrypoint again.
- **Build cancellation initially failed native process containment.** Session
  `gui-1789242362782554-518783d2e146f104` started at 19:46:02 UTC on manager53131.
  After Stop during build, the GUI returned idle and released its listener, but
  app70458/DDS70461 started at19:46:15UTC and remained PPID1 orphans in inherited
  PGID55160. The parent identified and terminated only those two fixture
  processes. This was corrected by the isolated process-group implementation
  and the real/native rechecks below; fake cancellation tests alone had not
  established containment.
- The isolated-group fix passed a real process-family/sibling test and a direct
  Flutter cancellation probe. At20:10:45UTC the probe cancelled root/group43974
  during compilation, before `app.start`; Stop completed20:10:47UTC. The group
  remained empty after25seconds and no fixture-A app remained. Flutter emitted
  a temporary app.dill/compiler shutdown error during cancellation. Earlier
  probes also confirmed post-build Stop; those are not build-phase evidence.
  Astra then identified a separate readiness-timeout containment race. Its fix
  passed29 focused tests and independent recheck25. The rebuilt GUI cancellation
  repetition above passed with the final containment implementation.

## Repeatable automated proof added after implementation

The user-requested test pass added a shared Convenient Test launcher UI journey,
a host entrypoint, and a disposable native fixture/runner. On 2026-09-12 the full
GUI suite passed **131 tests**, including the Convenient Test host journey;
the shared manager passed **13 tests**. GUI and shared-manager analysis passed.
The host journey saved a 245217-byte action report with 17 embedded PNG images
at `/tmp/convenient-launcher-host.rbA0ZF/ConvenientTestWidgetTest/WIDGET-TEST-20260912-233431-479.bin`.

`tool/test_macos_launcher.zsh` completed both native platforms in one invocation.
It uses the production LauncherController, session services, Flutter process
adapter, real VM connection, and manager test execution/report services:

| Worker | Session | Manager / VM ports | Result |
| --- | --- | --- | --- |
| macOS | `gui-1789249218924642-d4b429c683f3b018` | 64290 / 64368 | One success; no pending, running, or failed tests |
| iOS 26.5 simulator, iPhone 17 Pro | `gui-1789249257437023-34bac7b8b4f68e30` | 64494 / 64594 | One success; no pending, running, or failed tests |

Both sessions used authenticated loopback VM endpoints, saved non-empty reports,
and returned to idle after Stop with no owned process-group members or manager
listener. The probe computes `equivalentExitCode=0` from the same live suite
state buckets as the headless manager; it does not invoke that private method.
The runner exited zero, removed its disposable app/build root, and shut down the
simulator it had booted. Evidence and report directories are retained under
`/tmp/convenient-launcher-cli-20260912/32-native-run-20260912T213934Z/`;
the combined record is `32-native-evidence.md` in the parent directory.

A parent recheck of the final runner also passed both platforms after removing
the machine-specific simulator default and strengthening the authentication
and VM-port closure assertions. macOS session
`gui-1789249523875605-6c6bdd1e7ae19e0b` used 49504/49775; iOS session
`gui-1789249592475046-abbfab8f96e6a676` used 49878/49956. Both reported
`equivalentExitCode=0`, `managerPortClosed=true`, `workerPortClosed=true`, and
empty owned process groups. The command exited zero; the simulator was Shutdown
and no process matching this run's fixture or evidence path remained afterward.
The final record is `/tmp/convenient-launcher-cli-20260912/34-native-final-evidence.md`.

These are terminal-native controller tests. They do not resolve or retest the
installed app's Finder/TCC boundary. The launcher UI journey injects native
picker/process boundaries; its host result is separate from the native proof.
See [launcher_ux_testing.md](launcher_ux_testing.md) for repeatable commands.

## Limits

- Native macOS and one iOS 26.5 simulator were exercised. Other simulator
  versions and physical devices were not covered by this pass.
- iOS video recording reported `Host recording is already in progress` in
  the paired run. Test assertions and reports passed; video capture is not
  claimed as verified. No unrelated recording process was stopped.
- One native hot-restart request remained pending until Stop. Subsequent
  pre-first-run and post-success reconnect sequences passed. Do not claim this
  intermittent Flutter/VM interaction has a proven root cause or durable fix.
- Tests use disposable app identities and folders. Network/session isolation
  does not isolate shared user checkout contents, devices, databases or accounts.

Separate Codex CLI prompts, JSON event logs and final reports are retained under
`/tmp/convenient-launcher-cli-20260912/`; these temporary artifacts are local and
are not part of the fork's source.
