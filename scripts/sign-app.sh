#!/bin/zsh
# Signs Cida.app inside out, as Sparkle requires: Sparkle's helper tools, the framework, then
# the app. A Developer ID signature gets the hardened runtime; an ad hoc one (identity -) for
# local automation does not, because the runtime's library validation rejects ad hoc
# frameworks. Extra arguments go to every codesign call, such as --timestamp=none.
#
#   scripts/sign-app.sh <app> <identity or -> [codesign arguments...]
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <app> <identity or -> [codesign arguments...]" >&2
  exit 64
fi

app_path=${1:A}
identity=$2
shift 2
runtime=(--options runtime)
[[ "$identity" == - ]] && runtime=()
sign() {
  /usr/bin/codesign --force --sign "$identity" "${runtime[@]}" "$@"
}

sparkle="$app_path/Contents/Frameworks/Sparkle.framework"
sign "$@" "$sparkle/Versions/B/Autoupdate"
sign "$@" "$sparkle/Versions/B/Updater.app"
sign "$@" "$sparkle"
sign "$@" "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
