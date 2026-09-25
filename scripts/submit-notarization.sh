#!/bin/zsh
# Submits a file (a zip of Cida.app, or the DMG) to Apple's notary service and waits for the
# verdict. It exits non-zero, after printing the service's log, unless the submission is
# Accepted. Stapling is left to the caller.
#
#   scripts/submit-notarization.sh <zip or dmg>
#
# Credentials come from an App Store Connect API key when CIDA_NOTARY_KEY (path to the .p8),
# CIDA_NOTARY_KEY_ID and CIDA_NOTARY_ISSUER are set, as in CI. Otherwise they come from a
# notarytool keychain profile, cida-notary unless CIDA_NOTARY_PROFILE names another. Create it
# once with:
#
#   xcrun notarytool store-credentials cida-notary --apple-id <id> --team-id 3GMS63N4BQ
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <zip or dmg>" >&2
  exit 64
fi
file_path=${1:A}
if [[ ! -f "$file_path" ]]; then
  echo "Nothing to notarize at $file_path" >&2
  exit 66
fi

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

echo "Submitting ${file_path:t} to the notary service ($credentials_source)…"
submission=$(
  /usr/bin/xcrun notarytool submit "$file_path" \
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
echo "Notarization $submission_id accepted: ${file_path:t}"
