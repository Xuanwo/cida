#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_dir=${script_dir:h}
golden_vm=${CIDA_TART_GOLDEN_VM:-cida-ui-golden}
run_vm_prefix="cida-ui-run-$(date +%Y%m%d%H%M%S)-$$"
results_dir=${CIDA_TART_RESULTS_DIR:-"$project_dir/TestResults/vm-ui"}
only_testing=${CIDA_UI_TEST_ONLY_TESTING:-}
swift_test_sanitizer=${CIDA_TART_SWIFT_TEST_SANITIZER:-}
swift_test_filter=${CIDA_TART_SWIFT_TEST_FILTER:-}
guest_timeout_seconds=${CIDA_TART_GUEST_TIMEOUT_SECONDS:-600}
guest_session_timeout_seconds=${CIDA_TART_GUEST_SESSION_TIMEOUT_SECONDS:-900}
boot_attempts=${CIDA_TART_BOOT_ATTEMPTS:-2}
mkdir -p "$results_dir"
results_dir=${results_dir:A}
failure_classification_path="$results_dir/failure-classification.json"
failure_category="infrastructure"
failure_phase="host-preflight"
failure_detail="Host Tart orchestration failed."

write_host_failure() {
  local exit_code=$1
  if (( exit_code != 0 )) && [[ ! -e "$failure_classification_path" ]]; then
    /usr/bin/python3 "$project_dir/scripts/e2e/failure_classification.py" \
      "$failure_classification_path" \
      "$failure_category" \
      "$failure_phase" \
      "$exit_code" \
      "$failure_detail" || true
  fi
}

record_host_failure() {
  local exit_code=$?
  write_host_failure "$exit_code"
  return "$exit_code"
}

trap record_host_failure EXIT

