#!/bin/zsh
# Builds and signs build/Cida.app. CIDA_VERSION (CFBundleShortVersionString, e.g. 1.2.0) and
# CIDA_BUILD_NUMBER (CFBundleVersion) override the values in Resources/Cida-Info.plist.
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
configuration=${1:-release}
output_dir="$project_dir/build"
app_path="$output_dir/Cida.app"
mkdir -p "$output_dir"

if [[ -n "${CIDA_VERSION:-}" && ! "$CIDA_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "CIDA_VERSION must be three numbers such as 1.2.0, got $CIDA_VERSION" >&2
  exit 64
fi
if [[ -n "${CIDA_BUILD_NUMBER:-}" && ! "$CIDA_BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]]; then
  echo "CIDA_BUILD_NUMBER must be a positive integer, got $CIDA_BUILD_NUMBER" >&2
  exit 64
fi

signing_identity=${CIDA_CODESIGN_IDENTITY:-}
if [[ -z "$signing_identity" ]]; then
  signing_identity=$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
      | /usr/bin/head -1
  )
fi

if [[ -z "$signing_identity" ]]; then
  echo "A stable Developer ID code-signing identity is required for build/Cida.app." >&2
  echo "Automation must use scripts/run-isolated-automation.sh instead." >&2
  exit 69
fi

staging_root=$(mktemp -d "$output_dir/.cida-production-build.XXXXXX")
trap '/bin/rm -r "$staging_root"' EXIT
staging_app="$staging_root/Cida.app"

mkdir -p "$staging_app/Contents/MacOS"
mkdir -p "$staging_app/Contents/Resources"

swift build \
  --package-path "$project_dir" \
  --configuration "$configuration" \
  -Xswiftc -warnings-as-errors

bin_path=$(swift build \
  --package-path "$project_dir" \
  --configuration "$configuration" \
  --show-bin-path)

/usr/bin/install -m 755 "$bin_path/Cida" "$staging_app/Contents/MacOS/Cida"
/usr/bin/ditto \
  "$bin_path/Cida_Cida.bundle" \
  "$staging_app/Contents/Resources/Cida_Cida.bundle"
/usr/bin/install -m 644 "$project_dir/Resources/Cida-Info.plist" \
  "$staging_app/Contents/Info.plist"
"$script_dir/compile-app-icon.sh" "$staging_app/Contents/Resources"
if [[ -n "${CIDA_VERSION:-}" ]]; then
  /usr/bin/plutil -replace CFBundleShortVersionString -string "$CIDA_VERSION" \
    "$staging_app/Contents/Info.plist"
fi
if [[ -n "${CIDA_BUILD_NUMBER:-}" ]]; then
  /usr/bin/plutil -replace CFBundleVersion -string "$CIDA_BUILD_NUMBER" \
    "$staging_app/Contents/Info.plist"
fi

/usr/bin/xattr -cr "$staging_app"
/usr/bin/codesign --force --deep --sign "$signing_identity" --options runtime "$staging_app"
/usr/bin/codesign --verify --deep --strict "$staging_app"
/usr/bin/plutil -lint "$staging_app/Contents/Info.plist"

designated_requirement=$(/usr/bin/codesign -dr - "$staging_app" 2>&1)
if [[ "$designated_requirement" == *"cdhash"* ]]; then
  echo "Production signing is not stable across builds: $designated_requirement" >&2
  exit 70
fi

if [[ -e "$app_path" ]]; then
  backup_path="$output_dir/Cida.previous.$(date +%s).app"
  /bin/mv "$app_path" "$backup_path"
  echo "Previous app preserved at $backup_path"
fi
/bin/mv "$staging_app" "$app_path"

echo "$app_path"
