#!/bin/zsh
set -euo pipefail

if (( $# != 1 )); then
  echo "Usage: $0 <vm-name>" >&2
  exit 64
fi

vm_name=$1
tart list | /usr/bin/awk -v target="$vm_name" '
  $1 == "local" && $2 == target { found = 1 }
  END { exit found ? 0 : 1 }
'
