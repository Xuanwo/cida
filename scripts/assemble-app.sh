#!/bin/zsh
# Lays out Cida.app from a built Cida executable: the executable, its resource bundle and
# Sparkle.framework (found next to it in the SwiftPM build directory, or in the app it came
# from), Resources/Cida-Info.plist and the compiled app icon. Identity, version and signing
# are left to the caller (scripts/sign-app.sh signs).
#
#   scripts/assemble-app.sh <Cida executable> <new app path>
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <Cida executable> <new app path>" >&2
  exit 64
fi

script_dir=${0:A:h}
project_dir=${script_dir:h}
binary_path=${1:A}
app_path=${2:A}

if [[ ! -x "$binary_path" ]]; then
  echo "Cida executable is missing: $binary_path" >&2
  exit 66
fi
if [[ -e "$app_path" ]]; then
  echo "Refusing to replace an existing app: $app_path" >&2
  exit 73
fi

# A SwiftPM build keeps its products next to the executable; an app keeps them in Contents.
binary_dir=${binary_path:h}
locate() {
  local name=$1 contents_dir=$2
  if [[ -e "$binary_dir/$name" ]]; then
    print -r -- "$binary_dir/$name"
  elif [[ -e "${binary_dir:h}/$contents_dir/$name" ]]; then
    print -r -- "${binary_dir:h}/$contents_dir/$name"
  else
    echo "$name is missing next to $binary_path" >&2
    return 66
  fi
}
resource_bundle=$(locate Cida_Cida.bundle Resources)
sparkle_framework=$(locate Sparkle.framework Frameworks)

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources" "$app_path/Contents/Frameworks"
/usr/bin/install -m 755 "$binary_path" "$app_path/Contents/MacOS/Cida"
/usr/bin/ditto "$resource_bundle" "$app_path/Contents/Resources/Cida_Cida.bundle"
/usr/bin/ditto "$sparkle_framework" "$app_path/Contents/Frameworks/Sparkle.framework"
# Sparkle's XPC services are only for sandboxed apps; Cida is not sandboxed.
/bin/rm -rf "$app_path/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices" \
  "$app_path/Contents/Frameworks/Sparkle.framework/XPCServices"
/usr/bin/install -m 644 "$project_dir/Resources/Cida-Info.plist" "$app_path/Contents/Info.plist"
"$script_dir/compile-app-icon.sh" "$app_path/Contents/Resources"
