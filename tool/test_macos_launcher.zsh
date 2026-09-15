#!/bin/zsh

set -euo pipefail

readonly SCRIPT_DIR="${0:A:h}"
readonly PROGRAM_NAME="${0:t}"
readonly REPO_ROOT="${SCRIPT_DIR:h}"
readonly FIXTURE_SOURCE="$REPO_ROOT/tool/launcher_fixture"
readonly MANAGER_ROOT="$REPO_ROOT/packages/convenient_test_manager"

RUN_MACOS=1
RUN_IOS=1
IOS_UDID="${IOS_SIMULATOR_UDID:-}"
KEEP_WORK_ROOT=0

usage() {
  print -r -- "Usage: $PROGRAM_NAME [--macos-only|--ios-only] [--ios-udid UDID] [--keep-work-root]"
}

while (( $# > 0 )); do
  case "$1" in
    --macos-only)
      RUN_MACOS=1
      RUN_IOS=0
      ;;
    --ios-only)
      RUN_MACOS=0
      RUN_IOS=1
      ;;
    --ios-udid)
      (( $# >= 2 )) || { usage >&2; exit 64; }
      IOS_UDID="$2"
      shift
      ;;
    --keep-work-root)
      KEEP_WORK_ROOT=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 64
      ;;
  esac
  shift
done

if (( ! RUN_MACOS && ! RUN_IOS )); then
  print -u2 -- 'At least one native platform must be selected.'
  exit 64
fi

if (( RUN_IOS )) && [[ -z "$IOS_UDID" ]]; then
  print -u2 -- 'Pass --ios-udid UDID or set IOS_SIMULATOR_UDID; list available IDs with xcrun simctl list devices available.'
  exit 64
fi

if [[ "$(uname -s)" != Darwin ]]; then
  print -u2 -- 'This native launcher proof requires macOS.'
  exit 69
fi

FLUTTER_EXECUTABLE="${FLUTTER_EXECUTABLE:-$(command -v flutter || true)}"
if [[ -z "$FLUTTER_EXECUTABLE" || ! -x "$FLUTTER_EXECUTABLE" ]]; then
  print -u2 -- 'Set FLUTTER_EXECUTABLE to an executable Flutter SDK binary.'
  exit 69
fi
FLUTTER_EXECUTABLE="${FLUTTER_EXECUTABLE:A}"

readonly RUN_STAMP="$(date -u +%Y%m%dT%H%M%SZ)-$$"
readonly TEMP_BASE="${TMPDIR:-/tmp}"
WORK_ROOT="$(mktemp -d "$TEMP_BASE/convenient-launcher-native.XXXXXX")"
readonly WORK_ROOT
readonly WORKSPACE_ROOT="$WORK_ROOT/workspace"
readonly FIXTURE_ROOT="$WORKSPACE_ROOT/tool/launcher_fixture"
readonly DEFAULT_EVIDENCE_DIR="$TEMP_BASE/convenient-launcher-native-evidence-$RUN_STAMP"
EVIDENCE_DIR="${EVIDENCE_DIR:-$DEFAULT_EVIDENCE_DIR}"
mkdir -p "$EVIDENCE_DIR"
EVIDENCE_DIR="${EVIDENCE_DIR:A}"
EVIDENCE_FILE="${EVIDENCE_FILE:-$EVIDENCE_DIR/native-evidence.md}"
if [[ -e "$EVIDENCE_FILE" ]]; then
  print -u2 -- "Refusing to overwrite existing evidence: $EVIDENCE_FILE"
  exit 73
fi

readonly ORG_ID="dev.codex.launcherproof.r${RUN_STAMP//[^A-Za-z0-9]/}"
readonly BUNDLE_ID="$ORG_ID.launcherFixture"
readonly CLEANUP_LOG="$EVIDENCE_DIR/cleanup.log"
BOOTED_IOS_BY_RUNNER=0
CLEANED=0

cleanup_owned_resources() {
  (( CLEANED )) && return 0
  CLEANED=1
  set +e
  if (( RUN_IOS )); then
    /usr/bin/xcrun simctl terminate "$IOS_UDID" "$BUNDLE_ID" >>"$CLEANUP_LOG" 2>&1
    /usr/bin/xcrun simctl uninstall "$IOS_UDID" "$BUNDLE_ID" >>"$CLEANUP_LOG" 2>&1
    if (( BOOTED_IOS_BY_RUNNER )); then
      /usr/bin/xcrun simctl shutdown "$IOS_UDID" >>"$CLEANUP_LOG" 2>&1
    fi
  fi
  if (( ! KEEP_WORK_ROOT )); then
    case "$WORK_ROOT" in
      "$TEMP_BASE"/convenient-launcher-native.*)
        /bin/rm -rf -- "$WORK_ROOT"
        ;;
      *)
        print -u2 -- "Refusing to remove unexpected work root: $WORK_ROOT"
        ;;
    esac
  fi
  set -e
}
trap cleanup_owned_resources EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

