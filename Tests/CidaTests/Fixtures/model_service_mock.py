"""A loopback model service for the in-process tests and the command line's end-to-end run.

It speaks the configured format (chat-completions, responses or anthropic-messages), streams
the planned chunks as server-sent events or answers with one JSON document, and records the
last request. The plan is the second argument, as JSON:

  {"format": "responses", "chunks": ["你", "好"], "stream": true,
   "status": 200, "errorBody": "...", "streamError": "...", "delay": 0.02}

`errorBody` may contain {authorization} or {x-api-key}, replaced by the header the request
carried, so tests can prove that an echoed key is redacted.
"""

import http.server
import json
import sys
import time


record_path = sys.argv[1]
plan = json.loads(sys.argv[2])


def sse(data, event=None):
    lines = []
    if event:
        lines.append(f"event: {event}")
    lines.append(f"data: {json.dumps(data, ensure_ascii=False)}")
    return ("\n".join(lines) + "\n\n").encode("utf-8")


def stream_events(fmt, chunks, stream_error):
    if fmt == "chat-completions":
        yield sse({"choices": [{"index": 0, "delta": {"role": "assistant"}}]})
        for chunk in chunks:
            yield sse({"choices": [{"index": 0, "delta": {"content": chunk}}]})
        if stream_error:
            yield sse({"error": {"message": stream_error}})
            return
        yield b"data: [DONE]\n\n"
    elif fmt == "responses":
        yield sse({"type": "response.created", "response": {"id": "resp_mock"}}, "response.created")
        for chunk in chunks:
            yield sse({"type": "response.output_text.delta", "delta": chunk}, "response.output_text.delta")
        if stream_error:
            yield sse({"type": "error", "message": stream_error}, "error")
            return
        yield sse({"type": "response.completed", "response": {"id": "resp_mock"}}, "response.completed")
    else:
        yield sse({"type": "message_start", "message": {"id": "msg_mock"}}, "message_start")
        yield sse({"type": "content_block_start", "index": 0,
                   "content_block": {"type": "text", "text": ""}}, "content_block_start")
        yield b": keep-alive comment\n\n"
        for chunk in chunks:
            yield sse({"type": "content_block_delta", "index": 0,
                       "delta": {"type": "text_delta", "text": chunk}}, "content_block_delta")
        if stream_error:
            yield sse({"type": "error", "error": {"type": "overloaded_error", "message": stream_error}}, "error")
            return
        yield sse({"type": "content_block_stop", "index": 0}, "content_block_stop")
        yield sse({"type": "message_delta", "delta": {"stop_reason": "end_turn"}}, "message_delta")
        yield sse({"type": "message_stop"}, "message_stop")


def complete_document(fmt, text):
    if fmt == "chat-completions":
        return {"choices": [{"index": 0, "message": {"role": "assistant", "content": text}}]}
    if fmt == "responses":
        return {"output": [{"type": "message", "role": "assistant",
                            "content": [{"type": "output_text", "text": text}]}]}
    return {"content": [{"type": "text", "text": text}], "stop_reason": "end_turn"}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        raw_body = self.rfile.read(content_length)
        record = {
            "path": self.path,
            "headers": {name.lower(): value for name, value in self.headers.items()},
            "body": json.loads(raw_body),
        }
        with open(record_path, "w", encoding="utf-8") as output:
            json.dump(record, output, ensure_ascii=False)

        status = plan.get("status", 200)
        if status != 200:
            body = plan.get("errorBody", "")
            body = body.replace("{authorization}", self.headers.get("Authorization", ""))
            body = body.replace("{x-api-key}", self.headers.get("x-api-key", ""))
            payload = body.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.close_connection = True
            return

        fmt = plan.get("format", "chat-completions")
        chunks = plan.get("chunks", [])
        if not plan.get("stream", True):
            payload = json.dumps(complete_document(fmt, "".join(chunks)), ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
            self.close_connection = True
            return

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        for event in stream_events(fmt, chunks, plan.get("streamError")):
            self.wfile.write(event)
            self.wfile.flush()
            time.sleep(plan.get("delay", 0.02))
        self.close_connection = True

    def log_message(self, format, *args):
        return


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
