#!/bin/sh
# Xcode Cloud: TestFlight は CFBundleVersion が一意必須。
# Git の CURRENT_PROJECT_VERSION はローカル用のままにし、Archive だけ CI_BUILD_NUMBER を載せる。
# このディレクトリは BlueTicker.xcodeproj と同じ階層（Apple が ci_scripts を探す場所）。
set -eu

action="${CI_XCODEBUILD_ACTION:-}"
case "$action" in
  archive|Archive) ;;
  *) exit 0 ;;
esac

if [ -z "${CI_BUILD_NUMBER:-}" ]; then
  echo "ci_pre_xcodebuild: CI_BUILD_NUMBER is empty" >&2
  exit 1
fi

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
pbxproj="$root/BlueTicker.xcodeproj/project.pbxproj"

python3 - "$pbxproj" "$CI_BUILD_NUMBER" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
build = sys.argv[2]
if not re.fullmatch(r"[0-9]+", build):
    sys.stderr.write(f"ci_pre_xcodebuild: invalid CI_BUILD_NUMBER {build!r}\n")
    sys.exit(1)

text = path.read_text()
updated, count = re.subn(
    r"CURRENT_PROJECT_VERSION = [0-9]+;",
    f"CURRENT_PROJECT_VERSION = {build};",
    text,
)
if count == 0:
    sys.stderr.write("ci_pre_xcodebuild: CURRENT_PROJECT_VERSION not found\n")
    sys.exit(1)
path.write_text(updated)
print(f"ci_pre_xcodebuild: CURRENT_PROJECT_VERSION -> {build} ({count} sites)")
PY
