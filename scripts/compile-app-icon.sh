#!/bin/zsh
# Compiles Resources/AppIcon.icon into an app bundle's Contents/Resources: Assets.car for
# macOS 26 and later, AppIcon.icns for macOS 15. Resources/Cida-Info.plist names both.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <app>/Contents/Resources" >&2
  exit 64
fi

script_dir=${0:A:h}
project_dir=${script_dir:h}
resources_dir=$1
partial_plist=$(mktemp "${TMPDIR:-/tmp}/cida-app-icon.XXXXXX")
trap '/bin/rm -f "$partial_plist"' EXIT

if ! report=$(/usr/bin/xcrun actool "$project_dir/Resources/AppIcon.icon" \
  --compile "$resources_dir" \
  --platform macosx \
  --minimum-deployment-target 15.0 \
  --app-icon AppIcon \
  --output-partial-info-plist "$partial_plist" \
  --errors --warnings \
  --output-format human-readable-text); then
  echo "$report" >&2
  exit 70
fi
if [[ "$report" == *": warning:"* || "$report" == *": error:"* ]]; then
  echo "$report" >&2
fi

for compiled in Assets.car AppIcon.icns; do
  if [[ ! -s "$resources_dir/$compiled" ]]; then
    echo "actool did not produce $compiled" >&2
    exit 70
  fi
done
