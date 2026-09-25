#!/bin/zsh
# Packs a notarized Cida.app (scripts/notarize-app.sh) into the DMG that new users install
# from (Design/spec/lifecycle.md §二), then signs, notarizes and staples the DMG.
#
#   scripts/build-dmg.sh <notarized Cida.app> <output .dmg>
#
# The volume 辞达 opens as a 600 × 400 Finder window without toolbar, sidebar or status bar:
# the paper background Design/rendered/states/dmg-background.png, Cida.app at (150, 210) and a
# link to /Applications named 应用程序 at (450, 210), both at 128 pt. dmgbuild, pinned below
# and installed into a virtual environment under build/, writes that layout into the volume's
# .DS_Store directly, so no Finder window is scripted and CI can run it.
#
# The DMG is signed with CIDA_CODESIGN_IDENTITY, or else the Developer ID identity that signed
# the app. scripts/submit-notarization.sh notarizes it with the same credentials as the app.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <notarized Cida.app> <output .dmg>" >&2
  exit 64
fi

script_dir=${0:A:h}
project_dir=${script_dir:h}
app_path=${1:A}
dmg_path=${2:A}
background="$project_dir/Design/rendered/states/dmg-background.png"

dmgbuild_version=1.6.7
dmgbuild_requirements=(
  "dmgbuild==$dmgbuild_version --hash=sha256:37ee5771c377beb3203d9164aae8046ffed8531c06edf9227f5788b3c599b1bf"
  "ds_store==1.3.3 --hash=sha256:b92a371efbf1b4ccce2a04d1ed13fceacc4736c81ba09cf5aefb74c088160a35"
  "mac_alias==2.2.3 --hash=sha256:7362b521d2132ef92f606a37abfed5fcd849ceb2f28b6f9743e014b02af92f0d"
)
dmgbuild_env=${CIDA_DMGBUILD_ENV:-"$project_dir/build/dmgbuild-$dmgbuild_version"}

if [[ "${dmg_path:e}" != dmg ]]; then
  echo "The output must end in .dmg, got $dmg_path" >&2
  exit 64
fi
if [[ ! -d "$app_path" ]]; then
  echo "No app at $app_path" >&2
  exit 66
fi
# Only a stapled app belongs in the DMG: the ticket lets Gatekeeper accept it offline.
if ! /usr/bin/xcrun stapler validate -q "$app_path"; then
  echo "$app_path carries no notarization ticket; run scripts/notarize-app.sh first" >&2
  exit 65
fi

identity=${CIDA_CODESIGN_IDENTITY:-}
if [[ -z "$identity" ]]; then
  identity=$(
    /usr/bin/codesign -dv --verbose=2 "$app_path" 2>&1 \
      | /usr/bin/sed -n 's/^Authority=\(Developer ID Application:.*\)$/\1/p' \
      | /usr/bin/head -1
  )
fi
if [[ -z "$identity" ]]; then
  echo "$app_path is not signed with a Developer ID Application identity" >&2
  exit 65
fi

# Finder shows a 600 × 400 pt window; the background is rendered at 2x, so it becomes a TIFF
# holding a 1x and a 2x representation and Finder picks the one that matches the display.
background_size=$(
  /usr/bin/sips -g pixelWidth -g pixelHeight "$background" \
    | /usr/bin/awk '/pixel/ {print $2}' | /usr/bin/paste -sd x -
)
if [[ "$background_size" != 1200x800 ]]; then
  echo "$background must be 1200 × 800 pixels, got $background_size" >&2
  exit 65
fi

if ! "$dmgbuild_env/bin/python" -c 'import dmgbuild' 2>/dev/null; then
  python=${CIDA_PYTHON:-python3}
  if ! "$python" -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
    echo "dmgbuild $dmgbuild_version needs Python 3.10 or newer; set CIDA_PYTHON to one" >&2
    exit 69
  fi
  /bin/rm -rf "$dmgbuild_env"
  "$python" -m venv "$dmgbuild_env"
  print -rl -- "${dmgbuild_requirements[@]}" >"$dmgbuild_env/requirements.txt"
  "$dmgbuild_env/bin/pip" install --quiet --disable-pip-version-check --require-hashes \
    --only-binary :all: --no-deps -r "$dmgbuild_env/requirements.txt"
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/cida-dmg.XXXXXX")
trap '/bin/rm -rf "$work_dir"' EXIT

