#!/usr/bin/env python3
"""Run isolated, resource-bounded end-to-end Cida stress scenarios."""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import signal
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


SCHEMA = """
CREATE TABLE history_entries (
  id TEXT PRIMARY KEY NOT NULL,
  sort_order INTEGER NOT NULL UNIQUE,
  mode TEXT NOT NULL,
  source TEXT NOT NULL,
  result TEXT NOT NULL,
  detail TEXT NOT NULL,
  timestamp TEXT NOT NULL,
  source_character_count INTEGER,
  result_character_count INTEGER,
  state TEXT NOT NULL,
  created_at REAL NOT NULL,
  updated_at REAL NOT NULL
);
PRAGMA user_version = 1;
"""


@dataclasses.dataclass(frozen=True)
class Profile:
    name: str
    small_record_count: int
    small_result_characters: int
    million_character_record_count: int
    input_characters: int = 1_000_000
    output_characters: int = 1_024
    normal_scroll_points: int = 6_000
    hyper_scroll_points: int = 120_000
    timeout_seconds: int = 300
    rss_limit_bytes: int = 16 * 1024**3

    @property
    def initial_history_count(self) -> int:
        return self.small_record_count + self.million_character_record_count + 1


PROFILES = {
    "smoke": Profile(
        name="smoke",
        small_record_count=2_000,
        small_result_characters=256,
        million_character_record_count=4,
        timeout_seconds=120,
        rss_limit_bytes=4 * 1024**3,
    ),
    "million-history": Profile(
        name="million-history",
        small_record_count=999_999,
        small_result_characters=256,
        million_character_record_count=0,
        rss_limit_bytes=1 * 1024**3,
    ),
    "thousand-million-character-records": Profile(
        name="thousand-million-character-records",
        small_record_count=0,
        small_result_characters=0,
        million_character_record_count=1_000,
        rss_limit_bytes=3 * 1024**3,
    ),
}


class MockState:
    def __init__(self, output_characters: int) -> None:
        self.output_characters = output_characters
        self.requests: list[dict[str, Any]] = []
        self.lock = threading.Lock()


def make_handler(state: MockState) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_POST(self) -> None:  # noqa: N802
            content_length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(content_length)
            request: dict[str, Any] = {
                "path": self.path,
                "body_bytes": len(body),
                "input_characters": None,
                "model": None,
                "stream": None,
            }
            try:
                payload = json.loads(body)
                messages = payload.get("messages", [])
                if messages:
                    request["input_characters"] = len(messages[-1].get("content", ""))
                request["model"] = payload.get("model")
                request["stream"] = payload.get("stream")
            except (json.JSONDecodeError, AttributeError, TypeError):
                pass
            with state.lock:
                state.requests.append(request)

            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "close")
            self.end_headers()

            # Reproduce a backend that pauses, dribbles individual characters, then bursts.
            time.sleep(0.18)
            remaining = state.output_characters
            burst_pattern = (1, 1, 2, 512, 3, 7, 256, 1, 1, 1024)
            index = 0
            try:
                while remaining > 0:
                    size = min(remaining, burst_pattern[index % len(burst_pattern)])
                    content = "T" * size
                    event = {
                        "choices": [{"delta": {"content": content}}],
                    }
                    encoded = json.dumps(event, separators=(",", ":")).encode("utf-8")
                    self.wfile.write(b"data: " + encoded + b"\n\n")
                    self.wfile.flush()
                    remaining -= size
                    index += 1
                    if index < 3:
                        time.sleep(0.06)
                    elif index % 4 == 0:
                        time.sleep(0.004)
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return
            self.close_connection = True

        def log_message(self, format: str, *args: Any) -> None:
            return

    return Handler


def deterministic_uuid(index: int) -> str:
    return f"00000000-0000-0000-0000-{index + 1:012x}"


def record_tuple(index: int, result: str) -> tuple[Any, ...]:
    source = f"Persisted stress source {index}"
    now = float(index)
    return (
        deterministic_uuid(index),
        index,
        "translate",
        source,
        result,
        "中文 → English",
        "18:00",
        len(source),
        len(result),
        "completed",
        now,
        now,
    )


