#!/usr/bin/env python3

import http.server
import json
import pathlib
import sys
import threading
import time
import urllib.parse


if len(sys.argv) != 3:
    raise SystemExit("usage: e2e_scenario_server.py <latest request> <port file>")

record_path = pathlib.Path(sys.argv[1])
event_path = record_path.with_name(f"{record_path.stem}-events.jsonl")
port_path = pathlib.Path(sys.argv[2])


class ScenarioState:
    def __init__(self):
        self.lock = threading.Lock()
        self.next_request_id = 1
        self.requests = []
        self.gates = {}

    def begin(self, scenario, request):
        with self.lock:
            request_id = self.next_request_id
            self.next_request_id += 1
            state = {
                "requestID": request_id,
                "scenario": scenario,
                "status": "received",
                "chunksSent": 0,
                "request": request,
            }
            self.requests.append(state)
            self.gates[request_id] = threading.Event()
        self.event(request_id, "request-received")
        return request_id

    def event(self, request_id, name, **values):
        with self.lock:
            request = next(
                (item for item in self.requests if item["requestID"] == request_id),
                None,
            )
            if request is None:
                # A reset from the next test dropped this request while its
                # stream was still being written; nothing left to record.
                return
            request["status"] = name
            request.update(values)
            event = {
                "monotonic": time.monotonic(),
                "requestID": request_id,
                "scenario": request["scenario"],
                "event": name,
                **values,
            }
            with event_path.open("a", encoding="utf-8") as output:
                output.write(json.dumps(event, ensure_ascii=False) + "\n")

    def snapshot(self):
        with self.lock:
            return {
                "requests": [
                    {key: value for key, value in item.items() if key != "request"}
                    for item in self.requests
                ]
            }

    def wait_for_release(self, request_id):
        with self.lock:
            gate = self.gates[request_id]
        gate.wait(timeout=45)

    def release(self, scenario):
        with self.lock:
            matching = [
                item
                for item in self.requests
                if item["scenario"] == scenario
                and item["status"] in {"request-received", "headers-sent"}
            ]
            if not matching:
                return False
            request_id = matching[-1]["requestID"]
            self.gates[request_id].set()
        self.event(request_id, "first-byte-released")
        return True

    def reset(self):
        with self.lock:
            for gate in self.gates.values():
                gate.set()
            self.requests = []
            self.gates = {}
            self.next_request_id = 1
        event_path.unlink(missing_ok=True)


state = ScenarioState()


