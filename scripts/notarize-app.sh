#!/bin/zsh
# Notarizes and staples a Developer ID signed Cida.app (scripts/build-app.sh), then writes the
# zip to distribute next to it: build/Cida-<version>-<build>.zip by default.
#
#   scripts/notarize-app.sh [path/to/Cida.app]
#
# Credentials come from an App Store Connect API key when CIDA_NOTARY_KEY (path to the .p8),
# CIDA_NOTARY_KEY_ID and CIDA_NOTARY_ISSUER are set, as in CI. Otherwise they come from a
# notarytool keychain profile, cida-notary unless CIDA_NOTARY_PROFILE names another. Create it
# once with:
#
#   xcrun notarytool store-credentials cida-notary --apple-id <id> --team-id 3GMS63N4BQ
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
app_path=${1:-"$project_dir/build/Cida.app"}
app_path=${app_path:A}
if [[ -n "${CIDA_NOTARY_KEY:-}" ]]; then
  if [[ -z "${CIDA_NOTARY_KEY_ID:-}" || -z "${CIDA_NOTARY_ISSUER:-}" ]]; then
    echo "CIDA_NOTARY_KEY needs CIDA_NOTARY_KEY_ID and CIDA_NOTARY_ISSUER" >&2
    exit 64
  fi
  credentials=(--key "$CIDA_NOTARY_KEY" --key-id "$CIDA_NOTARY_KEY_ID" --issuer "$CIDA_NOTARY_ISSUER")
  credentials_source="API key $CIDA_NOTARY_KEY_ID"
else
  credentials=(--keychain-profile "${CIDA_NOTARY_PROFILE:-cida-notary}")
  credentials_source="profile ${CIDA_NOTARY_PROFILE:-cida-notary}"
fi

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

echo "Submitting ${app_path:t} to the notary service ($credentials_source)…"
submission=$(
  /usr/bin/xcrun notarytool submit "$submission_zip" \
    "${credentials[@]}" \
    --wait \
    --output-format json
)
submission_id=$(/usr/bin/plutil -extract id raw - <<<"$submission")
submission_status=$(/usr/bin/plutil -extract status raw - <<<"$submission")
if [[ "$submission_status" != "Accepted" ]]; then
  echo "Notarization $submission_id ended as $submission_status:" >&2
  /usr/bin/xcrun notarytool log "$submission_id" "${credentials[@]}" >&2 || true
  exit 70
fi

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

echo "Notarized ($submission_id) and stapled: $app_path"
echo "$archive_path"