INSERT_SQL = """
INSERT INTO history_entries (
  id, sort_order, mode, source, result, detail, timestamp,
  source_character_count, result_character_count, state, created_at, updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""


def seed_database(database_path: Path, profile: Profile) -> dict[str, Any]:
    started = time.monotonic()
    connection = sqlite3.connect(database_path)
    try:
        connection.executescript(
            "PRAGMA journal_mode = OFF;"
            "PRAGMA synchronous = OFF;"
            "PRAGMA locking_mode = EXCLUSIVE;"
            "PRAGMA temp_store = MEMORY;"
            + SCHEMA
        )
        connection.execute("BEGIN IMMEDIATE")

        small_result = (
            "S" * profile.small_result_characters
            if profile.small_result_characters > 0
            else ""
        )
        batch_size = 10_000
        for start in range(0, profile.small_record_count, batch_size):
            end = min(profile.small_record_count, start + batch_size)
            connection.executemany(
                INSERT_SQL,
                (record_tuple(index, small_result) for index in range(start, end)),
            )

        million_result = "M" * 1_000_000
        large_start = profile.small_record_count
        for start in range(0, profile.million_character_record_count, 8):
            end = min(profile.million_character_record_count, start + 8)
            connection.executemany(
                INSERT_SQL,
                (
                    record_tuple(large_start + offset, million_result)
                    for offset in range(start, end)
                ),
            )

        sentinel_index = (
            profile.small_record_count + profile.million_character_record_count
        )
        connection.execute(INSERT_SQL, record_tuple(sentinel_index, "TAIL_SENTINEL"))
        connection.commit()

        row_count, result_characters = connection.execute(
            "SELECT COUNT(*), COALESCE(SUM(length(result)), 0) FROM history_entries"
        ).fetchone()
    finally:
        connection.close()

    return {
        "duration_milliseconds": (time.monotonic() - started) * 1_000,
        "database_bytes": database_path.stat().st_size,
        "row_count": row_count,
        "result_payload_characters": result_characters,
        "expected_result_payload_characters": (
            profile.small_record_count * profile.small_result_characters
            + profile.million_character_record_count * 1_000_000
            + len("TAIL_SENTINEL")
        ),
    }


def process_tree_rss(root_pid: int) -> tuple[int, list[int]]:
    try:
        output = subprocess.check_output(
            ["/bin/ps", "-axo", "pid=,ppid=,rss="],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.SubprocessError:
        return 0, []
    children: dict[int, list[int]] = {}
    rss_by_pid: dict[int, int] = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) != 3:
            continue
        pid, parent_pid, rss_kib = map(int, fields)
        children.setdefault(parent_pid, []).append(pid)
        rss_by_pid[pid] = rss_kib * 1024

    descendants: list[int] = []
    pending = [root_pid]
    while pending:
        parent = pending.pop()
        for child in children.get(parent, []):
            descendants.append(child)
            pending.append(child)
    return sum(rss_by_pid.get(pid, 0) for pid in [root_pid, *descendants]), descendants


def terminate_process_group(process: subprocess.Popen[str]) -> None:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=5)
        return
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        return


def classify_recent_crash(started_wall_time: float) -> dict[str, Any] | None:
    reports_directory = Path.home() / "Library/Logs/DiagnosticReports"
    candidates = sorted(
        (
            path
            for path in reports_directory.glob("Cida-*.ips")
            if path.stat().st_mtime >= started_wall_time - 2
        ),
        key=lambda path: path.stat().st_mtime,
        reverse=True,
    )
    if not candidates:
        return None
    path = candidates[0]
    text = path.read_text(errors="replace")
    if "AG::data::table::grow_region" in text and "ForEachState" in text:
        signature = "swiftui-attribute-graph-capacity"
    elif '"signal":"SIGABRT"' in text:
        signature = "sigabrt"
    else:
        signature = "unknown"
    return {
        "signature": signature,
        "signal": "SIGABRT" if '"signal":"SIGABRT"' in text else None,
        "attribute_graph_growth_failure": "AG::data::table::grow_region" in text,
        "swiftui_for_each_in_backtrace": "ForEachState" in text,
        "report_name": path.name,
    }


def validate_database(database_path: Path, profile: Profile) -> dict[str, Any]:
    connection = sqlite3.connect(f"file:{database_path}?mode=ro", uri=True)
    try:
        row = connection.execute(
            """
            SELECT
              (SELECT COUNT(*) FROM history_entries),
              length(h.source),
              length(COALESCE(r.result, h.result)),
              h.state
            FROM history_entries AS h
            LEFT JOIN history_result_overrides AS r ON r.entry_id = h.id
            ORDER BY h.sort_order DESC
            LIMIT 1
            """
        ).fetchone()
    finally:
        connection.close()
    return {
        "row_count": row[0],
        "latest_source_characters": row[1],
        "latest_result_characters": row[2],
        "latest_state": row[3],
        "passed": row
        == (
            profile.initial_history_count + 1,
            profile.input_characters,
            profile.output_characters,
            "completed",
        ),
    }


def run_profile(
    profile: Profile,
    automation_target: Path,
    runner_path: Path,
    output_directory: Path,
    required_fps: int,
    sample_count: int,
) -> dict[str, Any]:
    with tempfile.TemporaryDirectory(prefix=f"cida-extreme-{profile.name}-") as root:
        temporary_root = Path(root)
        database_path = temporary_root / "History.sqlite3"
        frame_report_path = temporary_root / "frame-report.json"
        seed = seed_database(database_path, profile)

        state = MockState(profile.output_characters)
        server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(state))
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        endpoint = f"http://127.0.0.1:{server.server_port}/v1/chat/completions"

        command = [
            str(runner_path),
            str(automation_target),
            "--automation-history-database",
            str(database_path),
            "--automation-openai-endpoint",
            endpoint,
            "--performance-output",
            str(frame_report_path),
            "--performance-workload",
            "extreme-workflow",
            "--performance-required-fps",
            str(required_fps),
            "--performance-zero-missed-frame-budgets",
            "--performance-samples",
            str(sample_count),
            "--extreme-history-count",
            str(profile.initial_history_count),
            "--extreme-input-characters",
            str(profile.input_characters),
            "--extreme-output-characters",
            str(profile.output_characters),
            "--extreme-normal-scroll-points",
            str(profile.normal_scroll_points),
            "--extreme-hyper-scroll-points",
            str(profile.hyper_scroll_points),
        ]
        started = time.monotonic()
        started_wall_time = time.time()
        process = subprocess.Popen(
            command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        peak_process_tree_rss = 0
        termination_reason: str | None = None
        while process.poll() is None:
            elapsed = time.monotonic() - started
            rss, _ = process_tree_rss(process.pid)
            peak_process_tree_rss = max(peak_process_tree_rss, rss)
            if rss > profile.rss_limit_bytes:
                termination_reason = "rss-limit"
                terminate_process_group(process)
                break
            if elapsed > profile.timeout_seconds:
                termination_reason = "timeout"
                terminate_process_group(process)
                break
            time.sleep(0.1)
        stdout, stderr = process.communicate()
        crash = (
            classify_recent_crash(started_wall_time)
            if process.returncode not in (0, None)
            else None
        )
        server.shutdown()
        server.server_close()
        server_thread.join(timeout=2)

        frame_report: dict[str, Any] | None = None
        if frame_report_path.exists():
            frame_report = json.loads(frame_report_path.read_text())
        persistence = validate_database(database_path, profile)
        with state.lock:
            requests = list(state.requests)
        request_passed = (
            len(requests) == 1
            and requests[0]["path"] == "/v1/chat/completions"
            and requests[0]["input_characters"] == profile.input_characters
            and requests[0]["model"] == "cida-extreme-local-model"
            and requests[0]["stream"] is True
        )
        seed_passed = (
            seed["row_count"] == profile.initial_history_count
            and seed["result_payload_characters"]
            == seed["expected_result_payload_characters"]
        )
        frame_passed = frame_report is not None and frame_report.get("passed") is True
        phase_reports = (
            frame_report.get("phaseFramePacing", {}) if frame_report is not None else {}
        )
        required_phases = ("translating", "normal-scroll", "hyper-scroll", "completed")
        frame_workflow_passed = (
            frame_report is not None
            and frame_report.get("workloadCompleted") is True
            and frame_report.get("workflowPhase") == "completed"
            and frame_report.get("inputCharacterCount") == profile.input_characters
            and frame_report.get("outputCharacterCount") == profile.output_characters
            and frame_report.get("totalHistoryEntryCount")
            == profile.initial_history_count + 1
            and 0 < frame_report.get("historyEntryCount", 0)
            <= min(profile.initial_history_count + 1, 5_001)
            and frame_report.get("normalScrollDistancePoints", 0)
            >= profile.normal_scroll_points
            and frame_report.get("hyperScrollDistancePoints", 0)
            >= profile.hyper_scroll_points
            and frame_report.get("maximumScrollStepPoints", 0) >= 512
            and frame_report.get("streamPresentationUpdateCount", 0) > 0
            and 0
            < frame_report.get("maximumStreamPresentationBatchCharacterCount", 0)
            <= 8
            and frame_report.get("operationDurationMilliseconds", 0) > 0
            and all(
                phase_reports.get(phase, {}).get("sampleCount", 0) > 0
                for phase in required_phases
            )
            and frame_report.get("applicationActivationObserved") is False
            and frame_report.get("probeWindowBecameKey") is False
        )
        workflow_correctness_passed = (
            termination_reason is None
            and process.returncode == 0
            and seed_passed
            and request_passed
            and persistence["passed"]
            and frame_workflow_passed
        )
        passed = workflow_correctness_passed and frame_passed
        result = {
            "profile": dataclasses.asdict(profile),
            "seed": seed,
            "seed_passed": seed_passed,
            "process": {
                "return_code": process.returncode,
                "duration_milliseconds": (time.monotonic() - started) * 1_000,
                "peak_process_tree_resident_bytes": peak_process_tree_rss,
                "rss_limit_bytes": profile.rss_limit_bytes,
                "termination_reason": termination_reason,
                "crash": crash,
                "stdout": stdout[-4_000:],
                "stderr": stderr[-8_000:],
            },
            "request": requests,
            "request_passed": request_passed,
            "persistence": persistence,
            "frame_workflow_passed": frame_workflow_passed,
            "frame_report": frame_report,
            "workflow_correctness_passed": workflow_correctness_passed,
            "frame_pacing_passed": frame_passed,
            "passed": passed,
        }
        individual_path = output_directory / f"extreme-{profile.name}.json"
        individual_path.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
        return result


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--artifact",
        "--binary",
        dest="automation_target",
        required=True,
        type=Path,
    )
    parser.add_argument("--runner", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument(
        "--profile",
        action="append",
        choices=sorted(PROFILES),
        required=True,
    )
    parser.add_argument("--required-fps", type=int, default=120)
    parser.add_argument("--sample-count", type=int, default=2_400)
    parser.add_argument("--allow-failures", action="store_true")
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    arguments.output_directory.mkdir(parents=True, exist_ok=True)
    results = []
    for profile_name in arguments.profile:
        print(f"Running extreme profile: {profile_name}", flush=True)
        result = run_profile(
            PROFILES[profile_name],
            arguments.automation_target,
            arguments.runner,
            arguments.output_directory,
            max(1, arguments.required_fps),
            max(120, arguments.sample_count),
        )
        results.append(result)
        print(
            json.dumps(
                {
                    "profile": profile_name,
                    "passed": result["passed"],
                    "termination_reason": result["process"]["termination_reason"],
                    "frame_passed": bool(result["frame_report"])
                    and result["frame_report"].get("passed") is True,
                    "peak_resident_bytes": result["process"][
                        "peak_process_tree_resident_bytes"
                    ],
                },
                sort_keys=True,
            ),
            flush=True,
        )

    matrix = {
        "required_frames_per_second": arguments.required_fps,
        "sample_count": arguments.sample_count,
        "profiles": results,
        "passed": all(result["passed"] for result in results),
    }
    matrix_path = arguments.output_directory / "extreme-performance-matrix.json"
    matrix_path.write_text(json.dumps(matrix, indent=2, sort_keys=True) + "\n")
    print(matrix_path)
    return 0 if matrix["passed"] or arguments.allow_failures else 1


if __name__ == "__main__":
    sys.exit(main())
