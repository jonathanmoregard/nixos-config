# local-stt: runtime harness for the router tuxedo deploys
# (modules/nixos/local-stt.nix), run against two stub whisper servers. No VM,
# no model, no GPU: the stubs answer like whisper-server does, each with its
# own text, and record what they were asked.
#
# What must hold, whatever the models are:
#   - English audio is answered by the general model alone;
#   - audio the general model detects as Swedish is answered by the Swedish
#     model, with the caller's prompt passed on;
#   - a caller that says the audio is Swedish goes straight to the Swedish
#     model, and one that names another language is not re-routed;
#   - a clip of at most LOCAL_STT_SHORT_SECONDS (14 by default) is answered by
#     the short-window general model (a second turbo server with a 15-second
#     encoder window: half the latency, same text); longer clips and audio of
#     unknown length go to the full-window one, Swedish re-transcription always
#     uses the full window, and with the short-window model down short clips
#     fall back to the full-window one;
#   - with the Swedish model down, Swedish audio still gets the general
#     model's text; with the general model down, the caller gets a 502, not a
#     hang or an empty 200;
#   - the detected language is the most probable candidate, wherever it
#     sits in whisper-server's list;
#   - text whisper-server split mid-word across segments comes back whole;
#   - the model list and a request without audio are answered like the
#     OpenAI API would.
#
# Run: nix build .#checks.x86_64-linux.local-stt -L
{ pkgs, routerCommand }:
let
  stub = pkgs.writeText "whisper-stub.py" ''
    import json, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer

    port, name, log = int(sys.argv[1]), sys.argv[2], sys.argv[3]

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

    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
  '';

  client = pkgs.writeText "local-stt-client.py" ''
    import json, sys, urllib.error, urllib.request, uuid

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
        req = urllib.request.Request("http://127.0.0.1:18765/v1/audio/transcriptions", data=body,
                                     headers={"Content-Type": f"multipart/form-data; boundary={b}"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.load(r)
        except urllib.error.HTTPError as e:
            return e.code, json.load(e)

    what = sys.argv[1]
    if what == "models":
        with urllib.request.urlopen("http://127.0.0.1:18765/v1/models", timeout=10) as r:
            print(json.dumps(json.load(r)))
    elif what == "nofile":
        print(json.dumps(call("", with_file=False)))
    elif what in ("preflight", "models-headers"):
        # A browser-side caller: status and response headers, keys lowercased.
        origin = sys.argv[2]
        if what == "preflight":
            # Third argument: the headers the page wants to send (default: a bare key).
            requested = sys.argv[3] if len(sys.argv) > 3 else "authorization"
            req = urllib.request.Request("http://127.0.0.1:18765/models", method="OPTIONS", headers={
                "Origin": origin, "Access-Control-Request-Method": "GET",
                "Access-Control-Request-Headers": requested})
        else:
            req = urllib.request.Request("http://127.0.0.1:18765/v1/models", headers={"Origin": origin})
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
in
pkgs.runCommand "local-stt-check" { nativeBuildInputs = [ pkgs.python3 pkgs.jq ]; } ''
  set -euo pipefail
  export LOCAL_STT_PORT=18765
  export LOCAL_STT_GENERAL=http://127.0.0.1:18763
  export LOCAL_STT_SWEDISH=http://127.0.0.1:18764
  export LOCAL_STT_GENERAL_SHORT=http://127.0.0.1:18762
  log=$PWD/asked
  fail() { echo "FAIL: $*" >&2; exit 1; }

  start_stub() { python3 ${stub} "$1" "$2" "$log.$2" > /dev/null 2>&1 & echo $!; }
  wait_port() {
    for _ in $(seq 100); do
      python3 -c "import socket; socket.create_connection(('127.0.0.1', $1), 1)" 2>/dev/null && return 0
      sleep 0.1
    done
    fail "nothing listening on $1"
  }
  ask() { python3 ${client} "$@"; }
  asked_count() { if [ -f "$log.$1" ]; then wc -l < "$log.$1"; else echo 0; fi; }

  general=$(start_stub 18763 general)
  swedish=$(start_stub 18764 swedish)
  short=$(start_stub 18762 short)
  ${routerCommand} &
  router=$!
  wait_port 18762; wait_port 18763; wait_port 18764; wait_port 18765

  # English: general model only, and the split word comes back whole.
  res=$(ask EN-hello)
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "English: $res"
  [ "$(asked_count swedish)" = 0 ] || fail "English audio reached the Swedish model"

  # Detected Swedish: re-transcribed by the Swedish model, prompt passed on.
  res=$(ask SV-hej "" "Klaffat, Voquill")
  [ "$(jq -r '.[1].text' <<< "$res")" = "swedish heard it" ] || fail "Swedish: $res"
  [ "$(tail -1 "$log.swedish" | jq -r '.language')" = sv ] || fail "Swedish model not told sv"
  [ "$(tail -1 "$log.swedish" | jq -r '.prompt')" = true ] || fail "prompt not passed to the Swedish model"

  # Caller says Swedish: the general model is not asked at all.
  before=$(asked_count general)
  res=$(ask EN-anything sv)
  [ "$(jq -r '.[1].text' <<< "$res")" = "swedish heard it" ] || fail "language=sv: $res"
  [ "$(asked_count general)" = "$before" ] || fail "language=sv still asked the general model"

  # Caller names another language: no re-routing even if detection would.
  res=$(ask SV-hej en)
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "language=en re-routed: $res"

  # Clip length picks the model: a short clip (most dictation) goes to the
  # short-window turbo server, whose 15-second encoder window halves the
  # latency without changing the text (2026-10-03: 12 real clips). A long
  # clip or audio of unknown length goes to the full-window server, since a
  # smaller window chunks long audio and wrecks the text; the same server
  # cannot serve both, as switching its window costs seconds. Swedish
  # re-transcription always uses the full window: Swedish accuracy first.
  res=$(ask EN-hello "" "" 3)
  [ "$(jq -r '.[1].text' <<< "$res")" = "short heard it" ] || fail "a 3 s clip was not answered by the short-window model: $res"
  res=$(ask EN-hello "" "" 20)
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "a 20 s clip was not answered by the full-window model: $res"
  res=$(ask EN-hello)
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "audio of unknown length was not answered by the full-window model: $res"
  before=$(asked_count general)
  res=$(ask SV-hej "" "" 3)
  [ "$(jq -r '.[1].text' <<< "$res")" = "swedish heard it" ] || fail "short Swedish: $res"
  [ "$(tail -1 "$log.short" | jq -r '.audio')" = SV-hej ] || fail "a short Swedish clip was not detected by the short-window model: $(tail -1 "$log.short")"
  [ "$(asked_count general)" = "$before" ] || fail "a short Swedish clip also went through the full-window general model"

  # API surface.
  [ "$(ask models | jq -r '.data[0].id')" = local-stt ] || fail "model list"
  [ "$(ask nofile | jq -r '.[0]')" = 400 ] || fail "request without audio not refused"

  # A caller inside a browser: Voquill's settings page tests a key from its
  # webview (origin tauri://localhost) and sends an Authorization header, so
  # the browser asks first with OPTIONS and reads nothing without a CORS
  # grant. 2026-10-03 the router answered that OPTIONS with 501 and the
  # settings page reported a connection error. The grant is for local
  # origins only: a web page from elsewhere gets none.
  hdr() { jq -r ".[1].\"$1\" // empty" <<< "$2"; }
  res=$(ask preflight tauri://localhost)
  [ "$(jq -r '.[0]' <<< "$res")" = 204 ] || fail "CORS preflight from Voquill's webview: $res"
  [ "$(hdr access-control-allow-origin "$res")" = "tauri://localhost" ] || fail "preflight does not grant the webview origin: $res"
  grep -qi 'authorization' <<< "$(hdr access-control-allow-headers "$res")" || fail "preflight does not allow the Authorization header: $res"
  grep -q 'POST' <<< "$(hdr access-control-allow-methods "$res")" || fail "preflight does not allow POST: $res"
  res=$(ask models-headers tauri://localhost)
  [ "$(hdr access-control-allow-origin "$res")" = "tauri://localhost" ] || fail "model list carries no CORS grant for the webview: $res"
  res=$(ask preflight https://example.com)
  [ -z "$(hdr access-control-allow-origin "$res")" ] || fail "a foreign web page was granted cross-origin access: $res"

  # The settings page's Test button runs the openai npm SDK in that webview,
  # and the SDK sends its x-stainless-* telemetry headers next to the key. The
  # browser drops the request unless the preflight allows every header the
  # page asked for. 2026-10-03 the router allowed only Authorization and
  # Content-Type, so the SDK gave up with "Connection error." although the
  # model list itself was reachable.
  sdk=authorization,content-type,x-stainless-arch,x-stainless-lang,x-stainless-os,x-stainless-package-version,x-stainless-retry-count,x-stainless-runtime,x-stainless-runtime-version,x-stainless-timeout
  res=$(ask preflight tauri://localhost "$sdk")
  allowed=$(hdr access-control-allow-headers "$res" | tr 'A-Z' 'a-z' | tr -d ' ')
  for h in $(tr ',' ' ' <<< "$sdk"); do
    grep -q "\(^\|,\)$h\(,\|$\)" <<< "$allowed" || fail "preflight does not allow the SDK's $h header (allowed: $allowed)"
  done

  # Short-window model down: short clips still answered, by the full-window one.
  kill "$short"; wait "$short" 2>/dev/null || true
  res=$(ask EN-hello "" "" 3)
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "short clip with the short-window model down: $res"

  # Swedish model down: Swedish audio still answered, by the general model.
  kill "$swedish"; wait "$swedish" 2>/dev/null || true
  res=$(ask SV-hej)
  [ "$(jq -r '.[0]' <<< "$res")" = 200 ] || fail "Swedish with its model down: $res"
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "fallback text: $res"
  res=$(ask EN-anything sv)
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "language=sv with its model down: $res"

  # General model down: an error the caller can see.
  kill "$general"; wait "$general" 2>/dev/null || true
  res=$(ask EN-hello)
  [ "$(jq -r '.[0]' <<< "$res")" = 502 ] || fail "general model down: $res"

  kill "$router"
  echo "local-stt: all assertions passed"
  touch $out
''
