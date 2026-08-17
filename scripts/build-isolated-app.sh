#!/bin/zsh
set -euo pipefail

if (( $# != 3 )); then
  echo "Usage: $0 <Cida binary> <output app> <automation bundle identifier>" >&2
  exit 64
fi

script_dir=${0:A:h}
project_dir=${script_dir:h}
binary_path=${1:A}
app_path=${2:A}
bundle_identifier=$3

if [[ ! -x "$binary_path" ]]; then
  echo "Cida automation binary is not executable: $binary_path" >&2
  exit 66
fi
if [[ "$bundle_identifier" != com.xuanwo.Cida.Automation.* ]]; then
  echo "Automation bundle identifier must use com.xuanwo.Cida.Automation.*" >&2
  exit 64
fi
if [[ -e "$app_path" ]]; then
  echo "Refusing to replace an existing app: $app_path" >&2
  exit 73
fi

binary_dir=${binary_path:h}
resource_bundle="$binary_dir/Cida_Cida.bundle"
if [[ ! -d "$resource_bundle" ]]; then
  app_resources="${binary_dir:h}/Resources/Cida_Cida.bundle"
  if [[ -d "$app_resources" ]]; then
    resource_bundle=$app_resources
  fi
fi
if [[ ! -d "$resource_bundle" ]]; then
  echo "Cida resource bundle is missing: $resource_bundle" >&2
  exit 66
fi

output_dir=${app_path:h}
mkdir -p "$output_dir"
staging_root=$(mktemp -d "$output_dir/.cida-isolated-app.XXXXXX")
trap '/bin/rm -r "$staging_root"' EXIT
staging_app="$staging_root/${app_path:t}"

mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"
/usr/bin/install -m 755 "$binary_path" "$staging_app/Contents/MacOS/Cida"
/usr/bin/ditto "$resource_bundle" "$staging_app/Contents/Resources/Cida_Cida.bundle"
/usr/bin/install -m 644 "$project_dir/Resources/Cida-Info.plist" \
  "$staging_app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$bundle_identifier" \
  "$staging_app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleDisplayName -string "辞达测试" \
  "$staging_app/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleName -string "辞达测试" \
  "$staging_app/Contents/Info.plist"

actual_identifier=$(
  /usr/bin/plutil -extract CFBundleIdentifier raw "$staging_app/Contents/Info.plist"
)
if [[ "$actual_identifier" != "$bundle_identifier" || "$actual_identifier" == "com.xuanwo.Cida" ]]; then
  echo "Automation bundle identity isolation failed" >&2
  exit 70
fi

/usr/bin/codesign --force --deep --sign - "$staging_app"
/usr/bin/codesign --verify --deep --strict "$staging_app"
/bin/mv "$staging_app" "$app_path"
echo "$app_path"
