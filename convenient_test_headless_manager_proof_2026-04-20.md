---
owner: codex
status: active
last_validated: 2026-04-20
related:
  - docs/tooling/ci_cd/convenient_test_ci_integration.md
  - test/TEST_EXECUTION_GUIDE.md
---

# convenient_test Headless Manager Proof And Fork Workflow (2026-04-20)

## Purpose

Document the root-cause investigation for flaky long-running macOS `convenient_test` flows, record the proof gathered in the manager-only investigation cycle, and define the recommended next steps for a local fork plus an upstream PR.

This document is intentionally focused on the `convenient_test` manager/runtime layer. It does not change app code, repo test structure, or Flutter SDK behavior.

## Executive Summary

The investigation proved that the headless `convenient_test_manager_dart` startup sequence is a real contributor to long macOS flow instability.

The strongest proven points are:

1. The worker starts by fetching a one-shot active integration-test config with:
   - `filter=match-nothing^$`
   - `reportSuiteInfo=true`
2. That first startup snapshot produces a fake report-only cycle with zero matching tests.
3. In the baseline long US flow, the headless manager later performs another `hotRestart` after the real test has already started.
4. A manager-only experiment that skips the startup `reloadInfo()` phase removes the post-`START` restart overlap in repeated runs.

Important nuance:

- This does **not** mean the manager startup issue is the only failure mode.
- After removing the restart overlap, the long US flow still times out later in `addQuickReading`.
- So the manager startup issue is **proven**, but it is **not sufficient** to explain every remaining long-flow failure.

## Scope And Non-Goals

### In Scope

- headless manager startup behavior
- worker startup config snapshots
- restart timing overlap with long macOS flows
- fork and PR strategy for `convenient_test_manager_dart`

### Out Of Scope

- switching Flutter channel to beta
- patching Flutter SDK in this cycle
- changing app package dependencies to git/master
- restructuring repo tests in this cycle
- fixing the later `addQuickReading` timeout in this cycle

## Environment

- Flutter: stable
- Platform: macOS
- App repo: this repository
- Manager sandbox: temporary upstream clone under `/tmp`
- Worker instrumentation: temporary local pub-cache patch

No repo-tracked source files were changed for the proof cycle itself.

## Controls Used

### Short Control

- [hello_convenient_test.dart](/Users/bernhard/Development/nebrivo-meter-action-electricity-consumption/integration_test/hello_convenient_test.dart)

### Long Control

- [us_property_meter_flow_convenient_test.dart](/Users/bernhard/Development/nebrivo-meter-action-electricity-consumption/integration_test/us_property_meter_flow_convenient_test.dart)

## Instrumentation Added During Investigation

Temporary instrumentation was added only to:

- local `convenient_test_dev` worker startup/config path
- temporary upstream `convenient_test_manager_dart` manager/store path

The logging captured:

- first `getWorkerCurrentRunConfig` response
- manager controller transitions
- `hotRestart start/end`
- execution filter resolution counts
- report-suite-info entry
- per-startup integration-run invocations
- route-entry markers in the long US flow

The temporary instrumentation was restored after the investigation.

## Baseline Findings

### Finding 1: The First Worker Snapshot Is The Active `match-nothing` Config

In the baseline short and long runs, the first worker startup config was:

- subtype: integration test
- `filter=match-nothing^$`
- `reportSuiteInfo=true`
- `defaultRetryCount=1`

That proves the worker is not starting from a passive or idle startup state.

### Finding 2: The First Cycle Is A Fake Report-Only Run

The first execution filter resolution in baseline logs showed:

- `matching_tests=0`
- `allow_count=0`

This is the fake report-only startup cycle.

### Finding 3: Baseline Long Run Can Restart After Real Test Start

In the long US baseline, the manager log showed:

- real route entry at `START Property list ready`
- then another `hotRestart start`
- then a fresh worker config fetch and a second real run

This is the strongest proof that the startup choreography can overlap a real long-running test.

## A1: Passive Default Controller

### Change