print -r -- "Preparing disposable fixture at $FIXTURE_ROOT"
mkdir -p "$FIXTURE_ROOT" "$WORKSPACE_ROOT/tool"
ln -s "$REPO_ROOT/packages" "$WORKSPACE_ROOT/packages"
(
  cd "$FIXTURE_ROOT"
  "$FLUTTER_EXECUTABLE" create \
    --no-pub \
    --platforms=ios,macos \
    --project-name=launcher_fixture \
    --org="$ORG_ID" \
    .
)
cp "$FIXTURE_SOURCE/pubspec.yaml" "$FIXTURE_ROOT/pubspec.yaml"
mkdir -p "$FIXTURE_ROOT/lib" "$FIXTURE_ROOT/integration_test"
cp "$FIXTURE_SOURCE/lib/main.dart" "$FIXTURE_ROOT/lib/main.dart"
cp "$FIXTURE_SOURCE/integration_test/launcher_smoke_test.dart" \
  "$FIXTURE_ROOT/integration_test/launcher_smoke_test.dart"
for entitlement_file in \
  "$FIXTURE_ROOT/macos/Runner/DebugProfile.entitlements" \
  "$FIXTURE_ROOT/macos/Runner/Release.entitlements"; do
  /usr/libexec/PlistBuddy \
    -c 'Add :com.apple.security.network.client bool true' \
    "$entitlement_file" 2>/dev/null || \
    /usr/libexec/PlistBuddy \
      -c 'Set :com.apple.security.network.client true' \
      "$entitlement_file"
done
(
  cd "$FIXTURE_ROOT"
  "$FLUTTER_EXECUTABLE" pub get
)

IOS_INITIAL_STATE='not-run'
if (( RUN_IOS )); then
  IOS_DEVICE_LINE="$(/usr/bin/xcrun simctl list devices | /usr/bin/grep -F "$IOS_UDID" | head -1 || true)"
  if [[ -z "$IOS_DEVICE_LINE" ]]; then
    print -u2 -- "Simulator not found: $IOS_UDID"
    exit 69
  fi
  if [[ "$IOS_DEVICE_LINE" == *'(Booted)'* ]]; then
    IOS_INITIAL_STATE='Booted'
  elif [[ "$IOS_DEVICE_LINE" == *'(Shutdown)'* ]]; then
    IOS_INITIAL_STATE='Shutdown'
    print -r -- "Booting task-selected simulator $IOS_UDID"
    /usr/bin/xcrun simctl boot "$IOS_UDID"
    BOOTED_IOS_BY_RUNNER=1
    /usr/bin/xcrun simctl bootstatus "$IOS_UDID" -b
  else
    print -u2 -- "Unsupported simulator state: $IOS_DEVICE_LINE"
    exit 69
  fi
fi

typeset -a RESULT_JSONS SESSION_IDS REPORT_PATHS

