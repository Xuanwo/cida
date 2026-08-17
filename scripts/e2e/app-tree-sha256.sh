#!/bin/zsh
set -euo pipefail

if (( $# < 1 || $# > 2 )); then
  echo "Usage: $0 <Cida.app> [tree listing output]" >&2
  exit 64
fi

app_path=${1:A}
if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
  echo "Cida app bundle is missing: $app_path" >&2
  exit 66
fi

emit_tree_listing() {
  cd "$app_path"
  LC_ALL=C /usr/bin/find . \( -type f -o -type l \) -print \
    | LC_ALL=C /usr/bin/sort \
    | while IFS= read -r relative_path; do
      if [[ -L "$relative_path" ]]; then
        digest=$(printf '%s' "$(/usr/bin/readlink "$relative_path")" \
          | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
        kind=link
      else
        digest=$(/usr/bin/shasum -a 256 "$relative_path" | /usr/bin/awk '{print $1}')
        kind=file
      fi
      printf '%s\t%s\t%s\n' "$kind" "$digest" "$relative_path"
    done
}

if (( $# == 2 )); then
  listing_path=${2:A}
  emit_tree_listing >"$listing_path"
  /usr/bin/shasum -a 256 "$listing_path" | /usr/bin/awk '{print $1}'
else
  emit_tree_listing | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}'
fi
