#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 3 )); then
  echo "Usage: $0 <artifact directory> [--require-clean-source] [--require-developer-id]" >&2
  exit 64
fi

script_dir=${0:A:h}
artifact_root=${1:A}
shift
require_clean_source=false
require_developer_id=false
for argument in "$@"; do
  case "$argument" in
    --require-clean-source) require_clean_source=true ;;
    --require-developer-id) require_developer_id=true ;;
    *)
      echo "Unknown argument: $argument" >&2
      exit 64
      ;;
  esac
done

manifest_path="$artifact_root/artifact-manifest.json"
app_relative_path=$(/usr/bin/plutil -extract appRelativePath raw "$manifest_path")
app_path="$artifact_root/$app_relative_path"
if [[ ! -f "$manifest_path" || ! -d "$app_path" ]]; then
  echo "Release artifact is incomplete: $artifact_root" >&2
  exit 66
fi
if [[ ! -x "$app_path/Contents/MacOS/Cida" ]]; then
  echo "Release artifact executable lost its executable permission" >&2
  exit 1
fi
if [[ ! -d "$app_path/Contents/Resources/Cida_Cida.bundle" ]]; then
  echo "Release artifact is missing its packaged resource bundle" >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict "$app_path"
expected_bundle_identifier=$(
  /usr/bin/plutil -extract bundleIdentifier raw "$manifest_path"
)
actual_bundle_identifier=$(
  /usr/bin/plutil -extract CFBundleIdentifier raw "$app_path/Contents/Info.plist"
)
if [[ "$actual_bundle_identifier" != "$expected_bundle_identifier" ]]; then
  echo "Artifact bundle identifier changed after manifest creation" >&2
  exit 1
fi

expected_app_sha=$(/usr/bin/plutil -extract appTreeSHA256 raw "$manifest_path")
actual_app_sha=$("$script_dir/app-tree-sha256.sh" "$app_path")
if [[ "$actual_app_sha" != "$expected_app_sha" ]]; then
  actual_listing="$artifact_root/artifact-tree-actual.txt"
  "$script_dir/app-tree-sha256.sh" "$app_path" "$actual_listing" >/dev/null
  /usr/bin/diff -u "$artifact_root/artifact-tree.txt" "$actual_listing" >&2 || true
  echo "Artifact tree digest mismatch: expected $expected_app_sha, got $actual_app_sha" >&2
  exit 1
fi

expected_executable_sha=$(
  /usr/bin/plutil -extract executableSHA256 raw "$manifest_path"
)
actual_executable_sha=$(
  /usr/bin/shasum -a 256 "$app_path/Contents/MacOS/Cida" \
    | /usr/bin/awk '{print $1}'
)
if [[ "$actual_executable_sha" != "$expected_executable_sha" ]]; then
  echo "Artifact executable digest mismatch" >&2
  exit 1
fi

if [[ "$require_clean_source" == true ]]; then
  source_dirty=$(/usr/bin/plutil -extract sourceDirty raw "$manifest_path")
  if [[ "$source_dirty" != false ]]; then
    echo "Release artifact was built from a dirty source tree" >&2
    exit 1
  fi
fi

if [[ "$require_developer_id" == true ]]; then
  signature_mode=$(/usr/bin/plutil -extract signatureMode raw "$manifest_path")
  if [[ "$signature_mode" != developer-id ]]; then
    echo "Release artifact was not signed with Developer ID" >&2
    exit 1
  fi
fi

echo "$actual_app_sha"