Start the manager store in a passive/halt controller instead of active integration-test mode.

### Result

This did **not** solve the problem.

What happened:

- the first cycle became an inert halt-style startup snapshot
- but the later startup `reloadInfo()` path still created a fake active `match-nothing` report-only run
- then the final real test run still followed

### Conclusion

Passive default startup alone is not enough.

It reduces one symptom but does not remove the extra startup sequencing problem.

## B: Skip `reloadInfo()` During Headless Startup

### Change

Keep the active default integration-test startup behavior unchanged, but remove the headless startup `reloadInfo()` phase so startup performs only one effective restart into the real test run.

### Short-Control Result

Repeated `hello` runs under `B` showed:

- still an initial fake `match-nothing` report-only cycle
- exactly one real `hotRestart`
- zero `hotRestart` events after test start

### Long-Control Result

Repeated bounded long US runs under `B` showed:

- exactly one `hotRestart`
- zero post-`START` restarts
- flow reaches real app state consistently
- later timeout remains in `addQuickReading`

### Conclusion

This is the decisive experiment result:

- the startup double-restart choreography is a proven cause of restart overlap
- removing the startup `reloadInfo()` restart removes that overlap
- remaining failures are downstream and should be debugged separately

## Repetition Proof

### Short Control Requirement

- target: 10 consecutive runs
- result under `B`: **10/10**

Observed in every run:

- first config = active `match-nothing`
- `hot_restarts=1`
- `post_start_restarts=0`

### Long Control Requirement

- target: 5 repeated runs
- result under `B`: **5/5 bounded runs**

Observed in every run:

- first config = active `match-nothing`
- `hot_restarts=1`
- `post_start_restarts=0`
- route reached `START Property list ready`
- terminal failure remained later in readings step

## Interpretation

### Proven

- Manager startup sequencing is a real cause of post-`START` restart overlap.
- The headless startup `reloadInfo()` phase is the highest-value place to intervene.

### Not Proven

- That manager startup sequencing is the only cause of long-flow failures.

### Still Open

- Why `addQuickReading` later times out even after startup restart overlap is removed.
- Whether the Flutter `runningAsyncTasks` patch would reduce residual instability after the manager fix is in place.

## Recommended Path

Create a **small manager-only fork now**, and use that to prepare an upstream PR.

This is the recommended order:

1. Fork `fzyzcjy/flutter_convenient_test`
2. Patch only `packages/convenient_test_manager_dart`
3. Keep app-side `convenient_test` dependencies unchanged
4. Point the local CLI manager activation to the fork at a pinned commit
5. Open an upstream issue with the proof
6. Open a focused PR with the smallest headless-only fix

## Why This Is Better Than Other Options

### Better Than Switching To Beta

- No evidence was found that beta is the recommended or correct fix path.
- Upstream CI is centered on stable.

### Better Than Patching Flutter First

- The manager overlap is now directly proven.
- Flutter patching should remain a second-cycle step only if needed.

### Better Than Replacing convenient_test

- `convenient_test` still gives the speed and desktop workflow you want.
- The failure mode is narrow enough that a manager-side fix is realistic.

## Should You Create A New Project?

Short answer: **no new project is needed**.

If by “project” you mean a new repository, a new GitHub project board, or a separate app-level effort, that is unnecessary right now.

Recommended setup:

- keep this app repo as-is
- do the manager work in your already cloned fork under `$HOME/Development`
- create one focused branch in the fork for the manager fix

That is enough isolation.

### Recommended Working Model

- App repo: unchanged except for runner configuration later if you choose to point to the forked manager
- Fork clone: actual implementation work
- Branch name example:
  - `fix/headless-startup-restart-overlap`

Only create a separate GitHub project board if the work later expands into:

- multiple manager fixes
- upstream coordination over time
- Flutter patch experiments
- release tracking across several repos

For the current scope, a branch plus an upstream issue is enough.

## Suggested Fork Workflow

## 1. Work In The Fork Clone

Example:

```zsh
cd ~/Development/flutter_convenient_test
git checkout -b fix/headless-startup-restart-overlap
```