/usr/bin/sips --resampleHeightWidth 400 600 --setProperty dpiWidth 72 --setProperty dpiHeight 72 \
  "$background" --out "$work_dir/background.png" >/dev/null
/usr/bin/sips --setProperty dpiWidth 144 --setProperty dpiHeight 144 \
  "$background" --out "$work_dir/background@2x.png" >/dev/null
/usr/bin/tiffutil -cathidpicheck "$work_dir/background.png" "$work_dir/background@2x.png" \
  -out "$work_dir/background.tiff"

"$dmgbuild_env/bin/python" - "$app_path" "$work_dir/background.tiff" "$work_dir/Cida.dmg" <<'PYTHON'
import os.path
import subprocess
import sys

import dmgbuild.core

app, background, output = sys.argv[1:]
app_name = os.path.basename(app)
applications = "应用程序"

# dmgbuild compresses the finished image with `hdiutil convert`, which hdiutil deprecates in
# favour of `diskutil image create from` and which fails with EAGAIN on macOS 27. The same
# conversion goes through diskutil instead; every other hdiutil call stays dmgbuild's.
hdiutil = dmgbuild.core.hdiutil


def convert_with_diskutil(command, *arguments, **options):
    if command != "convert":
        return hdiutil(command, *arguments, **options)
    source = arguments[0]
    image_format = arguments[arguments.index("-format") + 1]
    destination = arguments[arguments.index("-o") + 1]
    result = subprocess.run(
        ["/usr/sbin/diskutil", "image", "create", "from", "--format", image_format, source, destination],
        capture_output=True,
        text=True,
    )
    return result.returncode, result.stdout + result.stderr


dmgbuild.core.hdiutil = convert_with_diskutil

dmgbuild.core.build_dmg(
    output,
    "辞达",
    settings={
        "format": "ULFO",
        "filesystem": "HFS+",
        "files": [app],
        "symlinks": {applications: "/Applications"},
        "hide_extensions": [app_name],
        "icon": os.path.join(app, "Contents/Resources/AppIcon.icns"),
        "background": background,
        # Finder takes this as the whole window: 400 pt of background plus a 30 pt title bar
        # (measured on macOS 26; the tallest title bar Finder draws).
        "window_rect": ((200, 120), (600, 430)),
        "default_view": "icon-view",
        "show_toolbar": False,
        "show_sidebar": False,
        "show_status_bar": False,
        "show_pathbar": False,
        "show_tab_view": False,
        "icon_size": 128,
        "text_size": 12,
        "icon_locations": {app_name: (150, 210), applications: (450, 210)},
    },
    lookForHiDPI=False,
)
PYTHON

/usr/bin/codesign --force --sign "$identity" --timestamp "$work_dir/Cida.dmg"
/usr/bin/codesign --verify --strict "$work_dir/Cida.dmg"
"$script_dir/submit-notarization.sh" "$work_dir/Cida.dmg"
/usr/bin/xcrun stapler staple "$work_dir/Cida.dmg"
/usr/bin/xcrun stapler validate "$work_dir/Cida.dmg"
assessment=$(/usr/sbin/spctl --assess --type open --context context:primary-signature -vv "$work_dir/Cida.dmg" 2>&1)
if [[ "$assessment" != *"source=Notarized Developer ID"* ]]; then
  echo "Gatekeeper does not accept the stapled DMG:" >&2
  echo "$assessment" >&2
  exit 70
fi

mkdir -p "${dmg_path:h}"
/bin/mv -f "$work_dir/Cida.dmg" "$dmg_path"
echo "$dmg_path"
