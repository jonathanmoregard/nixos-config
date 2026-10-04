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
to 15 s the words were the same (punctuation varied on four, a 1-second
"test" came back as "testing"; measured 2026-10-03). One server cannot do
both, since changing its window between requests costs seconds. A longer
clip, or audio whose length the router cannot read, goes to the full-window
server, which a smaller window would chunk and garble; so does a short clip
when the short-window server is down or has not answered within
LOCAL_STT_SHORT_TIMEOUT seconds. The Swedish re-transcription always keeps
the full window: Swedish accuracy first.

The record-start boost: on battery this laptop idles at 1.6-2.2 GHz under the
`balanced` power profile and a dictation is a one-second burst, too short for
the governor to ramp for. GET or POST /v1/prepare (Voquill pings it when a
recording starts) answers 204 at once and boost() does two things for the
seconds the transcription is about to need:

  - holds the `performance` power profile: `powerprofilesctl launch -p
    performance -- sleep 30` runs as a child and power-profiles-daemon keeps
    the hold exactly as long as that child lives; one child at a time, so a
    burst of pings cannot stack holds;
  - touches ai-throttle's foreground hint file, so the governor pauses the
    background units (embedding backfill) on its next tick instead of after
    the dictation's CPU time has shown up in cpu.stat.

Every transcription takes the same boost inline, so the gain exists without
any client ping. Without powerprofilesctl (a machine without
power-profiles-daemon) the hint is still left and the request still served;
the journal says so once.

Restarts. A deploy restarts this router and the whisper servers whenever
their units change, and a dictation may be in flight (2026-10-04: one was,
and it was lost). Three things keep the caller from noticing:

  - told to stop (SIGTERM), the router accepts nothing new, finishes the
    requests it holds and only then exits; systemd's TimeoutStopSec bounds
    that;
  - under systemd the listening socket belongs to local-stt.socket and is
    handed to each router process (LISTEN_FDS), so a request that arrives
    between two processes waits in the socket's queue instead of being
    refused;
  - a whisper server that is not there (connection refused, or gone before
    it answered) is waited for, up to LOCAL_STT_BACKEND_WAIT seconds, and the
    audio is sent again; only then do the rules above for a server that is
    down apply. The short-window server is never waited for: the full-window
    one gives the same text a second later.

Settings come from the environment (the systemd unit sets them):
  LOCAL_STT_PORT           port to listen on (127.0.0.1 only), unless systemd
                           hands over a socket
  LOCAL_STT_GENERAL        base URL of the turbo whisper-server (full window)
  LOCAL_STT_GENERAL_SHORT  base URL of the turbo whisper-server with the
                           15-second window (default: LOCAL_STT_GENERAL)
  LOCAL_STT_SWEDISH        base URL of the kb-whisper whisper-server
  LOCAL_STT_SHORT_SECONDS  clips up to this length (s) go to the short-window
                           server (14)
  LOCAL_STT_SHORT_TIMEOUT  seconds to wait for the short-window server before
                           using the full-window one (20)
  LOCAL_STT_POWERPROFILESCTL  the powerprofilesctl binary (default: the one
                           on PATH; none found = no performance hold)
  LOCAL_STT_THROTTLE_HINT  ai-throttle's foreground hint file (default
                           $XDG_RUNTIME_DIR/ai-throttle/foreground-hint)
  LOCAL_STT_BACKEND_WAIT   seconds a request waits for a whisper server that
                           is not there to come back (30)
  LOCAL_STT_CLIENT_IDLE    seconds a connected client may stay silent before
                           it is dropped (5)
