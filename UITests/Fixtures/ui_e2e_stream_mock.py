import http.server
import json
import pathlib
import sys
import time


record_path = pathlib.Path(sys.argv[1])
port_path = pathlib.Path(sys.argv[2])
default_response_chunks = [
    "The response starts after a short backend pause.\n",
    *[
        f"Streamed line {index} remains smooth and visible while content grows.\n"
        for index in range(30)
    ],
    "CIDA_UI_E2E_COMPLETE",
]


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(content_length)
        record = {
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
            "body": json.loads(raw_body),
        }
        record_path.write_text(json.dumps(record, ensure_ascii=False), encoding="utf-8")

        messages = record["body"].get("messages", [])
        submitted_text = messages[-1].get("content", "") if messages else ""
        if submitted_text == "CIDA_STALE_PIXEL_PROBE":
            response_chunks = ["CIDA_STALE_PIXEL_PROBE_COMPLETE"]
            initial_delay = 10.0
        elif submitted_text == "CIDA_CONTINUITY_FIRST":
            response_chunks = [*default_response_chunks[:-1], "CIDA_UI_E2E_COMPLETE_FIRST"]
            initial_delay = 3.0
        elif submitted_text == "CIDA_CONTINUITY_SECOND":
            response_chunks = [*default_response_chunks[:-1], "CIDA_UI_E2E_COMPLETE_SECOND"]
            initial_delay = 3.0
        else:
            response_chunks = default_response_chunks
            initial_delay = 0.8

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        time.sleep(initial_delay)
        for index, chunk in enumerate(response_chunks):
            event = {"choices": [{"delta": {"content": chunk}}]}
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode("utf-8"))
            self.wfile.flush()
            time.sleep(0.01 if index % 5 else 0.08)

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        self.close_connection = True

    def log_message(self, format, *args):
        return


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_path.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
