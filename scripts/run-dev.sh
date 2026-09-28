#!/bin/zsh
# Builds the development Cida (build/Cida Dev.app, see build-app.sh) and runs it in place of the
# released one: both register the same global shortcuts, so only one may run at a time.
#
#   scripts/run-dev.sh        build, quit the released Cida, start the development build
#   scripts/run-dev.sh stop   quit the development build and start the released Cida again
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
release_id=com.xuanwo.Cida
development_id=com.xuanwo.Cida.dev
development_app="$project_dir/build/Cida Dev.app"

# Quits the running app with this bundle identifier, if any, and waits until it is gone.
quit_app() {
  local asn pid
  asn=$(/usr/bin/lsappinfo find "bundleid=$1")
  [[ -n "$asn" ]] || return 0
  pid=$(/usr/bin/lsappinfo info -only pid "$asn" | /usr/bin/sed -n 's/.*pid"* *= *\([0-9][0-9]*\).*/\1/p' | /usr/bin/head -1)
  [[ -n "$pid" ]] || return 0
  /bin/kill -TERM "$pid"
  for _ in {1..50}; do
    /bin/kill -0 "$pid" 2>/dev/null || return 0
    /bin/sleep 0.1
  done
  echo "$1 (pid $pid) did not quit" >&2
  return 1
}

case ${1:-} in
  "")
    CIDA_VARIANT=dev "$script_dir/build-app.sh" release
    quit_app "$release_id"
    quit_app "$development_id"
    /usr/bin/open -g "$development_app"
    ;;
  stop)
    quit_app "$development_id"
    /usr/bin/open -g -b "$release_id" || echo "The released Cida is not installed" >&2
    ;;
  *)
    echo "Usage: $0 [stop]" >&2
    exit 64
    ;;
esac
