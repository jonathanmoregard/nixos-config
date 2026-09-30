# offline-ai: runtime-invocation harness for the deployed `offline-ai`
# wrapper and library server (modules/nixos/offline-ai.nix), run against a
# stub model server. No VM and no model: the stub plays the model's side of
# one conversation, asking for a fixed list of tools.
#
# What must hold, whatever the model is:
#   - a tool the model asks for is run and its result goes back to the model
#     (checked with a real option from the deployed option reference, so a
#     wrong store subpath in the wrapper fails here);
#   - a read outside the allowed roots is refused, and the refusal is fed
#     back as a tool result instead of ending the run;
#   - a tool name that does not exist is answered, not fatal;
#   - the same call made twice is not run twice (a small model can loop);
#   - a manual section that looks like a command-line option is refused;
#   - an answer that tells the operator to run one of the assistant's own
#     tools as a shell command is sent back once for a real answer;
#   - the library chain works end to end: the deployed serve script serves
#     a real ZIM archive, skipping a damaged one beside it, and a search
#     through the wrapper returns the article and its visible text only;
#   - an article path that climbs out of the library is refused;
#   - an HTML document in a collection is searchable by its visible text;
#   - the serve script fails with a message when no archive is readable;
#   - the archive fetcher puts a file in place only when it matches the
#     published checksum, continues a partial download instead of starting
#     over, keeps what arrived when the connection drops mid-file, and leaves
#     nothing behind for a corrupted one;
#   - a path such as `-delete` handed to big_files is a path, not a find
#     expression (nothing in the working directory is deleted);
#   - offline-AI mode: a conversation started in default mode stops only the
#     listed units that are running (timers first), loads the model, and on
#     the way out stops the model and starts exactly those units again, in
#     reverse order; `up` stays in the mode until `down`; a unit that will not
#     restart is remembered and reported; if the model cannot load, what was
#     stopped for it is started again;
#   - the model's final text reaches stdout.
#
# Run: nix build .#checks.x86_64-linux.offline-ai -L
{ pkgs, offlineAi, libraryServe, libraryFetch }:
let
  stub = pkgs.writeText "offline-ai-stub.py" ''
    import json, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer

    CALLS = [
        ("show_option", {"name": "networking.firewall.allowedTCPPorts"}),
        ("read_file", {"path": "/etc/shadow"}),
        ("no_such_tool", {}),
        ("search_library", {"query": "cantenna waveguide"}),
        ("read_article", {"article": "fixture_en_2026-01/antenna.html"}),
        ("read_article", {"article": "fixture_en_2026-01/../../etc/passwd"}),
        ("search_docs", {"query": "quillfeather", "collection": "guides"}),
        ("show_option", {"name": "networking.firewall.allowedTCPPorts"}),
        ("read_man", {"name": "ls", "section": "--version"}),
        ("big_files", {"path": "-delete", "min_mb": 0}),
    ]

    class Handler(BaseHTTPRequestHandler):
        turns = 0

        def log_message(self, *args):
            pass

        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"{}")

        def sse(self, delta):
            chunk = {"choices": [{"delta": delta}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            Handler.turns += 1
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            if Handler.turns == 1:
                for index, (name, arguments) in enumerate(CALLS):
                    # Arguments split across two chunks, as a real server streams them.
                    text = json.dumps(arguments)
                    self.sse({"tool_calls": [{"index": index, "id": f"c{index}",
                              "function": {"name": name, "arguments": text[:3]}}]})
                    self.sse({"tool_calls": [{"index": index, "function": {"arguments": text[3:]}}]})
            elif Handler.turns == 2:
                # An answer that hands one of the assistant's own tools to the operator.
                results = [m["content"] for m in body["messages"] if m["role"] == "tool"]
                with open(sys.argv[2], "w") as fh:
                    json.dump(results, fh)
                self.sse({"content": "Run this:\n```\nsudo big_files --min_mb 500\n```\n"})
            else:
                with open(sys.argv[2] + ".last", "w") as fh:
                    json.dump(body["messages"][-1], fh)
                self.sse({"content": "STUB FINAL "})
                self.sse({"content": "ANSWER"})
            self.wfile.write(b"data: [DONE]\n\n")

    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as fh:
        fh.write(str(server.server_address[1]))
    server.serve_forever()
  '';

  # A 48x48 grey PNG: zimwriterfs refuses to build an archive without one.
  illustration = pkgs.writeText "offline-ai-illustration.py" ''
    import struct, sys, zlib

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    raw = b"".join(b"\x00" + b"\x80" * 48 for _ in range(48))
    with open(sys.argv[1], "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 48, 48, 8, 0, 0, 0, 0))
                 + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))
  '';

  # A mirror: serves files from a folder, honours Range requests, and logs
  # the Range header of every request so the test can see a resume happen.
  mirror = pkgs.writeText "offline-ai-mirror.py" ''
    import os, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer

    ROOT, LOG = sys.argv[2], sys.argv[3]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            path = os.path.join(ROOT, self.path.lstrip("/"))
            with open(LOG, "a") as fh:
                fh.write(f"{self.path} range={self.headers.get('Range')}\n")
            if not os.path.isfile(path):
                self.send_error(404)
                return
            data = open(path, "rb").read()
            start = 0
            if self.headers.get("Range"):
                start = int(self.headers["Range"].split("=")[1].rstrip("-"))
                if start >= len(data):
                    self.send_error(416)
                    return
                self.send_response(206)
            else:
                self.send_response(200)
            self.send_header("Content-Length", str(len(data) - start))
            self.end_headers()
            # A *short* file is cut off after 40000 bytes, as a dropped connection would be.
            self.wfile.write(data[start:start + 40000] if "short" in path else data[start:])

    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as fh:
        fh.write(str(server.server_address[1]))
    server.serve_forever()
  '';

  # Stands in for systemctl in the mode scenarios: units are files in a state
  # folder (present = active), every call is logged, and units listed in
  # $FAKE_REFUSE refuse to start. Starting the model unit makes the model
  # stub report healthy; stopping it makes it unhealthy again.
  fakeSystemctl = pkgs.writeShellScript "systemctl" ''
    state="$FAKE_STATE"; scope=system
    [ "$1" = --user ] && { scope=user; shift; }
    verb=$1; shift; [ "$1" = -- ] && shift; unit=$1
    echo "$scope $verb $unit" >> "$state/calls"
    case "$verb" in
      is-active) if [ -e "$state/$scope/$unit" ]; then echo active; else echo inactive; exit 3; fi ;;
      stop) rm -f "$state/$scope/$unit"; [ "$unit" = offline-ai-llm.service ] && rm -f "$state/healthy"; exit 0 ;;
      start)
        case " $FAKE_REFUSE " in *" $unit "*) echo "refused $unit" >&2; exit 1 ;; esac
        touch "$state/$scope/$unit"; [ "$unit" = offline-ai-llm.service ] && touch "$state/healthy"; exit 0 ;;
      *) exit 0 ;;
    esac
  '';

  # A model server that is healthy only while the fake model unit runs.
  modeStub = pkgs.writeText "offline-ai-mode-stub.py" ''
    import json, os, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer

    STATE = sys.argv[2]

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            self.send_response(200 if os.path.exists(os.path.join(STATE, "healthy")) else 503)
            self.end_headers()

        def do_POST(self):
            self.rfile.read(int(self.headers["Content-Length"]))
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            chunk = {"choices": [{"delta": {"content": "MODE ANSWER"}}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\ndata: [DONE]\n\n")

    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as fh:
        fh.write(str(server.server_address[1]))
    server.serve_forever()
  '';

  freePort = pkgs.writeText "offline-ai-free-port.py" ''
    import socket
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        print(sock.getsockname()[1])
  '';
in
pkgs.runCommand "offline-ai-harness"
  {
    nativeBuildInputs = [ pkgs.python3 pkgs.jq pkgs.coreutils pkgs.zim-tools ];
  }
  ''
    fail() { echo "FAIL: $*"; for f in out.txt err.txt library.log; do [ -f "$f" ] && cat "$f"; done; exit 1; }

    export HOME="$PWD/home"
    mkdir -p "$HOME" config guides site zims broken
    echo '{ services.example.enable = true; }' > config/configuration.nix
    echo '<html><head><title>t</title><script>var hidden = "quillfeather-in-script";</script></head>
      <body><h1>Pens</h1><p>A quillfeather pen is cut from a goose feather.</p></body></html>' > guides/pens.html

    # A real archive, built here, plus a damaged copy beside it.
    echo '<html><head><title>Antennas</title></head><body><h1>Antennas</h1>
      <p>A cantenna is a directional waveguide antenna made from a tin can.</p>
      <script>var hidden = "scripttext";</script></body></html>' > site/antenna.html
    echo '<html><head><title>Home</title></head><body><a href="antenna.html">Antennas</a></body></html>' > site/index.html
    python3 ${illustration} site/icon.png
    zimwriterfs --welcome=index.html --illustration=icon.png --language=eng --title=Fixture \
      --description=fixture --creator=test --publisher=test --name fixture_en site zims/fixture_en_2026-01.zim > /dev/null \
      || fail "could not build the fixture archive"
    head -c 20000 zims/fixture_en_2026-01.zim > zims/damaged.zim
    head -c 20000 zims/fixture_en_2026-01.zim > broken/damaged.zim

    if OFFLINE_AI_ZIM_DIR="$PWD/broken" ${libraryServe}/bin/offline-ai-library-serve 2> broken.log; then
      fail "the library server started with no readable archive"
    fi
    grep -q 'no readable .zim archive' broken.log || fail "no message when no archive is readable"

    library_port=$(python3 ${freePort})
    OFFLINE_AI_ZIM_DIR="$PWD/zims" OFFLINE_AI_LIBRARY_PORT="$library_port" \
      ${libraryServe}/bin/offline-ai-library-serve > library.log 2>&1 &
    library_pid=$!
    python3 ${stub} port results.json &
    stub_pid=$!
    trap 'kill $stub_pid $library_pid 2>/dev/null || true' EXIT
    for _ in $(seq 1 50); do [ -s port ] && break; sleep 0.1; done
    [ -s port ] || fail "stub server did not start"

    export OFFLINE_AI_URL="http://127.0.0.1:$(cat port)"
    export OFFLINE_AI_LIBRARY_URL="http://127.0.0.1:$library_port"
    export OFFLINE_AI_CONFIG_ROOT="$PWD/config"
    export OFFLINE_AI_DOC_DIRS="guides=$PWD/guides"

    ready=""
    for _ in $(seq 1 50); do
      if ${offlineAi}/bin/offline-ai status 2> /dev/null | grep -q 'Fixture'; then ready=1; break; fi
      sleep 0.2
    done
    [ -n "$ready" ] || fail "the library server did not come up with the fixture archive"
    grep -q 'skipping unreadable archive: .*damaged.zim' library.log || fail "the damaged archive was not skipped"

    ${offlineAi}/bin/offline-ai "open a port" > out.txt 2> err.txt || fail "offline-ai exited non-zero"

    grep -q 'STUB FINAL ANSWER' out.txt || fail "final answer did not reach stdout"
    jq -e '.role == "user" and (.content | contains("big_files") and contains("Those are your tools"))' results.json.last > /dev/null \
      || fail "an answer giving a tool as a shell command was not sent back: $(cat results.json.last 2>/dev/null)"
    [ "$(jq length results.json)" = 10 ] || fail "expected ten tool results to reach the model"
    [ -f config/configuration.nix ] || fail "big_files with path -delete deleted files in the working directory"
    jq -e '.[0] | contains("networking.firewall.allowedTCPPorts") and contains("type:")' results.json > /dev/null \
      || fail "option lookup did not return the deployed option reference"
    jq -e '.[1] | contains("outside the readable roots")' results.json > /dev/null \
      || fail "a read outside the allowed roots was not refused"
    jq -e '.[1] | contains("root:") | not' results.json > /dev/null \
      || fail "file content from outside the allowed roots reached the model"
    jq -e '.[2] | contains("unknown tool")' results.json > /dev/null \
      || fail "an unknown tool name was not reported back"
    jq -e '.[3] | contains("article: fixture_en_2026-01/antenna.html")' results.json > /dev/null \
      || fail "library search did not return the article: $(jq '.[3]' results.json)"
    jq -e '.[4] | contains("directional waveguide") and (contains("scripttext") | not)' results.json > /dev/null \
      || fail "article text was not returned as visible text only: $(jq '.[4]' results.json)"
    jq -e '.[5] | contains("not an article path")' results.json > /dev/null \
      || fail "an article path leaving the library was not refused: $(jq '.[5]' results.json)"
    jq -e '.[6] | contains("guides/pens.html") and contains("goose feather") and (contains("in-script") | not)' results.json > /dev/null \
      || fail "the HTML document was not searchable by its visible text: $(jq '.[6]' results.json)"

    jq -e '.[7] | contains("already made this exact call")' results.json > /dev/null \
      || fail "a repeated identical tool call was run again: $(jq '.[7]' results.json)"

    jq -e '.[8] | contains("not a manual section")' results.json > /dev/null \
      || fail "an option-like manual section reached man: $(jq '.[8]' results.json)"

    # --- archive fetcher, against a local mirror
    mkdir -p mirror fetched
    head -c 300000 /dev/urandom > mirror/good_2026-01.zim
    head -c 300000 /dev/urandom > mirror/corrupt_2026-01.zim
    head -c 300000 /dev/urandom > mirror/short_2026-01.zim
    (cd mirror && sha256sum short_2026-01.zim > short_2026-01.zim.sha256)
    (cd mirror && sha256sum good_2026-01.zim > good_2026-01.zim.sha256)
    echo "$(printf '0%.0s' $(seq 1 64))  corrupt_2026-01.zim" > mirror/corrupt_2026-01.zim.sha256
    python3 ${mirror} mirror_port "$PWD/mirror" "$PWD/mirror.log" &
    mirror_pid=$!
    trap 'kill $stub_pid $library_pid $mirror_pid 2>/dev/null || true' EXIT
    for _ in $(seq 1 50); do [ -s mirror_port ] && break; sleep 0.1; done
    [ -s mirror_port ] || fail "mirror did not start"
    base="http://127.0.0.1:$(cat mirror_port)"
    {
      echo "- {id: good, type: kiwix, title: Good, fetch: core, size: 300K, url: \"$base/good_2026-01.zim\"}"
      echo "- {id: corrupt, type: kiwix, title: Corrupt, fetch: core, size: 300K, url: \"$base/corrupt_2026-01.zim\"}"
      echo "- {id: optional, type: kiwix, title: Optional, fetch: optional, url: \"$base/missing_2026-01.zim\"}"
      echo "- {id: short, type: kiwix, title: Short, fetch: core, url: \"$base/short_2026-01.zim\"}"
      echo "- {id: byhand, type: kiwix, title: By hand, url: \"\"}"
      echo "- {id: book, type: pdf, title: Not an archive, url: \"$base/book.pdf\"}"
    } > sources.yaml
    export OFFLINE_AI_SOURCES="$PWD/sources.yaml" OFFLINE_AI_ZIM_DIR="$PWD/fetched"

    # A third of the good archive is already there from an interrupted run.
    head -c 100000 mirror/good_2026-01.zim > fetched/good_2026-01.zim.part

    if ${offlineAi}/bin/offline-ai library fetch > fetch.log 2>&1; then
      cat fetch.log; fail "the fetcher reported success although one archive is corrupt"
    fi
    cmp -s mirror/good_2026-01.zim fetched/good_2026-01.zim \
      || { cat fetch.log mirror.log; fail "the good archive was not fetched intact"; }
    grep -q 'good_2026-01.zim range=bytes=100000-' mirror.log \
      || { cat mirror.log; fail "the partial download was restarted instead of continued"; }
    if ls fetched | grep -q corrupt; then ls fetched; fail "a corrupted download was left in the archive folder"; fi
    if grep -q 'missing_2026-01' mirror.log; then fail "an optional archive was fetched without --all"; fi
    if grep -q 'book.pdf' mirror.log; then fail "a non-archive source was fetched"; fi
    [ "$(stat -c %s fetched/short_2026-01.zim.part 2>/dev/null)" = 40000 ] \
      || { ls -l fetched; cat fetch.log; fail "a dropped connection lost the bytes that had arrived"; }
    [ ! -e fetched/short_2026-01.zim ] || fail "an incomplete archive was put in place"
    grep -q 'short_2026-01.zim: connection ended' fetch.log || { cat fetch.log; fail "a dropped connection was not reported"; }

    # --- offline-AI mode, with systemctl replaced by a fake. The deployed
    # script is run directly: the wrapper would put the real systemctl first.
    script=$(grep -o '/nix/store/[^ ]*-offline-ai.py' ${offlineAi}/bin/offline-ai | head -1)
    [ -n "$script" ] || fail "could not find the script in the wrapper"
    mkdir -p fakebin mode/system mode/user
    ln -s ${fakeSystemctl} fakebin/systemctl
    export FAKE_STATE="$PWD/mode"
    python3 ${modeStub} mode_port "$PWD/mode" &
    mode_pid=$!
    trap 'kill $stub_pid $library_pid $mirror_pid $mode_pid 2>/dev/null || true' EXIT
    for _ in $(seq 1 50); do [ -s mode_port ] && break; sleep 0.1; done
    reset_units() {
      rm -rf mode/system mode/user mode/calls mode/healthy; mkdir -p mode/system mode/user
      touch mode/system/a.timer mode/system/b.service mode/user/d.service   # c.service is not running
    }
    mode() {
      env PATH="$PWD/fakebin:$PATH" XDG_RUNTIME_DIR="$PWD/run" \
        OFFLINE_AI_URL="http://127.0.0.1:$(cat mode_port)" OFFLINE_AI_LIBRARY_URL="http://127.0.0.1:9" \
        OFFLINE_AI_UNIT=offline-ai-llm.service OFFLINE_AI_MODEL="''${MODE_MODEL:-}" \
        OFFLINE_AI_EVICT_SYSTEM="a.timer b.service" OFFLINE_AI_EVICT_USER="c.service d.service" \
        python3 "$script" "$@"
    }
    calls() { grep -E ' (stop|start) ' mode/calls | tr '\n' ';'; }

    reset_units
    mode "is the disk full" > mode.out 2> mode.err || { cat mode.out mode.err; fail "a conversation in offline-AI mode failed"; }
    grep -q 'MODE ANSWER' mode.out || fail "no answer in offline-AI mode"
    expected="system stop a.timer;system stop b.service;user stop d.service;user start offline-ai-llm.service;user start offline-ai-library.service;user stop offline-ai-library.service;user stop offline-ai-llm.service;user start d.service;system start b.service;system start a.timer;"
    [ "$(calls)" = "$expected" ] || { cat mode.err; fail "mode switch order wrong: $(calls)"; }
    [ ! -e run/offline-ai/evicted.json ] || fail "the record of stopped units survived a clean return to default mode"

    reset_units
    mode up > up.out 2>&1 || { cat up.out; fail "offline-ai up failed"; }
    grep -q 'mode: offline-AI, stopped for it: a.timer, b.service, d.service' up.out || { cat up.out; fail "status does not show the mode"; }
    [ ! -e mode/system/b.service ] || fail "up did not stop the listed units"
    mode "still here" > /dev/null 2>&1 || fail "a question while already up failed"
    [ ! -e mode/system/b.service ] || fail "a conversation after up ended offline-AI mode"
    FAKE_REFUSE="b.service" mode down > down.out 2>&1 && fail "down reported success although a unit did not restart"
    grep -q 'could not restart b.service' down.out || { cat down.out; fail "a unit that did not restart was not reported"; }
    [ -e mode/system/a.timer ] && [ -e mode/user/d.service ] || fail "down did not restart the units that could start"
    jq -e '. == [[false, "b.service"]]' run/offline-ai/evicted.json > /dev/null || fail "the unit that did not restart was not remembered"
    mode down > /dev/null 2>&1 || fail "a second down did not restart the remembered unit"
    [ -e mode/system/b.service ] && [ ! -e run/offline-ai/evicted.json ] || fail "the remembered unit was not restarted"

    reset_units
    MODE_MODEL=/nonexistent/model.gguf mode "anything" > nomodel.out 2>&1 && fail "a missing model did not fail"
    [ -e mode/system/a.timer ] && [ -e mode/system/b.service ] && [ -e mode/user/d.service ] \
      || { cat nomodel.out; fail "units stopped for a model that could not load were not restarted"; }

    mkdir -p "$out"
    echo 'offline-ai harness passed' > "$out/result"
  ''
