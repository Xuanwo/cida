#!/bin/zsh
# Imports the Developer ID Application identity for a CI release into a keychain of its own and
# prints the identity's SHA-1 for CIDA_CODESIGN_IDENTITY.
#
#   CIDA_DEVELOPER_ID_P12=<base64 of the exported .p12> \
#   CIDA_DEVELOPER_ID_P12_PASSWORD=<its export password> \
#   scripts/ci/import-signing-identity.sh <keychain path>
#
# The keychain is added to the user's search list so codesign finds it; delete it with
# `security delete-keychain <keychain path>` when the job ends.
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <keychain path>" >&2
  exit 64
fi
if [[ -z "${CIDA_DEVELOPER_ID_P12:-}" || -z "${CIDA_DEVELOPER_ID_P12_PASSWORD:-}" ]]; then
  echo "CIDA_DEVELOPER_ID_P12 and CIDA_DEVELOPER_ID_P12_PASSWORD are required" >&2
  exit 64
fi

keychain=$1
keychain_password=$(/usr/bin/openssl rand -base64 32)
p12=$(mktemp "${TMPDIR:-/tmp}/cida-developer-id.XXXXXX")
trap '/bin/rm -f "$p12"' EXIT
print -rn -- "$CIDA_DEVELOPER_ID_P12" | /usr/bin/base64 --decode >"$p12"

/usr/bin/security create-keychain -p "$keychain_password" "$keychain"
/usr/bin/security set-keychain-settings -lut 21600 "$keychain"
/usr/bin/security unlock-keychain -p "$keychain_password" "$keychain"
/usr/bin/security import "$p12" -k "$keychain" -f pkcs12 \
  -P "$CIDA_DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign >/dev/null
# The identity is valid only with its issuing CA; a fresh runner may not have it installed. A
# .p12 exported with its chain already carries the CA, which is fine.
for authority in DeveloperIDCA DeveloperIDG2CA; do
  /usr/bin/curl --fail --silent --show-error --retry 3 \
    "https://www.apple.com/certificateauthority/$authority.cer" -o "$p12.$authority.cer"
  if ! import_output=$(/usr/bin/security import "$p12.$authority.cer" -k "$keychain" 2>&1) \
    && [[ "$import_output" != *"already exists"* ]]; then
    echo "$import_output" >&2
    exit 1
  fi
  /bin/rm -f "$p12.$authority.cer"
done
# Let codesign use the private key without a UI prompt.
/usr/bin/security set-key-partition-list -S apple-tool:,apple: -s \
  -k "$keychain_password" "$keychain" >/dev/null

search_list=("${(@f)$(/usr/bin/security list-keychains -d user | /usr/bin/sed -e 's/^ *"//' -e 's/"$//')}")
/usr/bin/security list-keychains -d user -s "$keychain" "${search_list[@]}"

identity=$(
  /usr/bin/security find-identity -v -p codesigning "$keychain" \
    | /usr/bin/awk '/"Developer ID Application:/ { print $2; exit }'
)
if [[ -z "$identity" ]]; then
  echo "The .p12 holds no valid Developer ID Application identity" >&2
  /usr/bin/security find-identity -p codesigning "$keychain" >&2
  exit 65
fi
print -r -- "$identity"
