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
#     stopped for it is started again; when that is not enough, the user's
#     other large units (never desktop applications) are frozen, largest
#     first, only until the model fits, and thawed on the way out or when the
#     model still cannot load;
#   - the model's final text reaches stdout;
#   - tool output is budgeted: one result is capped with a tail that counts
#     what was left out, and once the retained results outgrow the budget
#     the oldest become stubs naming the call while the newest stay whole;
#   - a reply the server cut off at the context limit is announced on both
#     streams and never leaves stdout empty with exit 0 (it exits 2);
#   - swap is counted as the RAM it frees: a swap file one for one, zram at
#     its compression ratio, bounded by free swap and anonymous memory, and
#     the "will move to swap" message reports what really moves;
#   - two models: a run loads the default (small) model's unit unless --model
#     names the other; selecting the other while one is loaded stops the
#     loaded one (its marker with it) before the other starts; a conversation
#     while the mode is on only switches models and leaves the model it
#     loaded, one from default mode leaves nothing loaded; `down` stops every
#     model unit and clears every marker; an unknown --model exits 1 naming
#     the models; a missing model names its own fetch hint; status and
#     models name the loaded model; without OFFLINE_AI_DEFAULT_MODEL the
#     default is `small`, not whichever name sorts first; a switch to a
#     model that is not on disk stops nothing and leaves the loaded model
#     and the mode as they were. And, read from the deployed units: each
#     model unit names the other in Conflicts= and in After= (Conflicts=
#     alone orders nothing: with the ordering, systemd runs the stop job
#     before the start job, so a by-hand start of the other unit cannot run
#     both servers at once), and the gated units refuse to start while
#     either model's marker stands;
#   - the help text is a complete reference: every command the CLI
#     dispatches on, every option its parser defines, every model (with its
#     line and fetch hint), the default, and the exit statuses — the
#     expected list read from the script, so a command or option added
#     without a line of help fails here.
#
# Run: nix build .#checks.x86_64-linux.offline-ai -L
{ pkgs, offlineAi, libraryServe, libraryFetch
, conflicts ? { }               # model name -> Conflicts= of its deployed unit (string or list)
, after ? { }                   # model name -> After= of its deployed unit (string or list)
, gatedUserDropIn ? ""          # the drop-in text one gated user service carries
, gatedSystemConditions ? [ ]   # ConditionPathExists= of one gated system unit
}:
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
  # $FAKE_REFUSE refuse to start. Starting a model unit makes the model stub
  # report healthy; stopping it makes it unhealthy again. Two model units,
  # each with its own reservation and marker file: the small model's
  # (mode/marker) and the coder's (mode/marker-coder). No Conflicts= here:
  # the CLI itself must stop the loaded model before it starts the other,
  # or the fake keeps the first unit active.
  fakeSystemctl = pkgs.writeShellScript "systemctl" ''
    state="$FAKE_STATE"; scope=system
    [ "$1" = --user ] && { scope=user; shift; }
    verb=$1; shift; [ "$1" = -- ] && shift; unit=$1
    [ "$verb" = show ] && unit=''${*: -1}
    echo "$scope $verb $unit" >> "$state/calls"
    marker_of() {
      case "$1" in
        offline-ai-llm.service|memory-reserve-offline-ai.service) echo "$state/marker" ;;
        offline-ai-llm-coder.service|memory-reserve-offline-ai-coder.service) echo "$state/marker-coder" ;;
      esac
    }
    is_model() { case "$1" in offline-ai-llm.service|offline-ai-llm-coder.service) return 0 ;; *) return 1 ;; esac; }
    any_marker() { [ -e "$state/marker" ] || [ -e "$state/marker-coder" ]; }
    case "$verb" in
      is-active) if [ -e "$state/$scope/$unit" ]; then echo active; else echo inactive; exit 3; fi ;;
      show)
        case " $* " in
          *" LoadState "*) [ -e "$state/gone/$unit" ] && echo not-found || echo loaded ;;
          # A gated unit started while a marker stands was refused by its condition.
          *" ConditionResult "*) any_marker && [ -e "$state/gated/$unit" ] && echo no || echo yes ;;
          *) [ -e "$state/transient/$unit" ] && echo yes || echo no ;;
        esac
        exit 0 ;;
      stop)
        # A model unit that was running stops answering.
        if is_model "$unit" && [ -e "$state/$scope/$unit" ]; then rm -f "$state/healthy"; fi
        rm -f "$state/$scope/$unit"
        # The model unit's ExecStopPost stops its reservation, which removes
        # its marker; FAKE_STICKY_MARKER=1 is that stop failing, =2 the
        # reservation refusing to stop at all.
        marker=$(marker_of "$unit")
        if is_model "$unit" && [ "''${FAKE_STICKY_MARKER:-0}" = 0 ]; then rm -f "$marker"; fi
        case "$unit" in memory-reserve-*) [ "''${FAKE_STICKY_MARKER:-0}" != 2 ] && rm -f "$marker" ;; esac
        # Stopping a unit that holds GPU memory gives that memory back.
        if [ -e "$state/gpu/$unit" ]; then
          avail=$(sed -n 's/^MemAvailable: *\([0-9]*\) kB/\1/p' "$FAKE_MEMINFO")
          sed -i "s/^MemAvailable:.*/MemAvailable:   $((avail + $(cat "$state/gpu/$unit"))) kB/" "$FAKE_MEMINFO"
        fi
        exit 0 ;;
      start)
        case " $FAKE_REFUSE " in *" $unit "*) echo "refused $unit" >&2; exit 1 ;; esac
        # ConditionPathExists=!marker (one line per model): start returns 0 and does nothing.
        if any_marker && [ -e "$state/gated/$unit" ]; then exit 0; fi
        touch "$state/$scope/$unit"
        if is_model "$unit"; then
          # ExecStartPre starts the reservation (the marker), unless it fails;
          # the server becomes healthy, unless it never does.
          [ "''${FAKE_NO_MARKER:-0}" = 1 ] || touch "$(marker_of "$unit")"
          [ "''${FAKE_NEVER_HEALTHY:-0}" = 1 ] || touch "$state/healthy"
        fi
        exit 0 ;;
      freeze|thaw)
        # A frozen unit's memory goes to swap: it adds to MemAvailable in the
        # fake meminfo, and thawing takes it back.
        dir=$(find "$FAKE_CGROUP" -type d -name "$unit" | head -1)
        [ -n "$dir" ] || { echo "no such unit $unit" >&2; exit 1; }
        anon=$(cat "$dir/memory.current")
        avail=$(sed -n 's/^MemAvailable: *\([0-9]*\) kB/\1/p' "$FAKE_MEMINFO")
        if [ "$verb" = freeze ]; then echo 1 > "$dir/cgroup.freeze"; avail=$((avail + anon / 1024))
        else echo 0 > "$dir/cgroup.freeze"; avail=$((avail - anon / 1024)); fi
        sed -i "s/^MemAvailable:.*/MemAvailable:   $avail kB/" "$FAKE_MEMINFO"; exit 0 ;;
      *) exit 0 ;;
    esac
  '';

  # The manager's view of a transient unit, as busctl prints it, and a
  # systemd-run that records how it was asked to recreate one.
  fakeBusctl = pkgs.writeShellScript "busctl" ''
    echo '{"type":"a(sasbttttuii)","data":[["/bin/llama",["/bin/llama","-m","a model.gguf"],false,0,0,0,0,0,0,0]]}'
    echo '{"type":"as","data":["A=1","B=two words"]}'
    echo '{"type":"s","data":"!/srv"}'
    echo '{"type":"s","data":"app.slice"}'
  '';
  fakeSystemdRun = pkgs.writeShellScript "systemd-run" ''
    printf '%s\n' "$@" > "$FAKE_STATE/relaunched"
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

  # A model asked how to treat a burn: it searches the documents, then answers
  # without naming a source ("nocite", every time) or with one ("cite"). It
  # records whether it was sent back to cite. In "exhaust" mode it keeps
  # looking things up until the CLI runs out of steps and forces an answer
  # (a request without tools), then answers without a source.
  citeStub = pkgs.writeText "offline-ai-cite-stub.py" ''
    import json, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer

    MODE, LOG = sys.argv[2], sys.argv[3]

    class Handler(BaseHTTPRequestHandler):
        turns = 0

        def log_message(self, *args):
            pass

        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"{}")

        def sse(self, delta):
            self.wfile.write(b"data: " + json.dumps({"choices": [{"delta": delta}]}).encode() + b"\n\n")

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            Handler.turns += 1
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            if Handler.turns == 1 or (MODE == "exhaust" and "tools" in body):
                self.sse({"tool_calls": [{"index": 0, "id": "c%d" % Handler.turns, "function": {
                    "name": "search_docs", "arguments": json.dumps({"query": "burn cool water %d" % Handler.turns, "collection": "guides"})}}]})
            else:
                last = body["messages"][-1]
                with open(LOG, "a") as fh:
                    fh.write(json.dumps({"turn": Handler.turns, "role": last["role"], "content": last["content"]}) + "\n")
                cite = MODE == "cite"
                self.sse({"content": "Cool the burn under running water for 20 minutes."
                          + ("\nSources: burns, page 1" if cite else "")})
            self.wfile.write(b"data: [DONE]\n\n")

    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as fh:
        fh.write(str(server.server_address[1]))
    server.serve_forever()
  '';

  # A model that reads a long file three times, a slice per turn, and then
  # runs out of context: its last reply is empty and the server reports
  # finish_reason "length" (what llama-server sends when the context fills).
  # Every request's message list is logged, one JSON line per turn.
  budgetStub = pkgs.writeText "offline-ai-budget-stub.py" ''
    import json, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer

    LOG = sys.argv[2]

    class Handler(BaseHTTPRequestHandler):
        turns = 0

        def log_message(self, *args):
            pass

        def do_GET(self):
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"{}")

        def sse(self, delta, finish=None):
            chunk = {"choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(b"data: " + json.dumps(chunk).encode() + b"\n\n")

        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            Handler.turns += 1
            with open(LOG, "a") as fh:
                fh.write(json.dumps(body["messages"]) + "\n")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            if Handler.turns <= 3:
                arguments = json.dumps({"path": "big.nix", "start": 1 + 200 * (Handler.turns - 1), "lines": 200})
                self.sse({"tool_calls": [{"index": 0, "id": f"c{Handler.turns}",
                          "function": {"name": "read_file", "arguments": arguments}}]}, "tool_calls")
            else:
                self.sse({}, "length")
            self.wfile.write(b"data: [DONE]\n\n")

    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as fh:
        fh.write(str(server.server_address[1]))
    server.serve_forever()
  '';

  # Swap accounting as a pure function of /proc/swaps, AnonPages and the zram
  # mm_stat files: a disk swap area frees RAM one for one; a zram area is RAM
  # itself and frees only what compression saves; what is free in swap and
  # what there is to swap both bound it; zram fills first (priority).
  # The citation gate's rules, on the functions themselves: what counts as a
  # safety question, what counts as a Sources line, what a name must match.
  # Each row is a way the gate was shown to be fooled or to misfire
  # (close-out review, 2026-10-02).
  citeUnit = pkgs.writeText "offline-ai-cite-unit.py" ''
    import importlib.util, sys

    spec = importlib.util.spec_from_file_location("offline_ai", sys.argv[1])
    oai = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(oai)

    failed = []
    def check(label, cond):
        if not cond:
            failed.append(label)

    for q in ("jag har bränt mig på handen", "jag brände mig", "han har brutit armen",
              "min son har 39 graders feber", "fick en stöt av kabeln", "how do I treat a burn",
              "is it safe to run a petrol generator in the garage"):
        check("safety question not recognised: " + q, oai.SAFETY.search(q))
    for q in ("why does my systemd generator unit fail", "temp pause autodoro",
              "long boot list, limit to 8", "print both sides", "ingest failed"):
        check("sysadmin question taken for a safety one: " + q, not oai.SAFETY.search(q))

    doc = {"where_there_is_no_doctor"}
    check("prose opening with 'Sources of' passed as a citation line",
          not oai.cited("Sources of infection are dirt.\nSee where there is no doctor, page 96.", doc))
    check("a Sources: line naming the retrieved document is a citation",
          oai.cited("Cool it.\n\nSources: Where There Is No Doctor, page 96", doc))
    check("a bold **Källor:** line is a citation",
          oai.cited("Kyl.\n**Källor:** Where there is no doctor s. 76", doc))
    check("'burn' does not vouch for a retrieved 'burns'",
          not oai.cited("Sources: burn", {"burns"}))
    check("a Sources line naming nothing retrieved is not a citation",
          not oai.cited("Sources: Mayo Clinic", doc))

    if failed:
        print("citation rules:\n  " + "\n  ".join(failed), file=sys.stderr)
        sys.exit(1)
    print("citation rules ok")
  '';

  # The help text as a reference. The expected words come from the script
  # itself: the commands it dispatches on (COMMANDS), the option strings its
  # parser defines (build_parser), the model names in its table; plus the
  # default marked, the two-word library form, the exit statuses, and each
  # model's line and fetch hint. A word counts only as a whole word.
  helpUnit = pkgs.writeText "offline-ai-help-unit.py" ''
    import importlib.util, re, sys

    spec = importlib.util.spec_from_file_location("oai", sys.argv[1])
    oai = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(oai)
    for name in ("COMMANDS", "build_parser", "usage"):
        if not hasattr(oai, name):
            sys.exit(f"the CLI has no {name} to derive the help reference from")
    text = oai.usage()
    expected = list(oai.COMMANDS) + list(oai.MODELS)
    expected += [flag for action in oai.build_parser()._actions for flag in action.option_strings]
    missing = [word for word in expected
               if not re.search(r"(?<![\w-])" + re.escape(word) + r"(?![\w-])", text)]
    for needle, what in ((oai.DEFAULT_MODEL + " (default)", "which model is the default"),
                         ("library fetch", "the two-word library form"),
                         ("Exit status", "the exit statuses")):
        if needle not in text:
            missing.append(what)
    for name, entry in oai.MODELS.items():
        for key in ("about", "fetch"):
            if entry.get(key) and entry[key] not in text:
                missing.append(f"the {name} model's {key}")
    if missing:
        sys.exit("the help text lacks: " + ", ".join(missing))
    print("help reference ok")
  '';

  swapUnit = pkgs.writeText "offline-ai-swap-unit.py" ''
    import importlib.util, sys

    spec = importlib.util.spec_from_file_location("offline_ai", sys.argv[1])
    oai = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(oai)

    G = 2**30
    HEAD = "Filename\tType\tSize\tUsed\tPriority\n"
    FILE = "/var/lib/swapfile file %d %d -2\n"
    ZRAM = "/dev/zram0 partition %d %d 5\n"
    KIB = 1024
    stats = {}
    mm_stat = lambda name: stats.get(name)

    def swappable(swaps, anon):
        return oai.swappable_bytes(anon=anon * G, areas=oai.swap_areas(swaps, mm_stat))

    def check(label, got, want):
        if got != want * G:
            sys.exit(f"FAIL: {label}: {got / G:.2f} GiB, expected {want} GiB")

    # file only: 16 GiB free in the file, 20 GiB of anonymous memory: 16 GiB can go.
    check("file only", swappable(HEAD + FILE % (16 * G // KIB, 0), 20), 16)
    # file only, nearly full: 2 GiB of 16 left.
    check("file nearly full", swappable(HEAD + FILE % (16 * G // KIB, 14 * G // KIB), 20), 2)
    # zram only, ratio 4 (mm_stat: 4 bytes in for every 1 kept): 32 GiB free, 20 GiB of
    # anonymous memory: all 20 GiB fit, and each GiB swapped frees 3/4 GiB.
    stats["zram0"] = "4000000 1000000 1100000 0 2000000 0 0 0 0"
    check("zram only", swappable(HEAD + ZRAM % (32 * G // KIB, 0), 20), 15)
    # zram only, swap the bound: 8 GiB free at ratio 4 frees 6 GiB however much there is.
    check("zram bound by its size", swappable(HEAD + ZRAM % (32 * G // KIB, 24 * G // KIB), 20), 6)
    # empty zram (nothing compressed yet): ratio 2 assumed, so half of what goes in is freed.
    stats["zram0"] = "0 0 0 0 0 0 0 0 0"
    check("empty zram", swappable(HEAD + ZRAM % (32 * G // KIB, 0), 10), 5)
    # mm_stat unreadable: the same assumption.
    del stats["zram0"]
    check("zram without mm_stat", swappable(HEAD + ZRAM % (32 * G // KIB, 0), 10), 5)
    # mixed: zram (priority 5) fills before the file (priority -2). 8 GiB free in zram at
    # ratio 2 frees 4 GiB; the file takes the remaining 4 GiB of 12 GiB of anonymous memory.
    stats["zram0"] = "2000000 1000000 1100000 0 2000000 0 0 0 0"
    mixed = HEAD + ZRAM % (32 * G // KIB, 24 * G // KIB) + FILE % (16 * G // KIB, 0)
    check("mixed", swappable(mixed, 12), 8)
    # how much must move to free 6 GiB with that mix: 8 GiB into zram frees 4, then 2 GiB into the file.
    check("to free 6 GiB, mixed", oai.swap_needed(6 * G, 12 * G, oai.swap_areas(mixed, mm_stat)), 10)
    # no swap at all
    check("no swap", swappable(HEAD, 20), 0)
    print("swap accounting ok")
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
    nativeBuildInputs = [ pkgs.python3 pkgs.jq pkgs.coreutils pkgs.zim-tools pkgs.findutils pkgs.gnused ];
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

    # --- a medical answer must cite a stored reference the tools returned:
    # without one it is sent back once, and if it still names none it is
    # marked NOT VERIFIED; with one it goes through untouched.
    echo '<html><head><title>Burns</title></head><body><h1>Burns</h1>
      <p>Cool a burn under cool running water for 20 minutes.</p></body></html>' > guides/burns.html
    for mode in nocite cite exhaust; do
      rm -f cite_port
      python3 ${citeStub} cite_port "$mode" "$PWD/cite-$mode.log" &
      cite_pid=$!
      for _ in $(seq 1 50); do [ -s cite_port ] && break; sleep 0.1; done
      OFFLINE_AI_URL="http://127.0.0.1:$(cat cite_port)" ${offlineAi}/bin/offline-ai "how do I treat a burn" \
        > "cite-$mode.out" 2> "cite-$mode.err" || { cat "cite-$mode.err"; fail "the burn question ($mode) failed"; }
      kill $cite_pid
    done
    [ "$(grep -c '"role": "user"' cite-cite.log)" = 0 ] || fail "a cited medical answer was sent back"
    if grep -q 'NOT VERIFIED' cite-cite.out; then fail "a cited medical answer was marked not verified"; fi
    grep -q 'NOT VERIFIED' cite-nocite.out || { cat cite-nocite.out; fail "an uncited medical answer was not marked"; }
    grep -q 'revising: a medical or electrical answer' cite-nocite.out || fail "an uncited medical answer was not sent back first"
    grep -q 'burns' cite-nocite.out || fail "the warning does not name the reference that was retrieved"
    # The answer forced out after the step limit goes through the same gate:
    # it is the one most likely to be uncited, and it must not pass as checked.
    grep -q 'Stop looking things up' cite-exhaust.log || fail "the exhaust stub was never forced to answer: $(cat cite-exhaust.log)"
    grep -q 'NOT VERIFIED' cite-exhaust.out || { cat cite-exhaust.out; fail "an uncited answer forced after the step limit was not marked"; }
    if grep -q 'revising: a medical or electrical answer' cite-exhaust.out; then fail "the forced answer was sent back although no steps were left"; fi

    # --- the gate's own rules, on the functions themselves.
    python3 ${citeUnit} "$(grep -o '/nix/store/[^ ]*-offline-ai.py' ${offlineAi}/bin/offline-ai | head -1)" \
      || fail "citation rules"

    # --- tool output is budgeted so a long conversation stays inside the
    # model's context: one result is capped, and its tail says how much was
    # left out and what to do; once the retained results exceed the budget
    # the oldest give way to a stub naming the call, the newest stay whole
    # and the model's own turns are untouched; a reply cut off by the context
    # limit (empty, finish_reason "length") is said so on both streams, and
    # the run exits 2 rather than 0 with nothing to show.
    seq -f 'filler line %g: the quick brown fox jumps over the lazy dog, again and again' 1 600 > config/big.nix
    rm -f budget_port budget.log
    python3 ${budgetStub} budget_port "$PWD/budget.log" &
    budget_pid=$!
    for _ in $(seq 1 50); do [ -s budget_port ] && break; sleep 0.1; done
    rc=0
    OFFLINE_AI_URL="http://127.0.0.1:$(cat budget_port)" OFFLINE_AI_TOOL_BUDGET_CHARS=9000 \
      ${offlineAi}/bin/offline-ai "read the big file" > budget.out 2> budget.err || rc=$?
    kill $budget_pid
    [ "$(wc -l < budget.log)" = 4 ] || { cat budget.err; fail "expected four model turns in the budget scenario, got $(wc -l < budget.log)"; }
    first=$(sed -n 2p budget.log | jq '[.[] | select(.role == "tool")][0].content')
    jq -e 'length < 6200 and contains("1: filler line 1:") and (contains("filler line 200:") | not)
           and contains("more characters not shown") and contains("narrower")' <<< "$first" > /dev/null \
      || fail "a long tool result was not capped with a tail saying what was left out: $(tail -c 300 <<< "$first")"
    header="$PWD/config/big.nix (lines 1-200 of 600)"
    body=$(python3 -c 'print(sum(len(f"{i}: filler line {i}: the quick brown fox jumps over the lazy dog, again and again") + 1 for i in range(1, 201)) - 1)')
    omitted=$(jq -r 'capture("(?<n>[0-9]+) more characters not shown").n' <<< "$first")
    [ "$((6000 + omitted))" = "$((''${#header} + 1 + body))" ] \
      || fail "the tail miscounts what was left out: 6000 kept + $omitted omitted != $((''${#header} + 1 + body))"
    tools=$(sed -n 4p budget.log | jq '[.[] | select(.role == "tool")]')
    jq -e 'length == 3' <<< "$tools" > /dev/null || fail "expected three tool results in the fourth request"
    jq -e '.[0].content | startswith("[read_file") and contains("big.nix") and contains("start=1")
           and contains("dropped to save context") and (contains("filler line") | not)' <<< "$tools" > /dev/null \
      || fail "the oldest tool result over the budget was not replaced by a stub naming the call: $(jq '.[0].content' <<< "$tools")"
    jq -e '.[1].content | contains("start=201") and contains("dropped to save context") and (contains("filler line") | not)' <<< "$tools" > /dev/null \
      || fail "the second-oldest tool result over the budget was not dropped: $(jq '.[1].content | .[:200]' <<< "$tools")"
    jq -e '.[2].content | contains("401: filler line 401:") and contains("more characters not shown")' <<< "$tools" > /dev/null \
      || fail "the newest tool result was not kept whole: $(jq '.[2].content | .[:200]' <<< "$tools")"
    sed -n 4p budget.log | jq -e '[.[] | select(.role == "assistant")] | length == 3 and all(.tool_calls | length == 1)' > /dev/null \
      || fail "the model's own turns did not stay intact"
    [ "$rc" = 2 ] || { cat budget.out budget.err; fail "a reply cut off by the context limit exited $rc, not 2"; }
    grep -qi 'cut off' budget.out || { cat budget.out; fail "stdout does not say the answer was cut off"; }
    grep -qi 'narrower' budget.out || fail "stdout does not say what to try after a cut-off answer"
    grep -qi 'context' budget.err || { cat budget.err; fail "no notice on stderr about the context limit"; }

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
    ln -s ${fakeBusctl} fakebin/busctl
    ln -s ${fakeSystemdRun} fakebin/systemd-run
    export FAKE_STATE="$PWD/mode"
    python3 ${modeStub} mode_port "$PWD/mode" &
    mode_pid=$!
    trap 'kill $stub_pid $library_pid $mirror_pid $mode_pid 2>/dev/null || true' EXIT
    for _ in $(seq 1 50); do [ -s mode_port ] && break; sleep 0.1; done
    reset_units() {
      rm -rf mode/system mode/user mode/calls mode/healthy mode/marker mode/marker-coder mode/gated; mkdir -p mode/system mode/user mode/gated
      touch mode/system/a.timer mode/system/b.service mode/user/d.service   # c.service is not running
      touch mode/gated/d.service mode/gated/b.service   # these carry ConditionPathExists=!marker
    }
    mode() {
      env PATH="$PWD/fakebin:$PATH" XDG_RUNTIME_DIR="$PWD/run" \
        OFFLINE_AI_URL="http://127.0.0.1:$(cat mode_port)" OFFLINE_AI_LIBRARY_URL="http://127.0.0.1:9" \
        OFFLINE_AI_UNIT=offline-ai-llm.service OFFLINE_AI_MODEL="''${MODE_MODEL:-}" \
        OFFLINE_AI_MODE_MARKER="$PWD/mode/marker" OFFLINE_AI_RESERVATION=memory-reserve-offline-ai.service \
        OFFLINE_AI_READY_TIMEOUT="''${MODE_READY:-900}" \
        OFFLINE_AI_EVICT_SYSTEM="a.timer b.service" OFFLINE_AI_EVICT_USER="c.service d.service" \
        OFFLINE_AI_MEMINFO="$PWD/meminfo" OFFLINE_AI_SWAPS="$PWD/swaps" OFFLINE_AI_SYS_BLOCK="$PWD/sysblock" \
        OFFLINE_AI_USER_CGROUP="$PWD/cg/user@1000.service" \
        OFFLINE_AI_CGROUP_ROOT="$PWD/cg" OFFLINE_AI_PROC="$PWD/proc" \
        python3 "$script" "$@"
    }
    calls() { grep -E ' (stop|start) ' mode/calls | tr '\n' ';'; }
    # A user manager's cgroup tree: a desktop application, a large agent job,
    # a mid-sized service and a small one. Plenty of memory unless a scenario
    # says otherwise. No process in /proc holds GPU memory yet.
    export FAKE_CGROUP="$PWD/cg" FAKE_MEMINFO="$PWD/meminfo"
    cgroup() {  # cgroup <path under the manager> <MiB in RAM>
      mkdir -p "cg/user@1000.service/$1"
      echo "$(($2 * 1048576))" > "cg/user@1000.service/$1/memory.current"
      echo 0 > "cg/user@1000.service/$1/cgroup.freeze"
    }
    cgroup app.slice/app-chrome-1.scope 4096
    cgroup app.slice/run-p1-i2.scope 3072
    cgroup app.slice/mid.service 1024
    cgroup app.slice/small.service 100
    cgroup session.slice/compositor.service 8192   # the desktop session itself: never
    mkdir -p proc
    echo "MemAvailable:   99999999 kB" > meminfo

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
    jq -e '. == [[false, "b.service", "stop", null]]' run/offline-ai/evicted.json > /dev/null || fail "the unit that did not restart was not remembered"
    mode down > /dev/null 2>&1 || fail "a second down did not restart the remembered unit"
    [ -e mode/system/b.service ] && [ ! -e run/offline-ai/evicted.json ] || fail "the remembered unit was not restarted"

    reset_units
    MODE_MODEL=/nonexistent/model.gguf mode "anything" > nomodel.out 2>&1 && fail "a missing model did not fail"
    [ -e mode/system/a.timer ] && [ -e mode/system/b.service ] && [ -e mode/user/d.service ] \
      || { cat nomodel.out; fail "units stopped for a model that could not load were not restarted"; }

    # --- the model unit starts but never answers: the wait gives up, and
    # what gave way comes back. The unit is still running and holding the
    # reservation whose marker keeps those units from starting, so it must be
    # stopped first; otherwise their `systemctl start` returns 0 having done
    # nothing, and the record of them is wiped.
    reset_units
    FAKE_NEVER_HEALTHY=1 MODE_READY=2 mode up > notready.out 2>&1 && fail "a model that never became ready did not fail"
    grep -q 'did not become ready' notready.out || { cat notready.out; fail "the wait did not report giving up"; }
    [ ! -e mode/marker ] || fail "the marker outlived a failed load"
    case "$(calls)" in
      *"user stop offline-ai-llm.service;"*"start d.service;"*) ;;
      *) fail "the model unit was not stopped before what gave way was restarted: $(calls)" ;;
    esac
    [ -e mode/system/b.service ] && [ -e mode/user/d.service ] || { cat notready.out; fail "units did not come back after a failed load"; }
    [ ! -e run/offline-ai/evicted.json ] || fail "the record survived a failed load that restored everything"

    # The reservation's stop failed inside the unit: the CLI stops it itself.
    reset_units
    mode up > /dev/null 2>&1 || fail "up before the sticky-marker case failed"
    [ -e mode/marker ] || fail "up did not leave the marker"
    FAKE_STICKY_MARKER=1 mode down > sticky1.out 2>&1 || { cat sticky1.out; fail "down failed when only the unit's own reservation stop had failed"; }
    [ ! -e mode/marker ] || fail "down did not stop the reservation itself"
    [ -e mode/user/d.service ] && [ -e mode/system/b.service ] || fail "gated units did not come back once the marker was cleared"
    # The reservation will not stop at all: nothing gated is forgotten.
    reset_units
    mode up > /dev/null 2>&1 || fail "up before the stuck-marker case failed"
    FAKE_STICKY_MARKER=2 mode down > sticky2.out 2>&1 && fail "down reported success while the marker kept units from starting"
    grep -q 'did not start: its condition refused' sticky2.out || { cat sticky2.out; fail "a condition-refused start was taken for a restart"; }
    grep -q 'still exists' sticky2.out || fail "the standing marker was not named"
    [ ! -e mode/user/d.service ] || fail "the fake started a gated unit although the marker stood"
    [ -e mode/system/a.timer ] || fail "the ungated timer did not come back"
    jq -e 'map(.[1]) | sort == ["b.service", "d.service"]' run/offline-ai/evicted.json > /dev/null \
      || { cat run/offline-ai/evicted.json; fail "the gated units were forgotten"; }
    rm -f mode/marker
    mode down > /dev/null 2>&1 || fail "down after the marker was cleared did not restart the remembered units"
    [ -e mode/user/d.service ] && [ -e mode/system/b.service ] && [ ! -e run/offline-ai/evicted.json ] || fail "remembered gated units were not restarted"

    # The reservation did not start (the unit tolerates that): the model
    # answers, and the operator is told the mode is unguarded.
    reset_units
    FAKE_NO_MARKER=1 mode up > nomarker.out 2>&1 || { cat nomarker.out; fail "up failed when only the reservation had failed"; }
    grep -q 'no mode marker' nomarker.out || { cat nomarker.out; fail "a missing marker was not reported"; }
    mode down > /dev/null 2>&1 || fail "down after the no-marker case failed"

    # --- not enough memory once the listed units are stopped: other large
    # units of the user are frozen, largest first, until the model fits, and
    # thawed on the way out. Desktop applications and small units never are.
    frozen() { cat "cg/user@1000.service/app.slice/$1/cgroup.freeze"; }
    reset_units
    truncate -s 2G model-00001-of-00001.gguf
    echo "MemAvailable:   1048576 kB" > meminfo   # 1 GiB; the model needs 2 GiB plus 1 GiB headroom
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode up > freeze.out 2>&1 || { cat freeze.out; fail "up did not make room by freezing"; }
    [ "$(frozen run-p1-i2.scope)" = 1 ] || { cat freeze.out; fail "the large agent job was not frozen"; }
    [ "$(frozen mid.service)" = 0 ] || fail "more was frozen than the model needed"
    [ "$(frozen app-chrome-1.scope)" = 0 ] || fail "a desktop application was frozen"
    grep -q 'run-p1-i2.scope (frozen)' freeze.out || { cat freeze.out; fail "status does not show the frozen unit"; }
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode down > /dev/null 2>&1 || fail "down after freezing failed"
    [ "$(frozen run-p1-i2.scope)" = 0 ] || fail "down did not thaw the frozen unit"
    [ ! -e run/offline-ai/evicted.json ] || fail "the record survived a clean down after freezing"
    [ "$(cat "cg/user@1000.service/session.slice/compositor.service/cgroup.freeze")" = 0 ] \
      || fail "a unit of the desktop session itself was frozen"

    # A frozen unit whose processes ended meanwhile is gone: down still succeeds
    # and forgets it, instead of failing on it for ever.
    reset_units
    echo "MemAvailable:   1048576 kB" > meminfo
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode up > /dev/null 2>&1 || fail "up before the vanished-unit case failed"
    [ "$(frozen run-p1-i2.scope)" = 1 ] || fail "the vanished-unit case did not freeze"
    mkdir -p mode/gone && touch mode/gone/run-p1-i2.scope
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode down > gone.out 2>&1 || { cat gone.out; fail "down failed on a unit that had gone"; }
    [ ! -e run/offline-ai/evicted.json ] || fail "a unit that had gone stayed in the record"
    rm -rf mode/gone; echo 0 > "cg/user@1000.service/app.slice/run-p1-i2.scope/cgroup.freeze"

    reset_units
    echo "MemAvailable:   0 kB" > meminfo   # even with everything frozen the model does not fit
    truncate -s 8G model-00001-of-00001.gguf
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode up > short.out 2>&1 && fail "up succeeded without the memory for the model"
    grep -q 'not enough memory' short.out || { cat short.out; fail "no message when memory stays short"; }
    [ "$(frozen run-p1-i2.scope)" = 0 ] && [ "$(frozen mid.service)" = 0 ] \
      || { cat short.out; fail "units frozen for a model that could not load were not thawed"; }
    [ -e mode/system/b.service ] || fail "units stopped for a model that could not load were not restarted"
    if grep -q 'small.service' mode/calls; then fail "a unit too small to matter was frozen"; fi

    # --- a transient model server holding GPU memory (pinned RAM on an APU,
    # which freezing cannot free) is stopped and, on the way out, recreated
    # from its recorded command line. A desktop application holding more GPU
    # memory is left alone. One GPU client seen through two descriptors counts once.
    cgroup app.slice/gpu-llm.service 200
    gpu_proc() {  # gpu_proc <pid> <cgroup under the manager> <client id> <GiB>
      mkdir -p "proc/$1/fdinfo"
      echo "0::/user@1000.service/$2" > "proc/$1/cgroup"
      for fd in 3 4; do
        printf 'drm-pdev:\t0000:65:00.0\ndrm-client-id:\t%s\ndrm-total-gtt:\t1024 KiB\ndrm-resident-gtt:\t%s KiB\ndrm-resident-vram:\t0 KiB\n' \
          "$3" "$(($4 * 1048576))" > "proc/$1/fdinfo/$fd"
      done
    }
    gpu_proc 4242 app.slice/gpu-llm.service 7 6
    gpu_proc 4343 app.slice/app-chrome-1.scope 8 8
    mkdir -p mode/transient mode/gpu
    touch mode/transient/gpu-llm.service
    echo $((6 * 1048576)) > mode/gpu/gpu-llm.service
    reset_units
    touch mode/user/gpu-llm.service
    truncate -s 4G model-00001-of-00001.gguf
    echo "MemAvailable:   1048576 kB" > meminfo
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode up > gpu.out 2>&1 || { cat gpu.out; fail "up did not make room by stopping the GPU holder"; }
    grep -q 'stopped gpu-llm.service (6.0 GiB of GPU memory)' gpu.out || { cat gpu.out; fail "the GPU holder was not stopped, or its memory was miscounted"; }
    [ "$(frozen run-p1-i2.scope)" = 0 ] || fail "more gave way than the model needed"
    if grep -q 'app-chrome' mode/calls; then fail "a desktop application was touched"; fi
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode down > /dev/null 2>&1 || fail "down after stopping the GPU holder failed"
    [ "$(tr '\n' '|' < mode/relaunched)" = "--user|--unit=gpu-llm.service|--collect|--slice=app.slice|--working-directory=/srv|--setenv=A=1|--setenv=B=two words|--|/bin/llama|-m|a model.gguf|" ] \
      || fail "the transient unit was not recreated as it was: $(tr '\n' '|' < mode/relaunched 2>/dev/null)"

    # --- what stopping and freezing cannot free, the kernel may move to swap:
    # the model loads when idle anonymous memory that swap can take covers
    # the rest, and says how much will move. A swap file frees RAM one for one.
    swaps() { printf 'Filename\tType\tSize\tUsed\tPriority\n' > swaps; printf '%s\n' "$@" >> swaps; }
    reset_units
    touch mode/user/gpu-llm.service
    printf 'MemAvailable:   0 kB\nAnonPages:      %s kB\n' $((20 * 1048576)) > meminfo
    swaps "/var/lib/swapfile file $((30 * 1048576)) 0 -2"
    truncate -s 30G model-00001-of-00001.gguf
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode up > swap.out 2>&1 || { cat swap.out; fail "up refused although swap could take the rest"; }
    grep -q '20 GiB of other programs. idle memory will move to swap' swap.out || { cat swap.out; fail "no word on what moves to swap"; }
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode down > /dev/null 2>&1 || fail "down after a load that relied on swap failed"

    # zram instead: it keeps the swapped pages in RAM, compressed, so at its
    # current ratio of 2 the 20 GiB of idle memory frees only 10 GiB. Not
    # enough for the 20 GiB still missing, and the refusal counts it that way.
    reset_units
    touch mode/user/gpu-llm.service
    printf 'MemAvailable:   0 kB\nAnonPages:      %s kB\n' $((20 * 1048576)) > meminfo
    swaps "/dev/zram0 partition $((40 * 1048576)) 0 5"
    mkdir -p sysblock/zram0
    echo "2000000 1000000 1100000 0 2000000 0 0 0 0" > sysblock/zram0/mm_stat
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode up > zram.out 2>&1 && fail "up loaded although zram frees only half of what moves into it"
    grep -q '10 GiB more could go to swap' zram.out || { cat zram.out; fail "the refusal does not count zram at its compression ratio"; }
    [ -e mode/system/b.service ] || fail "units stopped for a model zram could not make room for were not restarted"

    # zram and the swap file together: zram (the higher priority) fills first.
    # 16 GiB free in it at ratio 2 frees 8 GiB; the file frees the other 12
    # one for one; so 28 GiB of the 40 GiB of idle memory moves to free 20.
    reset_units
    touch mode/user/gpu-llm.service
    printf 'MemAvailable:   0 kB\nAnonPages:      %s kB\n' $((40 * 1048576)) > meminfo
    swaps "/dev/zram0 partition $((32 * 1048576)) $((16 * 1048576)) 5" "/var/lib/swapfile file $((30 * 1048576)) 0 -2"
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode up > mixed.out 2>&1 || { cat mixed.out; fail "up refused although zram and the swap file together could take the rest"; }
    grep -q '28 GiB of other programs. idle memory will move to swap' mixed.out || { cat mixed.out; fail "the message does not say how much really moves with zram in the mix"; }
    MODE_MODEL="$PWD/model-00001-of-00001.gguf" mode down > /dev/null 2>&1 || fail "down after a load that relied on zram and the swap file failed"

    # --- two models: the small one by default, the coder on demand. The
    # table the module exports: the small model keeps today's unit,
    # reservation and marker; the coder has its own, and a model in parts.
    # Keys sorted, as builtins.toJSON writes them (so the coder comes first).
    # Plenty of memory, so only the switching matters here.
    echo "MemAvailable:   99999999 kB" > meminfo
    truncate -s 1M small.gguf coder-00001-of-00002.gguf coder-00002-of-00002.gguf
    jq -n -S --arg d "$PWD" '{
      small: {unit: "offline-ai-llm.service", model: ($d + "/small.gguf"),
              reservation: "memory-reserve-offline-ai.service", marker: ($d + "/mode/marker"),
              about: "small fixture, 1 MB, on the iGPU, 64k context: the one to use",
              fetch: "hf download small-fixture"},
      coder: {unit: "offline-ai-llm-coder.service", model: ($d + "/coder-00001-of-00002.gguf"),
              reservation: "memory-reserve-offline-ai-coder.service", marker: ($d + "/mode/marker-coder"),
              about: "coder fixture, 2 MB, CPU-only, 32k context: the fallback when the small one stumbles",
              fetch: "hf download coder-fixture"}}' > models.json
    two() { OFFLINE_AI_MODELS="$(cat models.json)" OFFLINE_AI_DEFAULT_MODEL=small mode "$@"; }
    active() { [ -e "mode/user/$1" ]; }

    # Without OFFLINE_AI_DEFAULT_MODEL the default is the small model, not the
    # name that happens to sort first in the table.
    reset_units
    OFFLINE_AI_MODELS="$(cat models.json)" mode models > two-default.out 2>&1 || { cat two-default.out; fail "models without OFFLINE_AI_DEFAULT_MODEL failed"; }
    grep -q '^small: not loaded, on disk, default$' two-default.out \
      || { cat two-default.out; fail "without OFFLINE_AI_DEFAULT_MODEL the default is not the small model"; }

    # A conversation loads the default model's unit; --model coder the coder's.
    # From default mode either leaves nothing loaded and no marker behind.
    reset_units
    two "which model" > two-small.out 2>&1 || { cat two-small.out; fail "a default-model conversation failed"; }
    case "$(calls)" in *"user start offline-ai-llm.service;"*) ;; *) fail "the default conversation did not load the small model: $(calls)" ;; esac
    case "$(calls)" in *"start offline-ai-llm-coder.service"*) fail "the default conversation loaded the coder: $(calls)" ;; esac
    reset_units
    two --model coder "which model" > two-coder.out 2>&1 || { cat two-coder.out; fail "a --model coder conversation failed"; }
    grep -q 'MODE ANSWER' two-coder.out || fail "no answer from the coder"
    case "$(calls)" in *"user start offline-ai-llm-coder.service;"*) ;; *) fail "--model coder did not load the coder: $(calls)" ;; esac
    case "$(calls)" in *"start offline-ai-llm.service"*) fail "--model coder loaded the small model: $(calls)" ;; esac
    active offline-ai-llm-coder.service && fail "a --model coder conversation from default mode left the coder loaded"
    [ ! -e mode/marker ] && [ ! -e mode/marker-coder ] || fail "a conversation from default mode left a marker"
    [ -e mode/system/b.service ] && [ -e mode/user/d.service ] || fail "what gave way to the coder was not restarted"
    [ ! -e run/offline-ai/evicted.json ] || fail "the record survived a coder conversation from default mode"

    # While the mode is on, a conversation with the other model only switches
    # models: the model it loaded stays, and so does the mode.
    reset_units
    two up > two-up.out 2>&1 || { cat two-up.out; fail "two-model up failed"; }
    active offline-ai-llm.service && [ -e mode/marker ] || fail "up did not load the small model with its marker"
    two --model coder "harder question" > two-switch-conv.out 2>&1 || { cat two-switch-conv.out; fail "a --model coder conversation with the small model loaded failed"; }
    active offline-ai-llm-coder.service || fail "the coder did not stay loaded after a conversation started in the mode"
    active offline-ai-llm.service && fail "the small model stayed active beside the coder"
    [ ! -e mode/system/b.service ] || fail "a coder conversation started in the mode ended the mode"
    two "easy question" > /dev/null 2>&1 || fail "a default-model conversation with the coder loaded failed"
    active offline-ai-llm.service || fail "the small model did not stay loaded after switching back"
    active offline-ai-llm-coder.service && fail "the coder stayed active beside the small model"

    # Switching with `up`: the loaded model is stopped, its marker going with
    # it, before the other starts; the switch is announced.
    rm -f mode/calls
    two --model coder up > two-switch.out 2>&1 || { cat two-switch.out; fail "--model coder up failed with the small model loaded"; }
    grep -q 'switching from small to coder' two-switch.out || { cat two-switch.out; fail "the switch was not announced"; }
    case "$(calls)" in
      *"user stop offline-ai-llm.service;"*"user start offline-ai-llm-coder.service;"*) ;;
      *) fail "the small model was not stopped before the coder started: $(calls)" ;;
    esac
    active offline-ai-llm.service && fail "the small model's unit stayed active after the switch"
    active offline-ai-llm-coder.service || fail "the coder's unit is not active after the switch"
    [ ! -e mode/marker ] || fail "the small model's marker outlived the switch"
    [ -e mode/marker-coder ] || fail "the coder's marker is missing after the switch"
    [ ! -e mode/system/b.service ] || fail "the switch ended offline-AI mode"

    # status and models name the loaded model, and which is the default.
    two status > two-status.out 2>&1 || { cat two-status.out; fail "status with the coder loaded failed"; }
    grep -q '^model server: ready (coder)$' two-status.out || { cat two-status.out; fail "status does not name the loaded model"; }
    grep -q '^models: small (not loaded, on disk, default); coder (loaded, on disk)$' two-status.out \
      || { cat two-status.out; fail "status does not list the models"; }
    two models > two-models.out 2>&1 || { cat two-models.out; fail "models failed"; }
    grep -q '^small: not loaded, on disk, default$' two-models.out || { cat two-models.out; fail "models does not describe the small model"; }
    grep -q '^coder: loaded, on disk$' two-models.out || { cat two-models.out; fail "models does not describe the coder"; }

    # down with the coder loaded stops it, clears every marker, restores.
    rm -f mode/calls
    two down > two-down.out 2>&1 || { cat two-down.out; fail "down with the coder loaded failed"; }
    case "$(calls)" in *"user stop offline-ai-llm-coder.service;"*) ;; *) fail "down did not stop the coder: $(calls)" ;; esac
    active offline-ai-llm-coder.service && fail "the coder stayed active after down"
    [ ! -e mode/marker ] && [ ! -e mode/marker-coder ] || fail "a marker survived down"
    [ -e mode/system/a.timer ] && [ -e mode/system/b.service ] && [ -e mode/user/d.service ] || fail "down did not restart what gave way to the coder"
    [ ! -e run/offline-ai/evicted.json ] || fail "the record survived a clean down from the coder"
    two status > two-status2.out 2>&1 || fail "status after down failed"
    grep -q '^model server: inactive$' two-status2.out || { cat two-status2.out; fail "status after down does not say inactive"; }
    grep -q '^models: small (not loaded, on disk, default); coder (not loaded, on disk)$' two-status2.out \
      || { cat two-status2.out; fail "status after down does not list both models unloaded"; }

    # An unknown model exits 1 naming the models, before anything is touched;
    # a model not on disk names its own fetch hint, and what gave way comes back.
    reset_units
    two --model nope "question" > two-nope.out 2>&1 && fail "an unknown --model did not fail"
    [ "$(two --model nope "question" > /dev/null 2>&1; echo $?)" = 1 ] || fail "an unknown --model did not exit 1"
    grep -q 'small' two-nope.out && grep -q 'coder' two-nope.out || { cat two-nope.out; fail "the unknown-model message does not name the models"; }
    if grep -qs ' start ' mode/calls; then fail "an unknown --model started something: $(calls)"; fi
    mv coder-00001-of-00002.gguf coder-away.gguf
    two --model coder up > two-missing.out 2>&1 && fail "a coder that is not on disk did not fail"
    grep -q 'coder-fixture' two-missing.out || { cat two-missing.out; fail "the missing coder does not name its fetch hint"; }
    if grep -q 'small-fixture' two-missing.out; then fail "the missing coder named the small model's fetch hint"; fi
    [ -e mode/system/b.service ] && [ -e mode/user/d.service ] || { cat two-missing.out; fail "units stopped for a coder that is not on disk were not restarted"; }
    mv coder-away.gguf coder-00001-of-00002.gguf
    two models > two-models2.out 2>&1 || fail "models after the missing-coder case failed"
    grep -q '^coder: not loaded, on disk$' two-models2.out || { cat two-models2.out; fail "models does not see the coder back on disk"; }

    # With the small model loaded, a switch to a coder that is not on disk
    # fails before anything is stopped: the small model stays loaded with its
    # marker, the mode stays on, and the message names the coder's fetch hint.
    reset_units
    two up > /dev/null 2>&1 || fail "up before the missing-coder switch failed"
    mv coder-00001-of-00002.gguf coder-away.gguf
    rm -f mode/calls
    two --model coder "harder question" > two-missing-switch.out 2>&1 && fail "a switch to a coder that is not on disk did not fail"
    grep -q 'coder-fixture' two-missing-switch.out || { cat two-missing-switch.out; fail "the missing-coder switch does not name the fetch hint"; }
    if grep -qs 'stop offline-ai-llm.service' mode/calls; then fail "the small model was stopped for a coder that is not on disk: $(calls)"; fi
    active offline-ai-llm.service && [ -e mode/marker ] || fail "the small model did not stay loaded when the coder was not on disk"
    [ ! -e mode/system/b.service ] || fail "a failed switch ended offline-AI mode"
    mv coder-away.gguf coder-00001-of-00002.gguf
    two down > /dev/null 2>&1 || fail "down after the failed switch failed"

    # --- the deployed units, read at eval time: each model unit names the
    # other in Conflicts= and in After= (Conflicts= alone orders nothing, so
    # a by-hand `systemctl --user start` of the other unit could run both
    # servers at once; with the ordering, systemd.unit(5): stop jobs are
    # ordered before start jobs), so systemd itself never holds both loaded;
    # and the gated units (one user drop-in, one system unit) refuse to
    # start while either model's marker stands.
    small_conflicts=${pkgs.lib.escapeShellArg (toString (conflicts.small or [ ]))}
    coder_conflicts=${pkgs.lib.escapeShellArg (toString (conflicts.coder or [ ]))}
    case " $small_conflicts " in *" offline-ai-llm-coder.service "*) ;; *) fail "the small model's unit does not conflict with the coder's: '$small_conflicts'" ;; esac
    case " $coder_conflicts " in *" offline-ai-llm.service "*) ;; *) fail "the coder's unit does not conflict with the small model's: '$coder_conflicts'" ;; esac
    small_after=${pkgs.lib.escapeShellArg (toString (after.small or [ ]))}
    coder_after=${pkgs.lib.escapeShellArg (toString (after.coder or [ ]))}
    case " $small_after " in *" offline-ai-llm-coder.service "*) ;; *) fail "the small model's unit is not ordered after the coder's (After=): '$small_after'" ;; esac
    case " $coder_after " in *" offline-ai-llm.service "*) ;; *) fail "the coder's unit is not ordered after the small model's (After=): '$coder_after'" ;; esac
    gated_user=${pkgs.lib.escapeShellArg gatedUserDropIn}
    gated_system=${pkgs.lib.escapeShellArg (toString gatedSystemConditions)}
    for marker in /run/memory-reserve/offline-ai /run/memory-reserve/offline-ai-coder; do
      printf '%s\n' "$gated_user" | grep -qx "ConditionPathExists=!$marker" \
        || fail "the gated user drop-in lacks ConditionPathExists=!$marker: $gated_user"
      case " $gated_system " in *" !$marker "*) ;; *) fail "the gated system units lack !$marker: '$gated_system'" ;; esac
    done

    # --- the help text is a complete reference (see helpUnit), reached by
    # both `help` and --help, and carries the table's lines and fetch hints.
    OFFLINE_AI_MODELS="$(cat models.json)" OFFLINE_AI_DEFAULT_MODEL=small python3 ${helpUnit} "$script" \
      || fail "the help text is not a complete reference"
    two --help > two-help.out 2>&1 || { cat two-help.out; fail "--help failed"; }
    two help > two-help2.out 2>&1 || fail "help failed"
    cmp -s two-help.out two-help2.out || fail "help and --help print different texts"
    grep -q 'coder-fixture' two-help.out && grep -q 'the fallback when the small one stumbles' two-help.out \
      || { cat two-help.out; fail "--help does not carry the coder's line and fetch hint"; }

    python3 ${swapUnit} "$script" || fail "swap accounting is wrong"

    mkdir -p "$out"
    echo 'offline-ai harness passed' > "$out/result"
  ''