run_probe() {
  local platform="$1"
  local device_id="$2"
  local log_file="$EVIDENCE_DIR/$platform-probe.log"
  local report_root="$EVIDENCE_DIR/$platform-reports"
  mkdir -p "$report_root"

  print -r -- "Running real $platform launcher smoke on $device_id"
  set +e
  (
    cd "$MANAGER_ROOT"
    "$FLUTTER_EXECUTABLE" test \
      test/launcher/native_platform_probe.dart \
      --reporter=expanded \
      --dart-define="LAUNCHER_NATIVE_PLATFORM=$platform" \
      --dart-define="LAUNCHER_NATIVE_DEVICE_ID=$device_id" \
      --dart-define="LAUNCHER_NATIVE_FIXTURE_ROOT=$FIXTURE_ROOT" \
      --dart-define="LAUNCHER_NATIVE_FLUTTER=$FLUTTER_EXECUTABLE" \
      --dart-define="LAUNCHER_NATIVE_REPORT_ROOT=$report_root"
  ) 2>&1 | tee "$log_file"
  local probe_status=${pipestatus[1]}
  set -e
  if (( probe_status != 0 )); then
    print -u2 -- "$platform probe failed with exit $probe_status; log: $log_file"
    return "$probe_status"
  fi

  local result_line="$(/usr/bin/grep 'NATIVE_RESULT_JSON=' "$log_file" | tail -1 || true)"
  if [[ -z "$result_line" ]]; then
    print -u2 -- "$platform probe did not emit its structured result."
    return 1
  fi
  local result_json="${result_line#*NATIVE_RESULT_JSON=}"
  local session_tail="${result_json#*\"sessionId\":\"}"
  local report_tail="${result_json#*\"reportPath\":\"}"
  if [[ "$session_tail" == "$result_json" || "$report_tail" == "$result_json" ]]; then
    print -u2 -- "$platform result is missing session/report identity."
    return 1
  fi
  RESULT_JSONS+=("$result_json")
  SESSION_IDS+=("${session_tail%%\"*}")
  REPORT_PATHS+=("${report_tail%%\"*}")
}

if (( RUN_MACOS )); then
  run_probe macos macos
fi
if (( RUN_IOS )); then
  run_probe ios "$IOS_UDID"
fi

if (( ${#SESSION_IDS} == 2 )); then
  if [[ "$SESSION_IDS[1]" == "$SESSION_IDS[2]" ]]; then
    print -u2 -- "Native runs reused session identity: $SESSION_IDS[1]"
    exit 1
  fi
  if [[ "$REPORT_PATHS[1]" == "$REPORT_PATHS[2]" ]]; then
    print -u2 -- "Native runs reused report path: $REPORT_PATHS[1]"
    exit 1
  fi
fi

cleanup_owned_resources
trap - EXIT INT TERM HUP

{
  print -r -- '# Native launcher evidence'
  print -r -- ''
  print -r -- "- UTC run stamp: \`$RUN_STAMP\`"
  print -r -- "- Repository: \`$REPO_ROOT\`"
  print -r -- "- Flutter executable: \`$FLUTTER_EXECUTABLE\`"
  print -r -- "- Disposable fixture root: \`$FIXTURE_ROOT\` (removed after the run)"
  print -r -- "- Task-unique app identity: \`$BUNDLE_ID\`"
  if (( RUN_IOS )); then
    print -r -- "- iOS simulator: \`$IOS_UDID\` (initial state: $IOS_INITIAL_STATE; booted by runner: $BOOTED_IOS_BY_RUNNER)"
  fi
  print -r -- ''
  print -r -- '## Commands'
  print -r -- ''
  print -r -- "- \`flutter create --no-pub --platforms=ios,macos --project-name=launcher_fixture --org=$ORG_ID .\`"
  print -r -- '- `flutter pub get`'
  print -r -- '- `flutter test test/launcher/native_platform_probe.dart --reporter=expanded --dart-define=...` once per selected platform'
  print -r -- ''
  print -r -- '## Results'
  print -r -- ''
  local_result=''
  for local_result in "${RESULT_JSONS[@]}"; do
    print -r -- "- \`$local_result\`"
  done
  print -r -- ''
  print -r -- 'Each result is derived from the live manager `SuiteInfoStore` using the same state buckets as manager `_calcExitCode`; `equivalentExitCode:0` requires no pending, running, failure, or error test and at least one completed success. Each result also proves a non-empty manager-saved report, an authenticated loopback worker URI, a dynamic non-legacy manager port, and post-Stop release of the manager listener and owned process group.'
  print -r -- ''
  print -r -- '## Resource cleanup and limits'
  print -r -- ''
  print -r -- "- Cleanup log: \`$CLEANUP_LOG\`"
  print -r -- '- The runner removes only its `mktemp` fixture/build root and its task-unique simulator app. It shuts down only the named simulator when this run booted it. It never erases simulator data and never uses broad process termination.'
  print -r -- '- Finder device discovery and macOS privacy/TCC behavior were not exercised or changed. This is terminal-native execution through the production launcher controller.'
  print -r -- '- Legacy ports 3579 and 9753 are explicitly rejected by the probe.'
} >"$EVIDENCE_FILE"

print -r -- "PASS: native launcher evidence written to $EVIDENCE_FILE"
