#!/bin/zsh
set -euo pipefail

if (( $# != 0 )); then
  echo "Usage: $0" >&2
  exit 64
fi

script_dir=${0:A:h}
project_dir=${script_dir:h:h}

if [[ -n "${CIDA_RELEASE_ARTIFACT_ROOT:-}" ]]; then
  artifact_root=${CIDA_RELEASE_ARTIFACT_ROOT:A}
  "$script_dir/verify-release-artifact.sh" "$artifact_root" >/dev/null
  echo "$artifact_root"
  exit 0
fi

artifact_parent="$project_dir/TestResults/performance-artifacts"
artifact_root="$artifact_parent/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$artifact_parent"
"$script_dir/build-release-artifact.sh" "$artifact_root" >/dev/null
echo "$artifact_root"