if (( $# != 0 )); then
  echo "Usage: $0" >&2
  exit 64
fi
if ! command -v tart >/dev/null 2>&1; then
  echo "OpenAI Tart is required: brew install openai/tools/tart" >&2
  exit 69
fi
if ! tart list | /usr/bin/grep -q "local  $golden_vm"; then
  echo "Tart golden VM is missing: $golden_vm" >&2
  exit 66
fi

project_dir=${project_dir:A}
artifact_root=${CIDA_RELEASE_ARTIFACT_ROOT:-"$results_dir/ReleaseArtifact"}
artifact_root=${artifact_root:A}
shared_artifact_root="$results_dir/ReleaseArtifact"
run_log="$results_dir/tart-run.log"
progress_log="$results_dir/vm-progress.log"
host_before_path="$results_dir/host-session-before.json"
host_after_path="$results_dir/host-session-after.json"
host_guard_path="$results_dir/host-session-guard.json"
host_monitor_path="$results_dir/host-session-observations.jsonl"
if [[ ! -d "$project_dir" || ! -d "$results_dir" ]]; then
  echo "Tart directory shares must resolve to existing directories" >&2
  exit 66
fi
: >"$progress_log"
: >"$host_monitor_path"
host_progress() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $1" >>"$progress_log"
}
host_monitor_pid=""
host_monitor_healthy=false
start_host_monitor() {
  : >"$host_monitor_path"
  "$project_dir/scripts/e2e/host-session-snapshot.swift" \
    --monitor 0.1 "$artifact_root/Cida.app" "$shared_artifact_root/Cida.app" \
    >"$host_monitor_path" &
  host_monitor_pid=$!
  for _ in {1..200}; do
    [[ -s "$host_monitor_path" ]] && return 0
    kill -0 "$host_monitor_pid" 2>/dev/null || return 1
    /bin/sleep 0.05
  done
  return 1
}
stop_host_monitor() {
  [[ -z "$host_monitor_pid" ]] && return 0
  if kill -0 "$host_monitor_pid" 2>/dev/null; then
    host_monitor_healthy=true
    /bin/kill "$host_monitor_pid" 2>/dev/null || true
    wait "$host_monitor_pid" 2>/dev/null || true
  else
    host_monitor_healthy=false
  fi
  host_monitor_pid=""
}
host_guard_finalized=false
finalize_host_guard() {
  [[ "$host_guard_finalized" == true ]] && return 0
  host_guard_finalized=true
  stop_host_monitor
  "$project_dir/scripts/e2e/host-session-snapshot.swift" >"$host_after_path"
  guard_arguments=(
    "$project_dir/scripts/e2e/compare-host-session.py"
    "$host_before_path"
    "$host_after_path"
    "$host_guard_path"
    --clipboard-isolated
    --monitor-observations "$host_monitor_path"
  )
  if [[ "$host_monitor_healthy" == true ]]; then
    guard_arguments+=(--monitor-healthy)
  fi
  if "${guard_arguments[@]}"
  then
    host_progress "host-session-guard-passed"
    return 0
  fi
  host_progress "host-session-guard-failed"
  return 1
}
"$project_dir/scripts/e2e/host-session-snapshot.swift" >"$host_before_path"
cleanup_before_vm() {
  local exit_code=$?
  finalize_host_guard || true
  write_host_failure "$exit_code"
  return "$exit_code"
}
trap cleanup_before_vm EXIT INT TERM

if [[ -n "${CIDA_RELEASE_ARTIFACT_ROOT:-}" ]]; then
  failure_category="artifact"
  failure_phase="host-artifact-staging"
  failure_detail="The external Release artifact could not be staged or verified."
  host_progress "host-external-release-artifact-verification-started"
  if [[ -e "$shared_artifact_root" ]]; then
    echo "External artifact staging path already exists: $shared_artifact_root" >&2
    exit 73
  fi
  /usr/bin/ditto "$artifact_root" "$shared_artifact_root"
  shared_artifact_digest=$(
    "$project_dir/scripts/e2e/verify-release-artifact.sh" \
      "$shared_artifact_root" --require-developer-id
  )
  external_artifact_digest=$(
    "$project_dir/scripts/e2e/verify-release-artifact.sh" \
      "$artifact_root" --require-developer-id
  )
  if [[ "$shared_artifact_digest" != "$external_artifact_digest" ]]; then
    echo "External Release artifact digest changed while staging it for Tart" >&2
    exit 1
  fi
  host_progress "host-external-release-artifact-verification-finished"
elif [[ -e "$artifact_root" ]]; then
  if [[ "${CIDA_E2E_REUSE_ARTIFACT:-0}" != "1" ]]; then
    echo "Release artifact already exists; use a new result directory or set CIDA_E2E_REUSE_ARTIFACT=1" >&2
    exit 73
  fi
  host_progress "host-release-artifact-reuse-started"
  "$project_dir/scripts/e2e/verify-release-artifact.sh" \
    "$artifact_root" --require-developer-id >/dev/null
  host_progress "host-release-artifact-reuse-finished"
else
  failure_category="build"
  failure_phase="release-artifact-build"
  failure_detail="The Release artifact failed to build."
  host_progress "host-release-artifact-build-started"
  "$project_dir/scripts/e2e/build-release-artifact.sh" "$artifact_root" \
    >"$results_dir/release-artifact-build.log" 2>&1
  host_progress "host-release-artifact-build-finished"
fi
"$project_dir/scripts/e2e/host-session-snapshot.swift" >"$host_before_path"
if ! start_host_monitor; then
  echo "Host artifact monitor failed to start" >&2
  exit 1
fi
host_progress "host-artifact-monitor-ready"
failure_category="infrastructure"

run_vm=""
run_pid=""
cleanup_current_vm() {
  if [[ -n "$run_pid" ]]; then
    tart stop "$run_vm" --timeout 30 >/dev/null 2>&1 || true
    wait "$run_pid" 2>/dev/null || true
    run_pid=""
  fi
  if [[ -n "$run_vm" ]]; then
    tart delete "$run_vm" >/dev/null 2>&1 || true
    run_vm=""
  fi
}
cleanup() {
  local exit_code=$?
  cleanup_current_vm
  finalize_host_guard || true
  write_host_failure "$exit_code"
  return "$exit_code"
}
trap cleanup EXIT INT TERM

probe_guest_agent() {
  /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' \
    3 tart exec "$run_vm" /usr/bin/true >/dev/null 2>&1
}

probe_guest_session() {
  /usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' \
    5 tart exec "$run_vm" /bin/launchctl asuser 501 \
    /usr/bin/sudo -H -u admin /bin/zsh -lc '
      [[ "$(/usr/bin/id -u)" == "501" ]] \
        && /usr/bin/pgrep -x WindowServer >/dev/null \
        && /usr/bin/pgrep -x Dock >/dev/null \
        && /usr/bin/pgrep -x Finder >/dev/null \
        && /bin/launchctl kickstart gui/501/com.apple.testmanagerd >/dev/null 2>&1 \
        && /usr/bin/pgrep -x testmanagerd >/dev/null
    ' >/dev/null 2>&1
}

vm_ready=false
attempt=1
while (( attempt <= boot_attempts )); do
  failure_phase="tart-boot"
  failure_detail="Tart did not reach a healthy guest agent and GUI session."
  run_vm="${run_vm_prefix}-${attempt}"
  host_progress "host-clone-started attempt=${attempt}"
  tart clone "$golden_vm" "$run_vm"
  # Keep the clone identity stable while giving concurrent test VMs distinct networking state.
  tart set "$run_vm" --random-mac
  host_progress "host-clone-finished attempt=${attempt}"

  : >"$run_log"
  tart run "$run_vm" \
    --no-graphics \
    --no-audio \
    --no-clipboard \
    --root-disk-opts="caching=cached,sync=none" \
    --dir="source:${project_dir}:ro" \
    --dir="artifacts:$results_dir" \
    >"$run_log" 2>&1 &
  run_pid=$!
  host_progress "host-vm-started attempt=${attempt}"

  guest_agent_ready=false
  guest_deadline=$((SECONDS + guest_timeout_seconds))
  while (( SECONDS < guest_deadline )); do
    if probe_guest_agent; then
      guest_agent_ready=true
      break
    fi
    if /usr/bin/grep -q '^Failed to run control socket:' "$run_log"; then
      host_progress "host-guest-agent-failed attempt=${attempt} reason=control-socket"
      break
    fi
    if ! kill -0 "$run_pid" 2>/dev/null; then
      host_progress "host-guest-agent-failed attempt=${attempt} reason=vm-stopped"
      break
    fi
    /bin/sleep 1
  done
  if [[ "$guest_agent_ready" != true ]]; then
    host_progress "host-guest-agent-failed attempt=${attempt} reason=timeout-or-startup"
    cleanup_current_vm
    attempt=$((attempt + 1))
    continue
  fi
  host_progress "host-guest-agent-ready attempt=${attempt}"

  if ! tart exec "$run_vm" /usr/bin/sudo /usr/sbin/networksetup \
    -setnetworkserviceenabled Ethernet off >/dev/null 2>&1
  then
    host_progress "host-guest-network-failed attempt=${attempt}"
    cleanup_current_vm
    attempt=$((attempt + 1))
    continue
  fi
  host_progress "host-guest-network-disabled attempt=${attempt}"

  guest_session_ready=false
  guest_session_deadline=$((SECONDS + guest_session_timeout_seconds))
  while (( SECONDS < guest_session_deadline )); do
    if probe_guest_session; then
      guest_session_ready=true
      break
    fi
    if ! kill -0 "$run_pid" 2>/dev/null; then
      host_progress "host-gui-session-failed attempt=${attempt} reason=vm-stopped"
      break
    fi
    /bin/sleep 1
  done
  if [[ "$guest_session_ready" == true ]]; then
    host_progress "host-gui-session-ready attempt=${attempt}"
    vm_ready=true
    break
  fi
  host_progress "host-gui-session-failed attempt=${attempt} reason=timeout-or-startup"
  cleanup_current_vm
  attempt=$((attempt + 1))
done
if [[ "$vm_ready" != true ]]; then
  echo "Tart infrastructure did not reach a ready macOS GUI session after $boot_attempts attempts" >&2
  exit 70
fi

tart exec "$run_vm" /bin/launchctl asuser 501 \
  /usr/bin/sudo -H -u admin /bin/zsh -lc '
  set -euo pipefail
  source_dir="/Volumes/My Shared Files/source"
  results_dir="/Volumes/My Shared Files/artifacts"
  work_dir="/Users/admin/cida-work"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) source-copy-started" >>"$results_dir/vm-progress.log"
  /bin/rm -rf "$work_dir"
  mkdir -p "$work_dir"
  /usr/bin/rsync -a \
    --exclude .git \
    --exclude .build \
    --exclude build \
    --exclude TestResults \
    "$source_dir/" "$work_dir/"
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) source-copy-finished" >>"$results_dir/vm-progress.log"
'
failure_phase="guest-test-execution"
failure_detail="The guest test command failed without writing a more specific classification."
tart exec "$run_vm" /bin/launchctl asuser 501 \
  /usr/bin/sudo -H -u admin /bin/zsh -lc '
  set -euo pipefail
  work_dir="/Users/admin/cida-work"
  results_dir="/Volumes/My Shared Files/artifacts"
  "$work_dir/scripts/run-vm-ui-tests-in-guest.sh" \
    "$work_dir" "$results_dir" "$1" "$2" "$3" "$4"
' -- "$only_testing" "$swift_test_sanitizer" "$swift_test_filter" \
  "/Volumes/My Shared Files/artifacts/ReleaseArtifact"

failure_category="artifact"
failure_phase="host-artifact-final-verification"
failure_detail="The tested artifact changed or failed final host verification."
"$project_dir/scripts/e2e/verify-release-artifact.sh" \
  "$artifact_root" --require-developer-id >/dev/null
host_progress "host-release-artifact-reverified"
staged_digest=$(
  "$project_dir/scripts/e2e/verify-release-artifact.sh" \
    "$shared_artifact_root" --require-developer-id
)
source_digest=$(
  "$project_dir/scripts/e2e/verify-release-artifact.sh" \
    "$artifact_root" --require-developer-id
)
if [[ "$staged_digest" != "$source_digest" ]]; then
  echo "Tart artifact staging copy no longer matches the source artifact" >&2
  exit 1
fi
host_progress "host-staged-release-artifact-reverified"

if ! finalize_host_guard; then
  echo "Headless E2E launched the exact artifact on the host or lost its isolation monitor" >&2
  exit 1
fi

echo "$results_dir/CidaUITests.xcresult"
