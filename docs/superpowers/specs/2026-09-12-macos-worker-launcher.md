# macOS worker launcher

## Outcome

From the installed GUI manager, select a Flutter project, an integration-test
entrypoint and a device, then start the worker and see its tests without opening
a terminal. Remember the last selections. Keep externally launched workers and
saved-report viewing supported.

## Scope

- macOS GUI, one managed worker at a time, with an independent session ID,
  manager listener, worker VM endpoint and report directory per launch. CLI
  defaults remain 3579/9753; GUI-managed runs use automatically allocated ports.
  Device selection uses the selected Flutter SDK's device list.
- Native project directory chooser; validate `pubspec.yaml` and list `.dart`
  files recursively beneath `integration_test`, showing relative paths. These
  are candidate entrypoints, not statically proven convenient-test suites.
- Persist one last-used configuration: project, entrypoint, SDK executable,
  device ID and user-supplied Dart defines. No multi-profile editor in v1.
- Select a Flutter executable explicitly when a saved path or PATH lookup fails.
  Resolve the project's `.fvm/flutter_sdk/bin/flutter` first when present; show
  the SDK chosen. Do not silently install or switch SDKs.
- Start a debug worker in the selected project with correct source-directory
  and connection defines. Show startup progress, bounded logs and clear failures.
- Automatically connect only after this launched worker is ready. Never attach
  automatically to an unrelated process. The VM endpoint must come from the
  owned Flutter process's machine-protocol events.
- Stop only a worker owned by this GUI session. Closing the manager with an
  owned worker must request orderly shutdown and handle failure visibly.
- New UI strings use localization resources; new controls have stable semantics
  identifiers suitable for accessibility and Maestro/convenient-test automation.
- Keep build/install Apple Silicon-only through `tool/macos_manager.zsh`.
- Local changes only. No push or PR; any later remote operation is restricted
  to the user's `Icosa2050/flutter_convenient_test` fork.

## Interaction

The disconnected page shows project, entrypoint and device fields, an expandable
SDK/Dart-defines section, Start, and an explicit Connect to existing worker
action. Invalid selections disable Start with a localized explanation.

During launch, show the exact project and test, progress and build logs. Keep
Stop available during building and testing. When connected, use the existing
test-selection interface and retain a compact owned-worker status/Stop control.
Changing project clears the prior entrypoint; changing SDK refreshes devices.
Late results from a previous selection must not overwrite current state.

An active CLI run on 3579/9753 must not block a GUI-managed launch. Bind the
GUI manager listener on an OS-assigned loopback port and pass its actual port
to the worker. Request an OS-assigned VM port and use the owned process's reported
endpoint. If the selected SDK cannot allocate the VM port, use a bounded
reserve/release/retry strategy and handle the binding race explicitly.
External connection is an explicit action, never a fallback after launch fails.
It uses explicit manager-port/worker-endpoint fields with legacy defaults;
refuse a manager port already owned by another process. This is not attachment
to an existing headless manager. Display owned session endpoints in diagnostics.

Network isolation does not isolate app data, devices or source files. Warn about
concurrent use of the same checkout/device; real coexistence proof uses separate
worker checkouts and devices or otherwise proven-isolated app data. Session
report paths are unique, and stopping one session affects only its own processes.

## Boundaries

No test-code generation, dependency installation, Nebrivo-specific seeding,
general port-management UI, multiple GUI-owned workers, scheduler, remote device setup, full-app
translation project, or Windows/Linux launcher in this increment. User-defined
seed/profile values are passed through without knowing Nebrivo internals.
Do not weaken signing or change macOS permissions for this feature.
There is no separate daemon in this increment: the GUI owns its session. A
future daemon can reuse the process-management boundary but is not implemented.

## Acceptance

1. Launch the installed GUI from Finder/Spotlight with a minimal environment.
2. Choose a project whose path contains spaces; choose a real entrypoint/device.
3. Start, see its suite in the manager, run a passing convenient test, inspect
   its action/result output, stop, and successfully launch again.
4. Prove clear errors for missing SDK, invalid project, exited worker, failed
   compilation, occupied ports and cancelled chooser. No unrelated process dies.
5. Prove last selections restore, custom defines reach the worker, and malformed
   saved configuration does not prevent startup.
6. Unit/widget tests cover process ownership and asynchronous selection races;
   a native convenient-test fixture supplies end-to-end worker evidence.
7. Release build, architecture/signature verification and fork diff review pass.
8. Run CLI and GUI journeys concurrently with distinct workers. Demonstrate
   separate endpoints/results/reports, stop the GUI worker while the CLI continues,
   and in a second run stop the CLI while the GUI continues. Observe progress
   after each stop, not merely surviving PIDs. Test stale endpoint/session events.

## Time expectation

Revised planning target with CLI coexistence: approximately 4 hours of Astra
execution; estimated range 3–5 hours with moderate confidence. Native lifecycle or integration failures
can exceed this. Report a concrete blocker and revised estimate if evidence
changes; never omit acceptance checks to fit the estimate.
