#!/bin/zsh
# Build and package the GUI manager for Apple Silicon. No Git operations.
set -euo pipefail

repo_dir=${0:A:h:h}
manager_dir="$repo_dir/packages/convenient_test_manager"
release_app="$manager_dir/build/macos/Build/Products/Release/convenient_test_manager.app"
packaged_app="$manager_dir/build/apple-silicon/Convenient Test Manager.app"
operation=${1:-build}
destination=${2:-/Applications/Convenient Test Manager.app}

usage() {
  cat <<'EOF'
Usage: tool/macos_manager.zsh [build|install|verify] [app-path]
  build    Build release, remove Intel slices, sign and verify (default).
  install  Build and install; optional destination defaults to /Applications.
           Quit the installed manager first. Keeps a timestamped backup.
  verify   Verify an existing app (defaults to the installed app).

Run from any directory. Requires native Apple Silicon macOS, Flutter on PATH,
Xcode command-line tools, Python 3, and CocoaPods if required by the project.
Build uses this checkout, including uncommitted changes, and Flutter on PATH.
Flutter may migrate project configuration for the selected SDK.
EOF
}

case "$operation" in
  -h|--help) usage; exit 0 ;;
  build|install|verify) ;;
  *) usage >&2; exit 2 ;;
esac
(( $# <= 2 )) || { usage >&2; exit 2; }
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || {
  print -u2 'Run from a native Apple Silicon macOS terminal.'; exit 1
}

# Follow framework symlinks once. Inspect every Mach-O, including native assets.
architectures() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve(strict=True)
thin = sys.argv[2] == 'thin'
seen = set()
count = 0
for entry in root.rglob('*'):
    if not entry.is_file():
        continue
    binary = entry.resolve(strict=True)
    if not binary.is_relative_to(root):
        raise SystemExit(f'Unexpected external symlink: {entry}')
    if binary in seen:
        continue
    seen.add(binary)
    kind = subprocess.check_output(['file', '-b', str(binary)], text=True)
    if 'Mach-O' not in kind:
        continue
    arches = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    if thin and 'arm64' in arches and len(arches) > 1:
        temporary = binary.with_name(binary.name + '.arm64-tmp')
        subprocess.run(['lipo', str(binary), '-thin', 'arm64', '-output', str(temporary)], check=True)
        temporary.chmod(binary.stat().st_mode)
        temporary.replace(binary)
        arches = subprocess.check_output(['lipo', '-archs', str(binary)], text=True).split()
    if arches != ['arm64']:
        raise SystemExit(f'Expected arm64 only: {entry}: {arches}')
    count += 1
    print(f'{entry.relative_to(root)}: arm64')
if not count:
    raise SystemExit('No Mach-O binaries found')
print(f'PASS: all {count} Mach-O binaries are arm64 only')
PY
}

verify_app() {
  architectures "$1" verify
  codesign --verify --deep --strict "$1"
}

if [[ "$operation" == verify ]]; then
  verify_app "$destination"
  exit 0
fi

if [[ "$operation" == install ]]; then
  [[ "$destination" == /* && "$destination" == *.app ]] || {
    print -u2 'Installation destination must be an absolute .app path.'; exit 2
  }
  if pgrep -x convenient_test_manager >/dev/null; then
    print -u2 'Quit Convenient Test Manager before installing.'; exit 1
  fi
fi

cd "$manager_dir"
flutter build macos --release
mkdir -p "${packaged_app:h}"
stage_dir=$(mktemp -d "${packaged_app:h}/package.XXXXXX")
trap 'rm -rf -- "$stage_dir"' EXIT
stage_app="$stage_dir/Convenient Test Manager.app"
ditto "$release_app" "$stage_app"
architectures "$stage_app" thin
codesign --force --deep --sign - --preserve-metadata=entitlements,identifier,flags "$stage_app"
verify_app "$stage_app"
# Replace the previous generated package, never source or the installed app.
if [[ -e "$packaged_app" ]]; then
  mv "$packaged_app" "$stage_dir/previous.app"
fi
mv "$stage_app" "$packaged_app"
print "Packaged: $packaged_app"

if [[ "$operation" == install ]]; then
  # Copy to a sibling staging directory before touching the current installation.
  install_stage=$(mktemp -d "${destination:h}/.convenient-manager.XXXXXX")
  trap 'rm -rf -- "$stage_dir" "$install_stage"' EXIT
  ditto "$packaged_app" "$install_stage/manager.app"
  verify_app "$install_stage/manager.app"
  if [[ -e "$destination" ]]; then
    backup="$destination.backup-$(date +%Y%m%d-%H%M%S)-$$"
    mv "$destination" "$backup"
    print "Previous installation: $backup"
  fi
  mv "$install_stage/manager.app" "$destination"
  verify_app "$destination"
  print "Installed: $destination"
fi
