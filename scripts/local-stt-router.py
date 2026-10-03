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

Whisper always encodes a padded 30-second window, so a 3-second dictation
costs as much as a 30-second one. A second turbo server keeps a 15-second
window (whisper-server -ac 768) and answers clips of at most
LOCAL_STT_SHORT_SECONDS: half the encoder work, and on 12 real clips of up
to 15 s the text was the same (measured 2026-10-03). One server cannot do
both, since changing its window between requests costs seconds. A longer
clip, or audio whose length the router cannot read, goes to the full-window
server, which a smaller window would chunk and garble; so does a short clip
when the short-window server is down. The Swedish re-transcription always
keeps the full window: Swedish accuracy first.

Settings come from the environment (the systemd unit sets them):
  LOCAL_STT_PORT           port to listen on (127.0.0.1 only)
  LOCAL_STT_GENERAL        base URL of the turbo whisper-server (full window)
  LOCAL_STT_GENERAL_SHORT  base URL of the turbo whisper-server with the
                           15-second window (default: LOCAL_STT_GENERAL)
  LOCAL_STT_SWEDISH        base URL of the kb-whisper whisper-server
  LOCAL_STT_SHORT_SECONDS  clips up to this length (s) go to the short-window
                           server (14)
"""

import email.parser
import email.policy
import json
import os
import re
import sys
import urllib.error
import urllib.request
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("LOCAL_STT_PORT", "8766"))
GENERAL = os.environ.get("LOCAL_STT_GENERAL", "http://127.0.0.1:8763")
GENERAL_SHORT = os.environ.get("LOCAL_STT_GENERAL_SHORT") or GENERAL
SWEDISH = os.environ.get("LOCAL_STT_SWEDISH", "http://127.0.0.1:8764")
TIMEOUT = 600
MODEL_ID = "local-stt"
SHORT_SECONDS = float(os.environ.get("LOCAL_STT_SHORT_SECONDS", "14"))


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


def wav_seconds(audio):
    """Length of a WAV clip in seconds from its header, or None if it is not one."""
    try:
        if audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
            return None
        pos, rate, channels, bits = 12, None, None, None
        while pos + 8 <= len(audio):
            chunk = audio[pos:pos + 4]
            size = int.from_bytes(audio[pos + 4:pos + 8], "little")
            if chunk == b"fmt ":
                channels = int.from_bytes(audio[pos + 10:pos + 12], "little")
                rate = int.from_bytes(audio[pos + 12:pos + 16], "little")
                bits = int.from_bytes(audio[pos + 22:pos + 24], "little")
            elif chunk == b"data":
                if not (rate and channels and bits):
                    return None
                # A streaming encoder may leave the size 0 or 0xFFFFFFFF: trust the bytes.
                present = len(audio) - pos - 8
                length = size if 0 < size <= present else present
                return length / (rate * channels * bits / 8)
            pos += 8 + size + (size & 1)
    except (ValueError, ZeroDivisionError):
        pass
    return None


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
    """The text for one request, which model produced it, and a note on the clip and window."""
    seconds = wav_seconds(audio)
    short = seconds is not None and seconds <= SHORT_SECONDS
    clip = f"{seconds:.1f} s clip" if seconds is not None else "length unknown"
    note = f"{clip}, 30 s window"
    text = None
    if language != "sv":
        detected = None
        if short:
            try:
                text, detected = transcribe(GENERAL_SHORT, audio, language or "auto", prompt)
                note = f"{clip}, 15 s window"
            except BackendError as e:
                print(f"local-stt: short-window model unavailable, using the full window: {e}",
                      file=sys.stderr, flush=True)
        if text is None:
            text, detected = transcribe(GENERAL, audio, language or "auto", prompt)
        if language or detected != "sv":
            return text, "turbo", note
    # Swedish accuracy first: kb-whisper always gets the full window.
    try:
        return transcribe(SWEDISH, audio, "sv", prompt)[0], "kb-whisper", f"{clip}, 30 s window"
    except BackendError as e:
        print(f"local-stt: Swedish model unavailable, answering with turbo's text: {e}",
              file=sys.stderr, flush=True)
    if text is None:
        text = transcribe(GENERAL, audio, "sv", prompt)[0]
    return text, "turbo (Swedish model unavailable)", note


def local_origin(origin):
    """A caller that runs inside a browser on this machine.

    Voquill's settings page tests a key from its webview (origin
    tauri://localhost) with an Authorization header, so the browser asks with
    OPTIONS first and reads nothing without a CORS grant. The grant covers
    local origins only: a web page from elsewhere, open in some browser here,
    gets none, so it cannot use the transcriber or learn it exists.
    """
    if origin == "tauri://localhost":
        return True
    return re.match(r"^https?://(localhost|127\.0\.0\.1)(:\d+)?$", origin) is not None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        print("local-stt: " + fmt % args, file=sys.stderr, flush=True)

    def cors_headers(self):
        origin = self.headers.get("Origin", "")
        if not local_origin(origin):
            return
        self.send_header("Access-Control-Allow-Origin", origin)
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        # The page lists the headers it wants to send: the settings page of
        # Voquill runs the openai SDK, which adds its x-stainless-* telemetry
        # next to the key, and the browser drops the request unless every one
        # is allowed. The origin is local, so allow what it asks for.
        requested = self.headers.get("Access-Control-Request-Headers")
        self.send_header("Access-Control-Allow-Headers", requested or "Authorization, Content-Type")
        self.send_header("Vary", "Origin, Access-Control-Request-Headers")

    def reply(self, status, payload):
        data = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.cors_headers()
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        # The browser's preflight: no body, the grant (or none) in the headers.
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.send_header("Access-Control-Max-Age", "600")
        self.cors_headers()
        self.end_headers()

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
            text, model, note = route(fields["file"][2], language, value("prompt"))
        except BackendError as e:
            self.reply(502, {"error": {"message": f"transcription backend unavailable: {e}"}})
            return
        self.log_message("%s -> %s, %d chars (%s)", self.path, model, len(text), note)
        self.reply(200, {"text": text})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"local-stt: listening on 127.0.0.1:{PORT} (general {GENERAL}, Swedish {SWEDISH})",
          file=sys.stderr, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
