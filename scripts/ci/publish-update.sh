#!/bin/zsh
# Publishes a notarized Cida zip as an update (Design/spec/updates.md): signs it with Sparkle's
# EdDSA key, uploads it to the R2 bucket cida-releases, adds it to appcast.xml and signs the
# feed. A release (not a candidate) also becomes latest/Cida.zip, the READMEs' download link.
#
#   SPARKLE_ED_PRIVATE_KEY=<exported key> AWS_ACCESS_KEY_ID=<R2 key> AWS_SECRET_ACCESS_KEY=<R2 secret> \
#   scripts/ci/publish-update.sh <zip> <version> <build> <release|beta> [notes file]
#
# The R2 key is an API token limited to Object Read & Write on cida-releases. The zip goes up
# first and the feed last, so the feed never points at a missing file.
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "usage: $0 <zip> <version> <build> <release|beta> [notes file]" >&2
  exit 64
fi
archive=${1:A}
version=$2
build=$3
channel=$4
notes=${5:-}
if [[ "$channel" != release && "$channel" != beta ]]; then
  echo "channel must be release or beta, got $channel" >&2
  exit 64
fi
for variable in SPARKLE_ED_PRIVATE_KEY AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  if [[ -z "${(P)variable:-}" ]]; then
    echo "$variable is required" >&2
    exit 64
  fi
done

script_dir=${0:A:h}
bucket=cida-releases
endpoint=https://d100c32126daec20555857d36239c412.r2.cloudflarestorage.com
public_host=https://cida-releases.xuanwo.io
sparkle_version=2.10.0
sparkle_sha256=c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c

export AWS_DEFAULT_REGION=auto
# R2 rejects the checksums newer AWS CLIs send by default.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
s3() { aws --endpoint-url "$endpoint" "$@"; }

# put <file> <key> <content type> <cache control> [content disposition]
put() {
  local arguments=(--only-show-errors --content-type "$3" --cache-control "$4")
  [[ -n "${5:-}" ]] && arguments+=(--content-disposition "$5")
  s3 s3 cp "${arguments[@]}" "$1" "s3://$bucket/$2"
}

work=$(mktemp -d)
chmod 700 "$work"
trap '/bin/rm -rf "$work"' EXIT

/usr/bin/curl --fail --silent --show-error --location --retry 3 \
  "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
  -o "$work/sparkle.tar.xz"
if [[ "$(/usr/bin/shasum -a 256 "$work/sparkle.tar.xz" | /usr/bin/awk '{print $1}')" != "$sparkle_sha256" ]]; then
  echo "Sparkle $sparkle_version tools do not match the pinned checksum" >&2
  exit 70
fi
/usr/bin/tar -xJf "$work/sparkle.tar.xz" -C "$work" bin/sign_update
sign() { print -rn -- "$SPARKLE_ED_PRIVATE_KEY" | "$work/bin/sign_update" --ed-key-file - "$@"; }

# sign_update prints: sparkle:edSignature="…" length="…"
signed=$(sign "$archive")
signature=$(print -r -- "$signed" | /usr/bin/sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')
length=$(print -r -- "$signed" | /usr/bin/sed -n 's/.*length="\([0-9]*\)".*/\1/p')
if [[ -z "$signature" || -z "$length" ]]; then
  echo "sign_update did not sign $archive" >&2
  exit 70
fi

# The feed is read from the bucket, not the CDN, whose copy can be minutes old.
if s3 s3api head-object --bucket "$bucket" --key appcast.xml >/dev/null 2>"$work/head.err"; then
  s3 s3 cp --only-show-errors "s3://$bucket/appcast.xml" "$work/current.xml"
elif ! /usr/bin/grep -q '(404)' "$work/head.err"; then
  echo "Reading the current feed failed:" >&2
  /bin/cat "$work/head.err" >&2
  exit 70
fi

key="releases/$version-$build/${archive:t}"
appcast_arguments=(
  --appcast "$work/current.xml" --output "$work/appcast.xml"
  --version "$version" --build "$build"
  --url "$public_host/$key" --length "$length" --signature "$signature"
)
[[ "$channel" == beta ]] && appcast_arguments+=(--channel beta)
[[ -n "$notes" ]] && appcast_arguments+=(--notes "$notes")
/usr/bin/python3 "$script_dir/update-appcast.py" "${appcast_arguments[@]}"
sign "$work/appcast.xml" >/dev/null

put "$archive" "$key" application/zip "public, max-age=31536000, immutable"
if [[ "$channel" == release ]]; then
  put "$archive" latest/Cida.zip application/zip "public, max-age=300" \
    "attachment; filename=\"Cida-$version.zip\""
fi
put "$work/appcast.xml" appcast.xml "application/xml; charset=utf-8" "public, max-age=300"

echo "Published $version ($build, $channel): $public_host/$key"
