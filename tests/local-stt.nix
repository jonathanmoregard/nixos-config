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
#     uses the full window, and with the short-window model down, or accepting
#     but not answering within LOCAL_STT_SHORT_TIMEOUT seconds, short clips
#     fall back to the full-window one;
#   - with the Swedish model down, Swedish audio still gets the general
#     model's text; with the general model down, the caller gets a 502, not a
#     hang or an empty 200;
#   - the detected language is the most probable candidate, wherever it
#     sits in whisper-server's list;
#   - text whisper-server split mid-word across segments comes back whole;
#   - the model list and a request without audio are answered like the
#     OpenAI API would;
#   - GET or POST /v1/prepare (the record-start ping) answers 204, holds the
#     performance power profile once at a time through powerprofilesctl and
#     leaves ai-throttle's foreground hint; a transcription takes the same
#     hold; without powerprofilesctl the hint is still left and 204 still
#     answered.
#
# Run: nix build .#checks.x86_64-linux.local-stt -L
{ pkgs, routerCommand }:
let
  stub = pkgs.writeText "whisper-stub.py" ''
    import json, sys, time
    from http.server import BaseHTTPRequestHandler, HTTPServer

    port, name, log = int(sys.argv[1]), sys.argv[2], sys.argv[3]
    # Optional: seconds to sit on every request before answering (a wedged server).
    delay = float(sys.argv[4]) if len(sys.argv) > 4 else 0

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
    import json, os, sys, urllib.error, urllib.request, uuid

    # The router under test; a second instance (other settings) listens elsewhere.
    base = "http://127.0.0.1:" + os.environ.get("LOCAL_STT_TEST_PORT", "18765")

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
            with urllib.request.urlopen(req, timeout=30) as r:
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
in
pkgs.runCommand "local-stt-check" { nativeBuildInputs = [ pkgs.python3 pkgs.jq ]; } ''
  set -euo pipefail
  export LOCAL_STT_PORT=18765
  export LOCAL_STT_GENERAL=http://127.0.0.1:18763
  export LOCAL_STT_SWEDISH=http://127.0.0.1:18764
  export LOCAL_STT_GENERAL_SHORT=http://127.0.0.1:18762
  export LOCAL_STT_SHORT_TIMEOUT=2
  # The record-start boost's two side channels: a fake powerprofilesctl that
  # records how it was called and then runs the held command like the real
  # one, and a hint file in a directory that does not exist yet.
  mkdir -p $PWD/bin
  export PPD_LOG=$PWD/powerprofilesctl.calls
  cat > $PWD/bin/powerprofilesctl <<'EOF'
  #!${pkgs.bash}/bin/bash
  echo "$*" >> "$PPD_LOG"
  while [ $# -gt 0 ] && [ "$1" != -- ]; do shift; done
  shift
  exec "$@"
  EOF
  chmod +x $PWD/bin/powerprofilesctl
  export LOCAL_STT_POWERPROFILESCTL=$PWD/bin/powerprofilesctl
  # A hold that outlives this whole run, so "one hold at a time" below is a
  # property of the router, not of how fast the earlier cases happened to go
  # (the wedged-stub case alone takes 20 s of a 30 s hold).
  export LOCAL_STT_HOLD_SECONDS=600
  hint=$PWD/throttle/foreground-hint
  export LOCAL_STT_THROTTLE_HINT=$hint
  log=$PWD/asked
  fail() { echo "FAIL: $*" >&2; exit 1; }

  start_stub() { python3 ${stub} "$1" "$2" "$log.$2" "''${3:-0}" > /dev/null 2>&1 & echo $!; }
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
  # latency for the same words (2026-10-03: 12 real clips; punctuation varied
  # on four, a 1-second "test" came back as "testing"). A long
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

  # Record-start boost. Voquill pings GET /v1/prepare when a recording starts;
  # the router answers 204 at once and, for the seconds the transcription is
  # about to need, holds the performance power profile (powerprofilesctl
  # launch keeps the hold while its child lives; one child at a time) and
  # leaves a foreground hint that ai-throttle reads to pause the background
  # units on its next tick. A transcription takes the same hold inline, so
  # the gain exists without any ping.
  # The transcriptions above already took the hold: one launch whose child
  # (600 s here) is still alive, so every request in this block must ride it
  # rather than start another.
  [ -f "$hint" ] || fail "the transcriptions left no foreground hint at $hint"
  [ "$(sort -u "$PPD_LOG")" = "launch -p performance -- sleep 600" ] || fail "the transcriptions did not hold the performance profile: $(cat "$PPD_LOG")"
  holds=$(wc -l < "$PPD_LOG")
  rm -f "$hint"
  res=$(ask prepare /v1/prepare)
  [ "$(jq -r '.[0]' <<< "$res")" = 204 ] || fail "GET /v1/prepare: $res"
  [ "$(hdr access-control-allow-origin "$res")" = "tauri://localhost" ] || fail "prepare carries no CORS grant for the webview: $res"
  [ -f "$hint" ] || fail "prepare left no foreground hint at $hint"
  res=$(ask prepare-post /prepare)
  [ "$(jq -r '.[0]' <<< "$res")" = 204 ] || fail "POST /prepare: $res"
  # An existing, stale hint is re-dated by the next transcription: ai-throttle
  # reads the mtime, so a hint that is only ever created would go stale after
  # the first dictation.
  touch -d @1500 "$hint"
  before=$(date +%s)
  res=$(ask EN-hello "" "" 3)
  [ "$(jq -r '.[1].text' <<< "$res")" = "short heard it" ] || fail "transcription after prepare: $res"
  [ -f "$hint" ] || fail "a transcription left no foreground hint"
  [ "$(stat -c %Y "$hint")" -ge "$before" ] || fail "a transcription did not re-date the stale hint (mtime $(stat -c %Y "$hint") < $before)"
  sleep 0.3
  [ "$(wc -l < "$PPD_LOG")" = "$holds" ] || fail "a request while the hold lives started another hold: $(cat "$PPD_LOG")"
  # A router with no hold alive: the first prepare starts one, at once.
  mkdir -p $PWD/r3
  PPD_LOG=$PWD/r3/calls LOCAL_STT_PORT=18767 LOCAL_STT_THROTTLE_HINT=$PWD/r3/hint ${routerCommand} > $PWD/r3/log 2>&1 &
  router3=$!
  wait_port 18767
  res=$(LOCAL_STT_TEST_PORT=18767 ask prepare /v1/prepare)
  [ "$(jq -r '.[0]' <<< "$res")" = 204 ] || fail "prepare on a fresh router: $res"
  # The 204 does not wait for the hold's child to start; give it a moment.
  for _ in $(seq 40); do [ -s $PWD/r3/calls ] && break; sleep 0.05; done
  [ "$(cat $PWD/r3/calls)" = "launch -p performance -- sleep 600" ] || fail "a prepare with no hold alive did not start one: $(cat $PWD/r3/calls)"
  [ -f $PWD/r3/hint ] || fail "prepare on a fresh router left no hint"
  kill "$router3"
  # No powerprofilesctl (the lane VM, any machine without power-profiles-daemon):
  # prepare still answers 204 and leaves the hint; the journal says so once.
  LOCAL_STT_PORT=18766 LOCAL_STT_POWERPROFILESCTL=$PWD/no-such-powerprofilesctl \
    LOCAL_STT_THROTTLE_HINT=$PWD/hint2 ${routerCommand} > $PWD/router2.log 2>&1 &
  router2=$!
  wait_port 18766
  res=$(LOCAL_STT_TEST_PORT=18766 ask prepare /v1/prepare)
  [ "$(jq -r '.[0]' <<< "$res")" = 204 ] || fail "prepare without powerprofilesctl: $res"
  [ -f $PWD/hint2 ] || fail "prepare without powerprofilesctl left no hint"
  LOCAL_STT_TEST_PORT=18766 ask prepare /v1/prepare > /dev/null
  [ "$(grep -c 'no powerprofilesctl' $PWD/router2.log)" = 1 ] || fail "a missing powerprofilesctl must be logged once: $(cat $PWD/router2.log)"
  kill "$router2"

  # Short-window model wedged (accepts, never answers): the clip is not held
  # for the backend's long timeout but handed to the full-window model.
  kill "$short"; wait "$short" 2>/dev/null || true
  short=$(start_stub 18762 short 60)
  wait_port 18762
  started=$SECONDS
  res=$(ask EN-hello "" "" 3)
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "short clip with the short-window model wedged: $res"
  [ $((SECONDS - started)) -lt 15 ] || fail "a wedged short-window model held a short clip for $((SECONDS - started)) s"

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