"""

import email.parser
import email.policy
import http.client
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import threading
import time
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
SHORT_TIMEOUT = float(os.environ.get("LOCAL_STT_SHORT_TIMEOUT", "20"))
POWERPROFILESCTL = os.environ.get("LOCAL_STT_POWERPROFILESCTL") or shutil.which("powerprofilesctl")
THROTTLE_HINT = os.environ.get("LOCAL_STT_THROTTLE_HINT") or os.path.join(
    os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "ai-throttle", "foreground-hint")
# How long one performance hold lasts: a dictation's transcription plus the
# next one, which is likely close behind. Each prepare while a hold lives
# changes nothing; the first one after it ends starts the next. An input so
# the lane can pick a hold that outlives its whole run.
HOLD_SECONDS = max(1, int(os.environ.get("LOCAL_STT_HOLD_SECONDS", "30")))
# powerprofilesctl is a Python/GLib program whose start-up competes with the
# transcription it serves (un-niced it cost ~35 ms on AC, 2026-10-03), so the
# child is started through nice(1). An argv prefix, not preexec_fn: preexec_fn
# runs Python between fork and exec, which CPython documents as unsafe with
# threads, and a child stuck there would hold the single-flight slot forever.
NICE = os.environ.get("LOCAL_STT_NICE") or shutil.which("nice")
# Seconds a connected client may stay silent, before its request or between
# two pieces of it. A stopping router waits for every connection it has
# accepted, so one that never speaks must not be able to hold the stop, and
# with it every dictation queued behind the restart.
CLIENT_IDLE = float(os.environ.get("LOCAL_STT_CLIENT_IDLE", "5"))
# Seconds a request waits for a whisper server that is not there to come
# back. A server being restarted (a deploy changed its unit, or it crashed)
# is away for the second or two it takes to load its model; the request
# holds the audio and sends it again when the server listens.
BACKEND_WAIT = float(os.environ.get("LOCAL_STT_BACKEND_WAIT", "30"))


class BackendError(Exception):
    pass


class BackendGone(BackendError):
    """The backend was not there: a restart in progress, not an answer."""


def log(message):
    print("local-stt: " + message, file=sys.stderr, flush=True)


class Boost:
    """The record-start boost: one performance hold at a time, and the hint.

    The hold is a child process, `powerprofilesctl launch -p performance --
    sleep HOLD_SECONDS`: power-profiles-daemon releases the hold when its
    D-Bus client exits, so the hold lives exactly as long as the child and
    nothing here has to remember to release it. Requests arrive on threads;
    the lock keeps two of them from both seeing "no child" and spawning two.
    """

    def __init__(self):
        self.lock = threading.Lock()
        self.child = None
        self.said = set()

    def say_once(self, message):
        if message not in self.said:
            self.said.add(message)
            log(message)

    def hold(self):
        if not POWERPROFILESCTL or not os.path.exists(POWERPROFILESCTL):
            self.say_once(f"no powerprofilesctl at {POWERPROFILESCTL or '(PATH)'}; "
                          "transcriptions run without the performance hold")
            return
        with self.lock:
            if self.child is not None:
                if self.child.poll() is None:
                    return
                if self.child.returncode != 0:
                    self.say_once(f"powerprofilesctl exited {self.child.returncode}; "
                                  "is power-profiles-daemon running? Trying again on the next request")
            try:
                argv = [POWERPROFILESCTL, "launch", "-p", "performance", "--", "sleep", str(HOLD_SECONDS)]
                if NICE:
                    argv = [NICE, "-n", "19"] + argv
                self.child = subprocess.Popen(
                    argv, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError as e:
                self.child = None
                self.say_once(f"cannot start powerprofilesctl ({e}); transcriptions run without the performance hold")

    def hint(self):
        try:
            os.makedirs(os.path.dirname(THROTTLE_HINT), exist_ok=True)
            with open(THROTTLE_HINT, "a"):
                pass
            os.utime(THROTTLE_HINT, None)
        except OSError as e:
            self.say_once(f"cannot write the ai-throttle hint {THROTTLE_HINT}: {e}")

    def __call__(self):
        self.hold()
        self.hint()


boost = Boost()


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
    """Length of a WAV clip in seconds from its header, or None if it is not one.

    Slices past the end are empty and read as 0, so a truncated header ends
    in None, never an exception.
    """
    if audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
        return None
    pos, rate, channels, bits = 12, 0, 0, 0
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
    return None


def transcribe(base, audio, language, prompt, timeout=TIMEOUT):
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
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.load(response)
    except (urllib.error.URLError, OSError, ValueError, http.client.HTTPException) as e:
        # URLError wraps the socket error met while connecting or sending.
        # Refused, reset, or closed before or in the middle of the answer:
        # the server is not there (any more). A timeout or an HTTP error is
        # a server that is there and not doing its job, which waiting for a
        # restart would not help.
        cause = e.reason if isinstance(e, urllib.error.URLError) else e
        gone = isinstance(cause, (ConnectionError, http.client.IncompleteRead))
        raise (BackendGone if gone else BackendError)(f"{base}: {e}") from e
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


# Backends that stayed away for a whole BACKEND_WAIT, until they answer again.
away = set()


def reach(base, audio, language, prompt):
    """transcribe(), waiting out a backend that is being restarted.

    A backend that is not there is asked again, the audio sent anew each
    time, until it answers or BACKEND_WAIT seconds have passed. One that
    stayed away for the whole wait is remembered and asked once per request
    from then on, so a model that is down for good (its file was never
    fetched) costs the wait once, not on every dictation; its first answer
    clears the mark.
    """
    patience = 0 if base in away else BACKEND_WAIT
    # Only the time spent waiting counts against the patience: the seconds a
    # request was in flight in a backend that then died are not the backend
    # being away.
    waited, pause = 0.0, 0.05
    while True:
        try:
            result = transcribe(base, audio, language, prompt)
        except BackendGone as e:
            if waited + pause > patience:
                if patience:
                    log(f"{base} did not come back within {patience:g} s; "
                        "it is not waited for again until it answers")
                away.add(base)
                raise
            if not waited:
                log(f"{e}: not answering; waiting up to {patience:g} s for it to come back")
            time.sleep(pause)
            waited += pause
            pause = min(pause * 2, 1.0)
        else:
            if waited:
                log(f"{base} is back")
            away.discard(base)
            return result


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
                text, detected = transcribe(GENERAL_SHORT, audio, language or "auto", prompt,
                                            timeout=SHORT_TIMEOUT)
                note = f"{clip}, 15 s window"
            except BackendError as e:
                print(f"local-stt: short-window model unavailable or slow, using the full window: {e}",
                      file=sys.stderr, flush=True)
        if text is None:
            text, detected = reach(GENERAL, audio, language or "auto", prompt)
        if language or detected != "sv":
            return text, "turbo", note
    # Swedish accuracy first: kb-whisper always gets the full window.
    try:
        return reach(SWEDISH, audio, "sv", prompt)[0], "kb-whisper", f"{clip}, 30 s window"
    except BackendError as e:
        print(f"local-stt: Swedish model unavailable, answering with turbo's text: {e}",
              file=sys.stderr, flush=True)
    if text is None:
        text = reach(GENERAL, audio, "sv", prompt)[0]
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
    # Applies to reads from and writes to the client only; the time a
    # transcription takes is spent waiting on a backend, not on this socket.
    timeout = CLIENT_IDLE

    def log_message(self, fmt, *args):
        log(fmt % args)

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

    def no_content(self):
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.cors_headers()
        self.end_headers()

    def do_OPTIONS(self):
        # The browser's preflight: no body, the grant (or none) in the headers.
        self.send_response(204)
        self.send_header("Content-Length", "0")
        self.send_header("Access-Control-Max-Age", "600")
        self.cors_headers()
        self.end_headers()

    def prepare(self):
        """The record-start ping: boost now, answer at once, no body to wait for."""
        boost()
        self.no_content()

    def do_GET(self):
        if self.path.rstrip("/") in ("/v1/models", "/models"):
            self.reply(200, {"object": "list", "data": [{"id": MODEL_ID, "object": "model", "owned_by": "local"}]})
        elif self.path.rstrip("/") in ("/v1/prepare", "/prepare"):
            self.prepare()
        elif self.path.rstrip("/") in ("", "/health"):
            self.reply(200, {"status": "ok"})
        else:
            self.reply(404, {"error": {"message": f"no route {self.path}"}})

    def do_POST(self):
        if self.path.rstrip("/") in ("/v1/prepare", "/prepare"):
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            self.prepare()
            return
        if self.path.rstrip("/") not in ("/v1/audio/transcriptions", "/audio/transcriptions"):
            self.reply(404, {"error": {"message": f"no route {self.path}"}})
            return
        # The boost before the body is read: the hold and the hint are worth
        # the most at the start of the second the transcription takes.
        boost()
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


def handed_socket():
    """The listening socket systemd holds for this unit (local-stt.socket), or None.

    sd_listen_fds(3): LISTEN_PID names this process and LISTEN_FDS counts the
    sockets passed, the first of them as fd 3. systemd keeps that socket open
    while one router process stops and the next starts, so a connection made
    in between waits in the socket's queue instead of being refused.
    """
    if os.environ.get("LISTEN_PID") != str(os.getpid()) or int(os.environ.get("LISTEN_FDS") or 0) < 1:
        return None
    return socket.socket(fileno=3)


class Server(ThreadingHTTPServer):
    # Not daemon threads: server_close() then waits for every request in
    # flight, which is what lets a restart finish a dictation instead of
    # dropping it (ThreadingHTTPServer's default kills them with the process).
    daemon_threads = False

    def __init__(self, handed):
        # A handed socket is bound and listening already; without one (run by
        # hand, or a unit without its .socket) the router binds PORT itself.
        super().__init__(("127.0.0.1", PORT), Handler, bind_and_activate=handed is None)
        if handed is not None:
            self.socket.close()
            self.socket = handed
            self.server_address = handed.getsockname()


def main():
    handed = handed_socket()
    server = Server(handed)
    # systemd stops a unit with SIGTERM, on a restart too. shutdown() blocks
    # until serve_forever() has returned, and the handler runs in the thread
    # serve_forever() is in, so it is called from another one.
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    host, port = server.server_address[:2]
    log(f"listening on {host}:{port}{' (socket handed over by systemd)' if handed else ''} "
        f"(general {GENERAL}, Swedish {SWEDISH}, "
        f"performance hold via {POWERPROFILESCTL or 'nothing'}, hint {THROTTLE_HINT})")
    server.serve_forever()
    log("told to stop: accepting nothing new, finishing the requests in flight")
    server.server_close()
    log("stopped")


if __name__ == "__main__":
    main()
