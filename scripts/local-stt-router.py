"""local-stt: one OpenAI-compatible transcription endpoint over two whisper.cpp servers.

Voquill (or anything else speaking the OpenAI audio API) posts to
POST /v1/audio/transcriptions. Each request is answered by the model that is
best at its language, measured on this machine on 2026-10-01:

  - whisper-large-v3-turbo transcribes English best and detects the language
    reliably, but on real Swedish speech it loops and invents sentences;
  - kb-whisper-large (National Library of Sweden) transcribes real Swedish
    best, but renders English speech as Swedish, even when told the audio is
    English.

So every request goes to turbo first with language detection on. If turbo
heard Swedish, the same audio is transcribed again by kb-whisper and that
text is returned. A caller that names the language skips detection: "sv"
goes straight to kb-whisper, anything else to turbo.

If kb-whisper is down, the Swedish request is answered with turbo's text
rather than failing; if turbo is down, the request fails with 502.

Settings come from the environment (the systemd unit sets them):
  LOCAL_STT_PORT      port to listen on (127.0.0.1 only)
  LOCAL_STT_GENERAL   base URL of the turbo whisper-server
  LOCAL_STT_SWEDISH   base URL of the kb-whisper whisper-server
"""

import email.parser
import email.policy
import json
import os
import sys
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("LOCAL_STT_PORT", "8766"))
GENERAL = os.environ.get("LOCAL_STT_GENERAL", "http://127.0.0.1:8763")
SWEDISH = os.environ.get("LOCAL_STT_SWEDISH", "http://127.0.0.1:8764")
TIMEOUT = 600
MODEL_ID = "local-stt"


class BackendError(Exception):
    pass


def parse_form(content_type, body):
    """Fields of a multipart/form-data body as {name: (filename, content_type, bytes)}."""
    msg = email.parser.BytesParser(policy=email.policy.HTTP).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body)
    if not msg.is_multipart():
        raise ValueError("expected multipart/form-data")
    fields = {}
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if name:
            fields[name] = (part.get_filename(), part.get_content_type(), part.get_payload(decode=True) or b"")
    return fields


def transcribe(base, audio, language, prompt):
    """Run one whisper-server; returns (text, detected language code or None)."""
    boundary = uuid.uuid4().hex
    parts = [("response_format", "verbose_json"), ("temperature", "0"), ("language", language)]
    if prompt:
        parts.append(("prompt", prompt))
    body = b""
    for key, value in parts:
        body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{key}\"\r\n\r\n"
                 f"{value}\r\n").encode()
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"
             "Content-Type: audio/wav\r\n\r\n").encode() + audio + f"\r\n--{boundary}--\r\n".encode()
    request = urllib.request.Request(
        base + "/inference", data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            result = json.load(response)
    except (urllib.error.URLError, OSError, ValueError) as e:
        raise BackendError(f"{base}: {e}") from e
    if "error" in result:
        raise BackendError(f"{base}: {result['error']}")
    # whisper-server joins segments with a newline, and a segment can end in
    # the middle of a word; the segments themselves carry their own spacing.
    segments = result.get("segments")
    if isinstance(segments, list):
        text = "".join(s.get("text", "") for s in segments)
    else:
        text = result.get("text", "").replace("\n", "")
    # With detection on, whisper-server lists the candidate languages in no
    # particular order; the detected one is the most probable.
    probabilities = result.get("language_probabilities") or {}
    detected = max(probabilities, key=probabilities.get) if probabilities else None
    return text.strip(), detected


def route(audio, language, prompt):
    """The text for one request, and which model produced it."""
    text = None
    if language != "sv":
        text, detected = transcribe(GENERAL, audio, language or "auto", prompt)
        if language or detected != "sv":
            return text, "turbo"
    try:
        return transcribe(SWEDISH, audio, "sv", prompt)[0], "kb-whisper"
    except BackendError as e:
        print(f"local-stt: Swedish model unavailable, answering with turbo's text: {e}",
              file=sys.stderr, flush=True)
    if text is None:
        text = transcribe(GENERAL, audio, "sv", prompt)[0]
    return text, "turbo (Swedish model unavailable)"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("local-stt: " + fmt % args, file=sys.stderr, flush=True)

    def reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/") in ("/v1/models", "/models"):
            self.reply(200, {"object": "list", "data": [{"id": MODEL_ID, "object": "model", "owned_by": "local"}]})
        elif self.path.rstrip("/") in ("", "/health"):
            self.reply(200, {"status": "ok"})
        else:
            self.reply(404, {"error": {"message": f"no route {self.path}"}})

    def do_POST(self):
        if self.path.rstrip("/") not in ("/v1/audio/transcriptions", "/audio/transcriptions"):
            self.reply(404, {"error": {"message": f"no route {self.path}"}})
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
            fields = parse_form(self.headers.get("Content-Type", ""), self.rfile.read(length))
        except (ValueError, TypeError) as e:
            self.reply(400, {"error": {"message": f"bad request: {e}"}})
            return
        if "file" not in fields or not fields["file"][2]:
            self.reply(400, {"error": {"message": "missing audio 'file' field"}})
            return
        value = lambda k: fields[k][2].decode("utf-8", "replace").strip() if k in fields else ""
        language = value("language").lower()
        language = "" if language == "auto" else language
        try:
            text, model = route(fields["file"][2], language, value("prompt"))
        except BackendError as e:
            self.reply(502, {"error": {"message": f"transcription backend unavailable: {e}"}})
            return
        self.log_message("%s -> %s, %d chars", self.path, model, len(text))
        self.reply(200, {"text": text})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"local-stt: listening on 127.0.0.1:{PORT} (general {GENERAL}, Swedish {SWEDISH})",
          file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
