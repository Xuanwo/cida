#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  echo "Usage: $0 <artifact directory>" >&2
  exit 64
fi

script_dir=${0:A:h}
project_dir=${script_dir:h:h}
artifact_root=${1:A}
artifact_parent=${artifact_root:h}

if [[ -e "$artifact_root" ]]; then
  echo "Refusing to replace an existing artifact directory: $artifact_root" >&2
  exit 73
fi

mkdir -p "$artifact_parent"
staging_root=$(mktemp -d "$artifact_parent/.cida-release-artifact.XXXXXX")
trap '/bin/rm -r "$staging_root"' EXIT
app_path="$staging_root/Cida.app"
manifest_plist="$staging_root/artifact-manifest.plist"
manifest_path="$staging_root/artifact-manifest.json"

swift build \
  --package-path "$project_dir" \
  --configuration release \
  -Xswiftc -warnings-as-errors
bin_path=$(swift build \
  --package-path "$project_dir" \
  --configuration release \
  --show-bin-path)

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
/usr/bin/install -m 755 "$bin_path/Cida" "$app_path/Contents/MacOS/Cida"
/usr/bin/ditto \
  "$bin_path/Cida_Cida.bundle" \
  "$app_path/Contents/Resources/Cida_Cida.bundle"
/usr/bin/install -m 644 "$project_dir/Resources/Cida-Info.plist" \
  "$app_path/Contents/Info.plist"
/usr/bin/xattr -cr "$app_path"

signing_identity=${CIDA_CODESIGN_IDENTITY:-}
if [[ -z "$signing_identity" ]]; then
  signing_identity=$(
    /usr/bin/security find-identity -v -p codesigning \
      | /usr/bin/sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
      | /usr/bin/head -1
  )
fi

signature_mode=developer-id
if [[ -z "$signing_identity" ]]; then
  if [[ "${CIDA_E2E_ALLOW_ADHOC:-0}" != "1" ]]; then
    echo "A Developer ID identity is required; set CIDA_E2E_ALLOW_ADHOC=1 only for local smoke tests" >&2
    exit 69
  fi
  signing_identity=-
  signature_mode=adhoc
fi

/usr/bin/codesign --force --deep --sign "$signing_identity" --options runtime "$app_path"
/usr/bin/codesign --verify --deep --strict "$app_path"
/usr/bin/plutil -lint "$app_path/Contents/Info.plist" >/dev/null

bundle_identifier=$(
  /usr/bin/plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist"
)
if [[ "$bundle_identifier" != "com.xuanwo.Cida" ]]; then
  echo "Release E2E artifact must retain the production bundle identifier" >&2
  exit 70
fi

app_tree_sha256=$(
  "$script_dir/app-tree-sha256.sh" "$app_path" "$staging_root/artifact-tree.txt"
)
executable_sha256=$(
  /usr/bin/shasum -a 256 "$app_path/Contents/MacOS/Cida" | /usr/bin/awk '{print $1}'
)
source_commit=$(git -C "$project_dir" rev-parse HEAD)
source_dirty=false
if [[ -n "$(git -C "$project_dir" status --porcelain --untracked-files=normal)" ]]; then
  source_dirty=true
fi
codesign_authority=$(
  /usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1 \
    | /usr/bin/sed -n 's/^Authority=//p' | /usr/bin/head -1
)
team_identifier=$(
  /usr/bin/codesign -dv --verbose=4 "$app_path" 2>&1 \
    | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -1
)
xcode_version=$(xcodebuild -version | /usr/bin/paste -s -d ' ' -)
swift_version=$(swift --version | /usr/bin/head -1)

/usr/bin/plutil -create xml1 "$manifest_plist"
/usr/bin/plutil -insert schemaVersion -integer 1 "$manifest_plist"
/usr/bin/plutil -insert appRelativePath -string "Cida.app" "$manifest_plist"
/usr/bin/plutil -insert appTreeSHA256 -string "$app_tree_sha256" "$manifest_plist"
/usr/bin/plutil -insert executableSHA256 -string "$executable_sha256" "$manifest_plist"
/usr/bin/plutil -insert bundleIdentifier -string "$bundle_identifier" "$manifest_plist"
/usr/bin/plutil -insert sourceCommit -string "$source_commit" "$manifest_plist"
/usr/bin/plutil -insert sourceDirty -bool "$source_dirty" "$manifest_plist"
/usr/bin/plutil -insert configuration -string "release" "$manifest_plist"
/usr/bin/plutil -insert signatureMode -string "$signature_mode" "$manifest_plist"
/usr/bin/plutil -insert codesignAuthority -string "${codesign_authority:-adhoc}" "$manifest_plist"
/usr/bin/plutil -insert teamIdentifier -string "${team_identifier:-not-set}" "$manifest_plist"
/usr/bin/plutil -insert macOSVersion -string "$(sw_vers -productVersion)" "$manifest_plist"
/usr/bin/plutil -insert xcodeVersion -string "$xcode_version" "$manifest_plist"
/usr/bin/plutil -insert swiftVersion -string "$swift_version" "$manifest_plist"
/usr/bin/plutil -insert builtAt -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$manifest_plist"
/usr/bin/plutil -convert json -o "$manifest_path" "$manifest_plist"

/bin/mv "$staging_root" "$artifact_root"
trap - EXIT
echo "$artifact_root/artifact-manifest.json"
