#!/bin/zsh
# Notarizes and staples a Developer ID signed Cida.app (scripts/build-app.sh), then writes the
# zip to distribute next to it: build/Cida-<version>-<build>.zip by default.
#
#   scripts/notarize-app.sh [path/to/Cida.app]
#
# scripts/submit-notarization.sh does the submission and describes the credentials it reads:
# an App Store Connect API key in CI, the notarytool keychain profile cida-notary locally.
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
app_path=${1:-"$project_dir/build/Cida.app"}
app_path=${app_path:A}
if [[ ! -d "$app_path" ]]; then
  echo "No app at $app_path; build one with scripts/build-app.sh release" >&2
  exit 66
fi

# Apple accepts only Developer ID signatures with the hardened runtime and a secure timestamp.
/usr/bin/codesign --verify --deep --strict "$app_path"
signature=$(/usr/bin/codesign -dv --verbose=2 "$app_path" 2>&1)
if [[ "$signature" != *"Authority=Developer ID Application:"* ]]; then
  echo "$app_path is not signed with a Developer ID Application identity" >&2
  exit 65
fi
if [[ "$signature" != *"(runtime)"* || "$signature" != *"Timestamp="* ]]; then
  echo "$app_path lacks the hardened runtime or a secure timestamp" >&2
  exit 65
fi

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/cida-notarize.XXXXXX")
trap '/bin/rm -r "$work_dir"' EXIT
submission_zip="$work_dir/Cida.zip"
/usr/bin/ditto -c -k --keepParent "$app_path" "$submission_zip"

"$script_dir/submit-notarization.sh" "$submission_zip"

/usr/bin/xcrun stapler staple "$app_path"
/usr/bin/xcrun stapler validate "$app_path"
assessment=$(/usr/sbin/spctl --assess --type execute -vv "$app_path" 2>&1)
if [[ "$assessment" != *"source=Notarized Developer ID"* ]]; then
  echo "Gatekeeper does not accept the stapled app:" >&2
  echo "$assessment" >&2
  exit 70
fi

version=$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")
build=$(/usr/bin/plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")
archive_path="${app_path:h}/Cida-$version-$build.zip"
/bin/rm -f "$archive_path"
/usr/bin/ditto -c -k --keepParent "$app_path" "$archive_path"

echo "Notarized and stapled: $app_path"
echo "$archive_path"
