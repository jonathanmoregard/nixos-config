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
#     answered;
#   - a restart loses no dictation: the router, told to stop, answers the
#     request it holds before it exits; a request that finds a whisper server
#     gone (not listening, or dead with the request in hand) waits for it and
#     is answered by the new process; on a socket handed over the systemd way
#     a request sent between two router processes waits and is answered. Each
#     with a negative control that is cut. A model that stays away is waited
#     for once, not on every request, and the short-window model never is.
#     (The same under a real user manager and a real switch:
#     tests/local-stt-switch.nix.)
#
# Run: nix build .#checks.x86_64-linux.local-stt -L
{ pkgs, routerCommand }:
let
  # The stub whisper server, the client and the socket holder: shared with
  # the VM lane (tests/local-stt-switch.nix).
  inherit (import ./lib/local-stt-fixtures.nix { inherit pkgs; }) stub client socketHolder;
in
pkgs.runCommand "local-stt-check" { nativeBuildInputs = [ pkgs.python3 pkgs.jq ]; } ''
  set -euo pipefail
  export LOCAL_STT_PORT=18765
  export LOCAL_STT_GENERAL=http://127.0.0.1:18763
  export LOCAL_STT_SWEDISH=http://127.0.0.1:18764
  export LOCAL_STT_GENERAL_SHORT=http://127.0.0.1:18762
  export LOCAL_STT_SHORT_TIMEOUT=2
  # How long a request waits for a model that is not there to come back (a
  # restart). Short here, so the cases with a model down for good stay quick;
  # the restart cases below set their own.
  export LOCAL_STT_BACKEND_WAIT=4
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

  # A deploy must not cut a dictation. 2026-10-04 a NixOS switch changed the
  # unit files of the router and the three whisper servers and restarted all
  # four while a dictation was in flight; the router died on SIGTERM with the
  # request in hand and the dictation was lost. What must hold now, whichever
  # of the four is restarted: a transcription already in flight returns its
  # text, and one that arrives while a server is away is answered once that
  # server is back. The stubs hold a request for as long as <log>.hold exists,
  # so "in flight" below is a fact, not a race.
  hold() { touch "$log.$1.hold"; }
  release() { rm -f "$log.$1.hold"; }
  asked_times() { if [ -f "$log.$1" ]; then grep -c "\"audio\": \"$2\"" "$log.$1" || true; else echo 0; fi; }
  wait_asked() {
    for _ in $(seq 200); do
      [ "$(asked_times "$1" "$2")" -ge "$3" ] && return 0
      sleep 0.05
    done
    fail "the $1 model was not asked for $2 $3 time(s): $(cat "$log.$1" 2>/dev/null)"
  }
  wait_gone() {
    for _ in $(seq "$2"); do
      kill -0 "$1" 2>/dev/null || return 0
      sleep 0.1
    done
    return 1
  }
  status() { jq -r '.[0]' "$1"; }
  text() { jq -r '.[1].text' "$1"; }
  start_router() {
    mkdir -p "$PWD/$1"
    PPD_LOG=$PWD/$1/calls LOCAL_STT_PORT=18768 LOCAL_STT_THROTTLE_HINT=$PWD/$1/hint \
      ${routerCommand} > "$PWD/$1/log" 2>&1 &
  }

  # The router is told to stop (SIGTERM, what systemd sends on a restart)
  # with a transcription in flight: the caller still gets the text, and only
  # then does the router exit, cleanly.
  start_router r4; router4=$!
  wait_port 18768
  hold general
  LOCAL_STT_TEST_PORT=18768 ask EN-inflight > $PWD/r4/inflight & inflight=$!
  wait_asked general EN-inflight 1
  kill -TERM "$router4"
  sleep 1
  kill -0 "$router4" 2>/dev/null || fail "the router exited on SIGTERM with a transcription in flight: $(cat $PWD/r4/log)"
  release general
  wait "$inflight"
  [ "$(status $PWD/r4/inflight)" = 200 ] && [ "$(text $PWD/r4/inflight)" = "general heard it" ] \
    || fail "a transcription in flight when the router was told to stop: $(cat $PWD/r4/inflight)"
  rc=0; wait "$router4" || rc=$?
  [ "$rc" = 0 ] || fail "the router did not exit cleanly once its request was answered (status $rc): $(cat $PWD/r4/log)"
  # Negative control: the same request with the router killed outright is
  # lost, so the case above did have its request in flight across the signal.
  start_router r4k; router4k=$!
  wait_port 18768
  hold general
  LOCAL_STT_TEST_PORT=18768 ask EN-killed > $PWD/r4k/inflight & inflight=$!
  wait_asked general EN-killed 1
  kill -KILL "$router4k"; wait "$router4k" 2>/dev/null || true
  wait "$inflight"
  [ "$(status $PWD/r4k/inflight)" = 599 ] || fail "negative control: a killed router still answered: $(cat $PWD/r4k/inflight)"
  release general

  # A client that connected and never sent a request does not keep a stopping
  # router alive: it is given LOCAL_STT_CLIENT_IDLE seconds, not for ever. A
  # router that waited on it would hold every queued dictation behind it.
  LOCAL_STT_CLIENT_IDLE=2 start_router r4i; router4i=$!
  wait_port 18768
  python3 -c "import socket, time; s = socket.create_connection(('127.0.0.1', 18768)); time.sleep(120)" &
  silent=$!
  sleep 0.5
  kill -TERM "$router4i"
  wait_gone "$router4i" 100 || fail "a silent connection kept the stopping router alive: $(cat $PWD/r4i/log)"
  kill "$silent" 2>/dev/null || true

  # A whisper server is restarted (a deploy changed its unit, or it crashed):
  # the request that finds it gone waits for it, bounded by
  # LOCAL_STT_BACKEND_WAIT, and is answered by the new process.
  LOCAL_STT_BACKEND_WAIT=60 start_router r5; router5=$!
  wait_port 18768
  kill "$general"; wait "$general" 2>/dev/null || true
  LOCAL_STT_TEST_PORT=18768 ask EN-while-down > $PWD/r5/down & waiting=$!
  # The request has reached the router and found the server gone...
  for _ in $(seq 200); do grep -q 'not answering' $PWD/r5/log && break; sleep 0.05; done
  grep -q 'not answering' $PWD/r5/log \
    || fail "a request with the general model down was not held for it: $(cat $PWD/r5/log) $(cat $PWD/r5/down 2>/dev/null)"
  # ...and the server comes back.
  general=$(start_stub 18763 general)
  wait "$waiting"
  [ "$(status $PWD/r5/down)" = 200 ] && [ "$(text $PWD/r5/down)" = "general heard it" ] \
    || fail "a request that arrived while the general model was restarting: $(cat $PWD/r5/down)"

  # The server dies with the request in hand (no answer, connection gone):
  # the audio is sent again to the new process, and the caller gets the text.
  hold general
  LOCAL_STT_TEST_PORT=18768 ask EN-dropped > $PWD/r5/dropped & waiting=$!
  wait_asked general EN-dropped 1
  kill -KILL "$general"; wait "$general" 2>/dev/null || true
  general=$(start_stub 18763 general)
  wait_asked general EN-dropped 2
  release general
  wait "$waiting"
  [ "$(status $PWD/r5/dropped)" = 200 ] && [ "$(text $PWD/r5/dropped)" = "general heard it" ] \
    || fail "a request whose backend died under it: $(cat $PWD/r5/dropped)"
  kill -TERM "$router5"; wait "$router5" 2>/dev/null || true

  # The router's own restart. Under systemd the listening socket belongs to
  # local-stt.socket and is handed to each router process, so the port stays
  # open while one process stops and the next starts: a dictation that ends
  # in that moment waits in the socket's queue and is answered by the new
  # process. The holder stands in for systemd (same LISTEN_FDS protocol).
  mkdir -p $PWD/r6
  PPD_LOG=$PWD/r6/calls LOCAL_STT_PORT=18769 LOCAL_STT_THROTTLE_HINT=$PWD/r6/hint \
    python3 ${socketHolder} 18769 $PWD/r6 ${routerCommand} > $PWD/r6/log 2>&1 &
  holder=$!
  wait_port 18769
  touch $PWD/r6/start
  for _ in $(seq 100); do [ -s $PWD/r6/pid ] && break; sleep 0.05; done
  first=$(cat $PWD/r6/pid)
  LOCAL_STT_TEST_PORT=18769 LOCAL_STT_TEST_TIMEOUT=10 ask EN-hello > $PWD/r6/first
  [ "$(status $PWD/r6/first)" = 200 ] && [ "$(text $PWD/r6/first)" = "general heard it" ] \
    || fail "the router did not serve on the socket it was handed: $(cat $PWD/r6/first) $(cat $PWD/r6/log)"
  kill -TERM "$first"
  for _ in $(seq 100); do [ -s $PWD/r6/exited ] && break; sleep 0.1; done
  [ "$(cat $PWD/r6/exited)" = 0 ] || fail "the router on a handed socket did not stop cleanly: $(cat $PWD/r6/exited 2>/dev/null) $(cat $PWD/r6/log)"
  LOCAL_STT_TEST_PORT=18769 ask EN-queued > $PWD/r6/queued & queued=$!
  sleep 1
  kill -0 "$queued" 2>/dev/null || fail "a request sent between two router processes did not wait: $(cat $PWD/r6/queued)"
  touch $PWD/r6/start
  wait "$queued"
  [ "$(status $PWD/r6/queued)" = 200 ] && [ "$(text $PWD/r6/queued)" = "general heard it" ] \
    || fail "a request sent between two router processes: $(cat $PWD/r6/queued) $(cat $PWD/r6/log)"
  [ "$(cat $PWD/r6/pid)" != "$first" ] || fail "the queued request was not answered by a new router process"
  kill "$holder" "$(cat $PWD/r6/pid)" 2>/dev/null || true
  # Negative control: a router that binds its own port (as before) is simply
  # not there between two processes; the same request is refused.
  LOCAL_STT_TEST_PORT=18768 ask EN-refused > $PWD/r5/refused
  [ "$(status $PWD/r5/refused)" = 599 ] || fail "negative control: a stopped router's own port still answered: $(cat $PWD/r5/refused)"

  # Short-window model wedged (accepts, never answers): the clip is not held
  # for the backend's long timeout but handed to the full-window model.
  kill "$short"; wait "$short" 2>/dev/null || true
  short=$(start_stub 18762 short 60)
  wait_port 18762
  started=$SECONDS
  res=$(ask EN-hello "" "" 3)
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "short clip with the short-window model wedged: $res"
  [ $((SECONDS - started)) -lt 15 ] || fail "a wedged short-window model held a short clip for $((SECONDS - started)) s"

  # Short-window model down: short clips still answered, by the full-window
  # one, and at once. The short-window model is never waited for: the
  # full-window one gives the same text a second later.
  kill "$short"; wait "$short" 2>/dev/null || true
  started=$SECONDS
  res=$(ask EN-hello "" "" 3)
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "short clip with the short-window model down: $res"
  [ $((SECONDS - started)) -lt 3 ] || fail "a short clip waited $((SECONDS - started)) s for the short-window model instead of using the full window"

  # Swedish model down: Swedish audio still answered, by the general model,
  # once the Swedish one has had LOCAL_STT_BACKEND_WAIT seconds to come back.
  kill "$swedish"; wait "$swedish" 2>/dev/null || true
  res=$(ask SV-hej)
  [ "$(jq -r '.[0]' <<< "$res")" = 200 ] || fail "Swedish with its model down: $res"
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "fallback text: $res"
  # A model that stayed away is not waited for again: the wait is for a
  # restart, and every later request would otherwise pay it in full.
  started=$SECONDS
  res=$(ask EN-anything sv)
  [ "$(jq -r '.[1].text' <<< "$res")" = "general heard it" ] || fail "language=sv with its model down: $res"
  [ $((SECONDS - started)) -lt 3 ] || fail "a model known to be down was waited for again ($((SECONDS - started)) s)"
  # Back again, it is used again; nobody has to tell the router.
  swedish=$(start_stub 18764 swedish)
  wait_port 18764
  res=$(ask EN-anything sv)
  [ "$(jq -r '.[1].text' <<< "$res")" = "swedish heard it" ] || fail "the Swedish model came back and was not used: $res"

  # General model down: an error the caller can see.
  kill "$general"; wait "$general" 2>/dev/null || true
  res=$(ask EN-hello)
  [ "$(jq -r '.[0]' <<< "$res")" = 502 ] || fail "general model down: $res"

  kill "$router"
  echo "local-stt: all assertions passed"
  touch $out
''
