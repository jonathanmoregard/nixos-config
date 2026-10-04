# Stand-ins shared by the local-stt lanes (tests/local-stt.nix, which runs the
# router as a plain process, and tests/local-stt-switch.nix, which runs it
# under systemd in a VM and switches configurations under it). No model, no
# GPU: the stub answers like whisper-server does, with its own name as the
# text, and records what it was asked.
{ pkgs }:
{
  stub = pkgs.writeText "whisper-stub.py" ''
    import json, os, sys, time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

    port, name, log = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    # Optional: seconds to sit on every request before answering (a wedged server).
    delay = float(sys.argv[4]) if len(sys.argv) > 4 else 0
    # While this file exists every request is held unanswered: a transcription
    # in flight for exactly as long as a test needs it to be. It outlives the
    # stub, so a restarted stub holds the request that is sent to it again.
    hold = log + ".hold"

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_POST(self):
            body = self.rfile.read(int(self.headers["Content-Length"]))
            raw = body.split(b"\r\n\r\n")[-1].split(b"\r\n--")[0]
            # The client sends a bare token or a WAV whose samples start with
            # the token; the stub only needs the token.
            audio = (raw[44:] if raw.startswith(b"RIFF") else raw).split(b"\0")[0].decode()
            asked = {"audio": audio, "prompt": b'name="prompt"' in body,
                     "language": body.split(b'name="language"\r\n\r\n')[1].split(b"\r\n")[0].decode()}
            with open(log, "a") as f:
                f.write(json.dumps(asked) + "\n")
            time.sleep(delay)
            while os.path.exists(hold):
                time.sleep(0.05)
            lang = "sv" if audio.startswith("SV") else "en"
            if asked["language"] not in ("auto", ""):
                lang = asked["language"]
            # Like whisper-server: several candidates, the detected one not first.
            reply = {"language_probabilities": {"no": 0.001, "en": 0.004, lang: 0.99},
                     "segments": [{"text": " " + name + " hear"}, {"text": "d it"}]}
            data = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    # Threaded, like whisper-server: a held request does not stop the next
    # connection from being accepted. Killed, it drops what it was holding.
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
  '';

  client = pkgs.writeText "local-stt-client.py" ''
    import json, os, sys, urllib.error, urllib.request, uuid

    # The router under test; a second instance (other settings) listens elsewhere.
    base = "http://127.0.0.1:" + os.environ.get("LOCAL_STT_TEST_PORT", "18765")
    # How long a transcription call waits for its answer.
    patience = float(os.environ.get("LOCAL_STT_TEST_TIMEOUT", "30"))

    def wav(token, seconds):
        # 16 kHz mono 16-bit silence of the given length, the token in its first bytes.
        size = int(seconds * 32000)
        data = token.encode().ljust(size, b"\0")
        header = (b"RIFF" + (36 + size).to_bytes(4, "little") + b"WAVEfmt " + (16).to_bytes(4, "little")
                  + (1).to_bytes(2, "little") + (1).to_bytes(2, "little") + (16000).to_bytes(4, "little")
                  + (32000).to_bytes(4, "little") + (2).to_bytes(2, "little") + (16).to_bytes(2, "little")
                  + b"data" + size.to_bytes(4, "little"))
        return header + data

    def call(audio, language=None, prompt=None, with_file=True, seconds=None):
        b = uuid.uuid4().hex
        body = f'--{b}\r\nContent-Disposition: form-data; name="model"\r\n\r\nlocal-stt\r\n'.encode()
        if language:
            body += f'--{b}\r\nContent-Disposition: form-data; name="language"\r\n\r\n{language}\r\n'.encode()
        if prompt:
            body += f'--{b}\r\nContent-Disposition: form-data; name="prompt"\r\n\r\n{prompt}\r\n'.encode()
        if with_file:
            body += (f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="audio.wav"\r\n'
                     f'Content-Type: audio/wav\r\n\r\n').encode()
            body += (wav(audio, seconds) if seconds is not None else audio.encode()) + b'\r\n'
        body += f'--{b}--\r\n'.encode()
        req = urllib.request.Request(base + "/v1/audio/transcriptions", data=body,
                                     headers={"Content-Type": f"multipart/form-data; boundary={b}"})
        try:
            with urllib.request.urlopen(req, timeout=patience) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            return e.code, json.load(e)
        except (urllib.error.URLError, OSError) as e:
            # No answer at all (e.g. the router held the request): a status of its own.
            return 599, {"error": str(e)}

    what = sys.argv[1]
    if what == "models":
        with urllib.request.urlopen(base + "/v1/models", timeout=10) as r:
            print(json.dumps(json.load(r)))
    elif what == "nofile":
        print(json.dumps(call("", with_file=False)))
    elif what in ("prepare", "prepare-post"):
        # The record-start ping, from the webview origin: status and headers.
        path = sys.argv[2] if len(sys.argv) > 2 else "/v1/prepare"
        req = urllib.request.Request(base + path, method="POST" if what == "prepare-post" else "GET",
                                     data=b"" if what == "prepare-post" else None,
                                     headers={"Origin": "tauri://localhost"})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                print(json.dumps([r.status, {k.lower(): v for k, v in r.headers.items()}]))
        except urllib.error.HTTPError as e:
            print(json.dumps([e.code, {k.lower(): v for k, v in e.headers.items()}]))
    elif what in ("preflight", "models-headers"):
        # A browser-side caller: status and response headers, keys lowercased.
        origin = sys.argv[2]
        if what == "preflight":
            # Third argument: the headers the page wants to send (default: a bare key).
            requested = sys.argv[3] if len(sys.argv) > 3 else "authorization"
            req = urllib.request.Request(base + "/models", method="OPTIONS", headers={
                "Origin": origin, "Access-Control-Request-Method": "GET",
                "Access-Control-Request-Headers": requested})
        else:
            req = urllib.request.Request(base + "/v1/models", headers={"Origin": origin})
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                print(json.dumps([r.status, {k.lower(): v for k, v in r.headers.items()}]))
        except urllib.error.HTTPError as e:
            print(json.dumps([e.code, {k.lower(): v for k, v in e.headers.items()}]))
    else:
        audio, language, prompt, seconds = (sys.argv[1:] + ["", "", ""])[:4]
        print(json.dumps(call(audio, language or None, prompt or None,
                              seconds=float(seconds) if seconds else None)))
  '';

  # What systemd does for a socket-activated service, without systemd: holds a
  # listening socket for as long as it lives and hands it to the command as
  # fd 3 with LISTEN_FDS/LISTEN_PID set (sd_listen_fds(3)). The command is
  # started each time <dir>/start appears; its pid is left in <dir>/pid and,
  # once it has exited, its exit status in <dir>/exited. Connections made
  # while no command runs wait in the socket's queue, as they do under systemd.
  socketHolder = pkgs.writeText "socket-holder.py" ''
    import os, socket, sys, time

    port, ctl, command = int(sys.argv[1]), sys.argv[2], sys.argv[3:]
    listener = socket.socket()
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(128)
    while True:
        while not os.path.exists(ctl + "/start"):
            time.sleep(0.05)
        os.unlink(ctl + "/start")
        pid = os.fork()
        if pid == 0:
            if listener.fileno() != 3:
                os.dup2(listener.fileno(), 3)
            os.set_inheritable(3, True)
            os.environ["LISTEN_FDS"] = "1"
            os.environ["LISTEN_PID"] = str(os.getpid())
            os.execvp(command[0], command)
        with open(ctl + "/pid.tmp", "w") as f:
            f.write(str(pid))
        os.replace(ctl + "/pid.tmp", ctl + "/pid")
        status = os.waitpid(pid, 0)[1]
        with open(ctl + "/exited.tmp", "w") as f:
            f.write(str(os.waitstatus_to_exitcode(status)))
        os.replace(ctl + "/exited.tmp", ctl + "/exited")
  '';
}