## 2. Patch Only The Manager Package

Target:

- `packages/convenient_test_manager_dart`

Preferred patch shape:

- headless-only
- explicit and narrow
- upstream-viable

Avoid:

- unrelated cleanup
- broad control-flow rewrites
- changes to app packages unless necessary

## 3. Validate Against The Same Controls

Use:

- short control: `hello_convenient_test`
- long control: `us_property_meter_flow_convenient_test`

Validation goals:

- no post-`START` restart in long runs
- no regression in short runs

## 4. Use The Forked Manager Locally

Preferred operational model:

- keep repo dependencies unchanged
- activate only the CLI manager from the fork

That keeps the blast radius small.

Example activation flow once the fork patch exists:

```zsh
cd ~/Development/flutter_convenient_test
git checkout fix/headless-startup-restart-overlap

dart pub global activate \
  --source git \
  https://github.com/<your-user>/flutter_convenient_test.git \
  --git-ref <pinned-commit-or-branch> \
  --git-path packages/convenient_test_manager_dart
```

## Suggested Upstream Issue

### Title

`Headless manager startup can trigger a second hot restart after real test start`

### What To Include

- environment:
  - Flutter stable
  - macOS
  - headless `convenient_test_manager_dart`
- baseline proof:
  - first config is active `match-nothing`
  - first cycle is fake report-only
  - long run shows `hotRestart` after `START Property list ready`
- fix proof:
  - skipping startup `reloadInfo()` removes post-`START` restart overlap in repeated runs
- note:
  - downstream failures may remain, but the restart overlap is independently proven

## Suggested Upstream PR

### Title

`Avoid extra headless startup restart that can overlap long-running tests`

### PR Goal

Remove or dedupe the headless startup `reloadInfo()` restart so a real test run cannot later receive a queued startup restart.

### Scope

- manager only
- headless startup only
- no Flutter SDK changes

### Non-Goals

- solving all long-flow failures
- changing GUI manager behavior
- addressing unrelated reading-step timeouts

## Good Patch Shape

Preferred approaches:

1. Skip startup `reloadInfo()` in headless mode
2. Dedupe queued startup restarts so `reloadInfo()` cannot leave a trailing restart once the real test run has been scheduled

Less preferred:

- changing the entire default controller model globally
- mutating semantics for non-headless flows without proof

## Known Remaining Issue After Manager Fix

Even when the restart overlap is removed, the long US flow can still fail later in:

- `UsPropertyFlowRobot.addQuickReading`

This must be treated as a separate issue.

Recommended sequencing:

1. land or locally adopt the manager fix
2. re-run controls
3. debug the readings timeout separately

## Local Evidence Locations

Representative proof artifacts from the investigation:

- `/tmp/ct-proof-logs/baseline-hello-clean-20260420-163418/`
- `/tmp/ct-proof-logs/baseline-us-clean-20260420-163517/`
- `/tmp/ct-proof-logs/a1-halt-hello-20260420-163816/`
- `/tmp/ct-proof-logs/b-skip-reload-hello-20260420-163935/`
- `/tmp/ct-proof-logs/b-skip-reload-us-20260420-164023/`
- `/tmp/ct-proof-logs/b-bounded-us-1-20260420-165253/`
- `/tmp/ct-proof-logs/b-bounded-us-2-20260420-165401/`
- `/tmp/ct-proof-logs/b-bounded-us-3-20260420-165504/`
- `/tmp/ct-proof-logs/b-bounded-us-4-20260420-165608/`
- `/tmp/ct-proof-logs/b-bounded-us-5-20260420-165712/`

These are temporary local artifacts and not intended as permanent repo assets.

## Final Recommendation

Do **not** create a new project for this.

Do this instead:

1. work in your fork under `$HOME/Development`
2. make a small manager-only branch
3. validate with the same short and long controls
4. open an upstream issue
5. open a focused PR

That is the cleanest way to improve `convenient_test` while preserving the speed and desktop workflow that made it attractive in the first place.