def plan_for(submitted_text):
    default_chunks = [
        "The response starts after a controlled backend pause.\n",
        *[
            f"Streamed line {index} remains smooth and visible while content grows.\n"
            for index in range(24)
        ],
        "CIDA_UI_E2E_COMPLETE",
    ]
    plans = {
        "CIDA_RELEASE_ARTIFACT_SMOKE": {
            "chunks": ["Signed release artifact response.\n", "CIDA_UI_E2E_COMPLETE"],
        },
        "CIDA_E2E_UNEVEN_STREAM": {
            "chunks": [
                "Uneven response begins.\n",
                "One byte-shaped burst. ",
                "A larger backend burst remains visually smooth.\n",
                *[f"Follow line {index}.\n" for index in range(32)],
                "CIDA_E2E_UNEVEN_COMPLETE",
            ],
            "delays": [0.0, 0.18, 0.01, 0.26, 0.0, 0.12],
        },
        "CIDA_E2E_RESULT_A": {
            "chunks": ["First persisted result.\n", "CIDA_E2E_RESULT_A_COMPLETE"],
        },
        "CIDA_E2E_DELAYED_RESULT_B": {
            "chunks": ["Second fresh result.\n", "CIDA_E2E_RESULT_B_COMPLETE"],
            "gateFirstByte": True,
        },
        "CIDA_STALE_PIXEL_PROBE": {
            "chunks": ["CIDA_STALE_PIXEL_PROBE_COMPLETE"],
            "gateFirstByte": True,
        },
        "CIDA_E2E_CANCEL": {
            "chunks": [
                "Partial result before cancellation.\n",
                "The visible prefix is retained.\n",
                "UNEXPECTED_AFTER_CANCEL",
            ],
            "delays": [0.0, 0.05, 30.0],
        },
        "CIDA_E2E_ERROR": {"status": 500, "body": "controlled upstream failure"},
        "CIDA_E2E_POOL_GATED": {
            "chunks": [
                "Fresh result after pool exhaustion.\n",
                "CIDA_E2E_POOL_GATED_COMPLETE",
            ],
            "gateFirstByte": True,
        },
        "CIDA_CONTINUITY_FIRST": {
            "chunks": [*default_chunks[:-1], "CIDA_UI_E2E_COMPLETE_FIRST"],
            "initialDelay": 0.35,
        },
        "CIDA_CONTINUITY_SECOND": {
            "chunks": [*default_chunks[:-1], "CIDA_UI_E2E_COMPLETE_SECOND"],
            "initialDelay": 0.35,
        },
        "This sentence are unclear and too wordy. CIDA_E2E_IMPROVE_ENGLISH": {
            "chunks": [
                "This sentence is clearer and more concise.\n",
                "CIDA_E2E_IMPROVE_ENGLISH_COMPLETE",
            ],
            "requiredSystemFragments": [
                '"operation":"improve"',
                '"language_behavior":"preserve_source"',
            ],
            "forbiddenSystemFragments": [
                '"source_language"',
                '"target_language"',
            ],
        },
        "这句话不太清楚也有一点啰嗦。CIDA_E2E_IMPROVE_CHINESE": {
            "chunks": [
                "这句话更加清晰、简洁。\n",
                "CIDA_E2E_IMPROVE_CHINESE_COMPLETE",
            ],
            "requiredSystemFragments": [
                '"operation":"improve"',
                '"language_behavior":"preserve_source"',
            ],
            "forbiddenSystemFragments": [
                '"source_language"',
                '"target_language"',
            ],
        },
    }
    if submitted_text in plans:
        return plans[submitted_text]
    if submitted_text == "CIDA CAPTURE SCENARIO":
        # What Vision reads from the source application's line of text.
        return {
            "chunks": ["Captured text translated.\n", "CIDA_CAPTURE_SCENARIO_COMPLETE"],
        }
    if submitted_text.startswith("CIDA_E2E_SELECTION_"):
        return {
            "chunks": [
                f"Translated selection {submitted_text}.\n",
                f"{submitted_text}_COMPLETE",
            ],
            "gateFirstByte": submitted_text.endswith("_GATED"),
        }
    if submitted_text.startswith("CIDA_E2E_POOL_"):
        return {
            "chunks": [
                f"Pool response for {submitted_text}.\n",
                f"{submitted_text}_COMPLETE",
            ]
        }
    return {"chunks": default_chunks, "initialDelay": 0.2}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path != "/control/state":
            self.send_error(404)
            return
        self.send_json(200, state.snapshot())

    def do_POST(self):
        parsed_path = urllib.parse.urlparse(self.path)
        if parsed_path.path == "/control/reset":
            state.reset()
            self.send_json(200, {"reset": True})
            return
        if parsed_path.path == "/control/release-first-byte":
            body = self.read_json_body()
            released = state.release(str(body.get("scenario", "")))
            self.send_json(200 if released else 409, {"released": released})
            return
        if parsed_path.path != "/v1/chat/completions":
            self.send_error(404)
            return

        body = self.read_json_body()
        messages = body.get("messages", [])
        submitted_text = messages[-1].get("content", "") if messages else ""
        request = {
            "path": parsed_path.path,
            "authorization": self.headers.get("Authorization"),
            "body": body,
        }
        temporary_record = record_path.with_suffix(record_path.suffix + ".tmp")
        temporary_record.write_text(
            json.dumps(request, ensure_ascii=False), encoding="utf-8"
        )
        temporary_record.replace(record_path)

        scenario = submitted_text
        request_id = state.begin(scenario, request)
        plan = plan_for(scenario)
        system_message = next(
            (
                message.get("content", "")
                for message in messages
                if message.get("role") == "system"
            ),
            "",
        )
        missing_fragments = [
            fragment
            for fragment in plan.get("requiredSystemFragments", [])
            if fragment not in system_message
        ]
        forbidden_fragments = [
            fragment
            for fragment in plan.get("forbiddenSystemFragments", [])
            if fragment in system_message
        ]
        if missing_fragments or forbidden_fragments:
            plan = {
                "status": 422,
                "body": json.dumps(
                    {
                        "missingSystemFragments": missing_fragments,
                        "forbiddenSystemFragments": forbidden_fragments,
                    },
                    ensure_ascii=False,
                ),
            }
        if plan.get("status", 200) != 200:
            time.sleep(2.0)
            payload = plan.get("body", "controlled failure").encode("utf-8")
            self.send_response(plan["status"])
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.wfile.flush()
            self.close_connection = True
            state.event(request_id, "failed", httpStatus=plan["status"])
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        state.event(request_id, "headers-sent")

        if plan.get("gateFirstByte"):
            state.wait_for_release(request_id)
        elif plan.get("initialDelay", 0) > 0:
            time.sleep(plan["initialDelay"])

        delays = plan.get("delays", [0.01])
        try:
            for index, chunk in enumerate(plan["chunks"]):
                delay = delays[min(index, len(delays) - 1)]
                if delay > 0:
                    time.sleep(delay)
                event = {"choices": [{"delta": {"content": chunk}}]}
                self.wfile.write(f"data: {json.dumps(event)}\n\n".encode("utf-8"))
                self.wfile.flush()
                state.event(request_id, "chunk-sent", chunksSent=index + 1)

            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
            state.event(request_id, "completed", chunksSent=len(plan["chunks"]))
        except (BrokenPipeError, ConnectionResetError):
            state.event(request_id, "client-disconnected")
        finally:
            self.close_connection = True

    def read_json_body(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(content_length)
        return json.loads(raw_body) if raw_body else {}

    def send_json(self, status, value):
        payload = json.dumps(value, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()
        self.close_connection = True

    def log_message(self, format, *args):
        return


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True


record_path.parent.mkdir(parents=True, exist_ok=True)
port_path.parent.mkdir(parents=True, exist_ok=True)
server = Server(("127.0.0.1", 0), Handler)
port_path.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
