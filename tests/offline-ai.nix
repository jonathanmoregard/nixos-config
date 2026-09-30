# offline-ai: runtime-invocation harness for the deployed `offline-ai`
# wrapper (modules/nixos/offline-ai.nix), run against a stub model server.
# No VM and no model: the stub plays the model's side of one conversation.
#
# What must hold, whatever the model is:
#   - a tool the model asks for is run and its result goes back to the model
#     (checked with a real option from the deployed option reference, so a
#     wrong store subpath in the wrapper fails here);
#   - a read outside the allowed roots is refused, and the refusal is fed
#     back as a tool result instead of ending the run;
#   - a tool name that does not exist is answered, not fatal;
#   - the model's final text reaches stdout.
#
# Run: nix build .#checks.x86_64-linux.offline-ai -L
{ pkgs, offlineAi }:
let
  stub = pkgs.writeText "offline-ai-stub.py" ''
    import json, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer

    CALLS = [
        ("show_option", {"name": "networking.firewall.allowedTCPPorts"}),
        ("read_file", {"path": "/etc/shadow"}),
        ("no_such_tool", {}),
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
            else:
                results = [m["content"] for m in body["messages"] if m["role"] == "tool"]
                with open(sys.argv[2], "w") as fh:
                    json.dump(results, fh)
                self.sse({"content": "STUB FINAL "})
                self.sse({"content": "ANSWER"})
            self.wfile.write(b"data: [DONE]\n\n")

    server = HTTPServer(("127.0.0.1", 0), Handler)
    with open(sys.argv[1], "w") as fh:
        fh.write(str(server.server_address[1]))
    server.serve_forever()
  '';
in
pkgs.runCommand "offline-ai-harness"
  {
    nativeBuildInputs = [ pkgs.python3 pkgs.jq pkgs.coreutils ];
  }
  ''
    fail() { echo "FAIL: $*"; [ -f out.txt ] && cat out.txt; [ -f err.txt ] && cat err.txt; exit 1; }

    export HOME="$PWD/home"
    mkdir -p "$HOME" config
    echo '{ services.example.enable = true; }' > config/configuration.nix

    python3 ${stub} port results.json &
    stub_pid=$!
    trap 'kill $stub_pid 2>/dev/null || true' EXIT
    for _ in $(seq 1 50); do [ -s port ] && break; sleep 0.1; done
    [ -s port ] || fail "stub server did not start"

    export OFFLINE_AI_URL="http://127.0.0.1:$(cat port)"
    export OFFLINE_AI_CONFIG_ROOT="$PWD/config"
    export OFFLINE_AI_DOC_DIRS="$PWD/docs"
    export OFFLINE_AI_MODEL=""

    ${offlineAi}/bin/offline-ai "open a port" > out.txt 2> err.txt || fail "offline-ai exited non-zero"

    grep -q 'STUB FINAL ANSWER' out.txt || fail "final answer did not reach stdout"
    [ "$(jq length results.json)" = 3 ] || fail "expected three tool results to reach the model"
    jq -e '.[0] | contains("networking.firewall.allowedTCPPorts") and contains("type:")' results.json > /dev/null \
      || fail "option lookup did not return the deployed option reference"
    jq -e '.[1] | contains("outside the readable roots")' results.json > /dev/null \
      || fail "a read outside the allowed roots was not refused"
    jq -e '.[1] | contains("root:") | not' results.json > /dev/null \
      || fail "file content from outside the allowed roots reached the model"
    jq -e '.[2] | contains("unknown tool")' results.json > /dev/null \
      || fail "an unknown tool name was not reported back"

    mkdir -p "$out"
    echo 'offline-ai harness passed' > "$out/result"
  ''
