# security-batch-model-retirement: runtime harness for the model-retirement
# check (modules/nixos/security-batch/model-retirement.sh). No VM, no
# network: curl is a fake on PATH that serves manifests and Models API
# answers from files.
#
# What must hold:
#   - shutdown_date beyond the window, lifecycle active: exit 0;
#   - shutdown_date within the window (epoch or ISO string), or past: exit 1,
#     the id, days left, date and consumer in summary.txt;
#   - HTTP 404, or an Anthropic lifecycle of deprecated/retired: exit 1;
#   - no OpenAI date: counted as unknown, exit 0; no Anthropic lifecycle: exit 3;
#   - an id in accepted.txt: exit 0 (a commented-out line accepts nothing);
#   - a lookup failing (HTTP 500, missing key), a manifest unreachable or
#     malformed (incl. non-object entries, zero models), a transport error,
#     an entry with a bad provider or a path-unsafe id: exit 3,
#     and every other model is still checked;
#   - one lookup per model even when two manifests pin it;
#   - API keys reach curl on stdin, never argv, never a file in the run dir.
#
# Run: nix build .#checks.x86_64-linux.security-batch-model-retirement -L
{ pkgs, runnerScript, runnerPackage }:
let
  # Fake curl: logs argv and any -K - stdin, answers by URL.
  #   manifest URLs (FAKE_DIR/manifests/<n>.json, or <n>.fail → exit 22)
  #   /v1/models/<id> → FAKE_DIR/models/<id>.json, status <id>.code (default 200)
  fakeCurl = pkgs.writeShellScript "curl" ''
    echo "argv: $*" >> "$FAKE_LOG"
    out=/dev/stdout; fmt=""; url=""; stdin_cfg=no
    while [ $# -gt 0 ]; do
      case "$1" in
        -K) [ "$2" = - ] && stdin_cfg=yes; shift ;;
        -o) out=$2; shift ;;
        -w) fmt=$2; shift ;;
        -H|--proto|--max-time) shift ;;
        -*) ;;
        *) url=$1 ;;
      esac
      shift
    done
    [ "$stdin_cfg" = yes ] && { printf 'stdin: '; cat; } >> "$FAKE_LOG"
    case "$url" in
      https://manifests.test/*)
        n=''${url##*/}
        [ -e "$FAKE_DIR/manifests/$n.fail" ] && { echo "curl: (22) 404" >&2; exit 22; }
        cat "$FAKE_DIR/manifests/$n.json" > "$out" ;;
      https://api.openai.com/v1/models/*|https://api.anthropic.com/v1/models/*)
        id=''${url##*/}
        echo "lookup $id" >> "$FAKE_LOG"
        [ -e "$FAKE_DIR/models/$id.curlfail" ] && { echo "curl: (28) timed out" >&2; exit 28; }
        code=$(cat "$FAKE_DIR/models/$id.code" 2>/dev/null || echo 200)
        cat "$FAKE_DIR/models/$id.json" 2>/dev/null > "$out" || echo '{"error":{}}' > "$out"
        [ -n "$fmt" ] && printf '%s' "$code" ;;
      *) echo "fake curl: unexpected url $url" >&2; exit 6 ;;
    esac
  '';
in
pkgs.runCommand "security-batch-model-retirement-harness"
  {
    nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.gawk pkgs.gnugrep pkgs.gnused pkgs.coreutils ];
  } ''
    fail() { echo "FAIL: $*" >&2; for f in "$run"/summary.txt "$run"/out "$FAKE_LOG"; do [ -f "$f" ] && { echo "--- $f"; cat "$f"; } >&2; done; exit 1; }

    # The deployed runner is this exact script.
    grep -qF 'shutdown_date' ${runnerPackage}/bin/security-batch-model-retirement \
      || fail "the runner package does not embed model-retirement.sh"

    mkdir -p fakebin fake/manifests fake/models creds
    ln -s ${fakeCurl} fakebin/curl
    export FAKE_DIR=$PWD/fake FAKE_LOG=$PWD/calls.log
    echo sk-openai-SECRET > creds/openai-api-key
    echo sk-ant-SECRET > creds/anthropic-api-key
    now=$(date -u -d 2026-10-24 +%s)

    manifest() {  # manifest <n> <consumer> '<provider>:<id> ...'
      jq -n --arg c "$2" --arg spec "$3" '{schema: 1, consumer: $c,
        models: ($spec | split(" ") | map(select(. != "") | split(":")
          | {provider: .[0], id: .[1], used_by: ["test"]}))}' > "fake/manifests/$1.json"
    }
    model() { echo "$2" > "fake/models/$1.json"; rm -f "fake/models/$1.code"; }  # model <id> <json>
    status() { echo "$2" > "fake/models/$1.code"; }                                # status <id> <code>
    : > accepted.txt
    manifests="https://manifests.test/1"
    n=0
    check() {  # → sets $run and $rc
      n=$((n + 1)); run=$PWD/run$n; mkdir -p "$run"; : > "$FAKE_LOG"
      rc=0
      env PATH="$PWD/fakebin:$PATH" RUN_DIR="$run" ACCEPTED_FINDINGS="$PWD/accepted.txt" \
        CREDENTIALS_DIRECTORY="$PWD/creds" MODEL_RETIREMENT_MANIFESTS="$manifests" \
        MODEL_RETIREMENT_NOW="$now" MODEL_RETIREMENT_WARN_DAYS=90 \
        bash ${runnerScript} > "$run/out" 2>&1 || rc=$?
    }
    summary() { cat "$run/summary.txt"; }
    far=$(date -u -d 2027-12-01 +%s); near=$(date -u -d 2027-01-14 +%s)

    # 1. Clean: a far shutdown date and an active model.
    manifest 1 injection-scanner "openai:gpt-4o-mini anthropic:claude-haiku-4-5"
    model gpt-4o-mini "{\"id\":\"gpt-4o-mini\",\"shutdown_date\":$far}"
    model claude-haiku-4-5 '{"id":"claude-haiku-4-5","lifecycle":"active"}'
    check; [ "$rc" = 0 ] || fail "clean run exited $rc"
    grep -q '^models=2 retiring=0 unknown=0 tool_errors=0$' <<< "$(summary)" || fail "clean summary wrong"

    # 2. Keys travel on stdin only.
    grep -q '^argv: .*SECRET' calls.log && fail "an API key reached curl argv"
    grep -q 'stdin: header = "Authorization: Bearer sk-openai-SECRET"' calls.log || fail "openai key not sent"
    grep -q 'stdin: header = "x-api-key: sk-ant-SECRET"' calls.log || fail "anthropic key not sent"
    grep -q 'argv: .*anthropic-version: 2023-06-01' calls.log || fail "anthropic-version header missing"

    # 3. Inside the window: 82 days, epoch form and ISO form.
    model gpt-4o-mini "{\"shutdown_date\":$near}"
    check; [ "$rc" = 1 ] || fail "near shutdown exited $rc"
    grep -q 'retiring=1 .*retiring: gpt-4o-mini:82d:2027-01-14:injection-scanner' <<< "$(summary)" || fail "near shutdown not named"
    model gpt-4o-mini '{"shutdown_date":"2027-01-14"}'
    check; [ "$rc" = 1 ] || fail "ISO shutdown_date exited $rc"
    grep -q 'gpt-4o-mini:82d:2027-01-14' <<< "$(summary)" || fail "ISO date not parsed"
    model gpt-4o-mini '{"shutdown_date":"2026-10-23"}'
    check; [ "$rc" = 1 ] || fail "past shutdown exited $rc"
    grep -q 'gpt-4o-mini:gone:2026-10-23' <<< "$(summary)" || fail "past shutdown not gone"
    model gpt-4o-mini "{\"shutdown_date\":$near.0}"
    check; [ "$rc" = 1 ] || fail "float shutdown_date exited $rc"
    grep -q 'gpt-4o-mini:82d:2027-01-14' <<< "$(summary)" || fail "float date not parsed"
    model gpt-4o-mini '{"shutdown_date":"soonish"}'
    check; [ "$rc" = 3 ] || fail "unparsable shutdown_date exited $rc"

    # 4. 404 and Anthropic lifecycle.
    model gpt-4o-mini '{}'; status gpt-4o-mini 404
    check; [ "$rc" = 1 ] || fail "404 exited $rc"
    grep -q 'gpt-4o-mini:gone:injection-scanner' <<< "$(summary)" || fail "404 not gone"
    model gpt-4o-mini "{\"shutdown_date\":$far}"
    model claude-haiku-4-5 '{"lifecycle":{"status":"deprecated"}}'
    check; [ "$rc" = 1 ] || fail "deprecated exited $rc"
    grep -q 'claude-haiku-4-5:deprecated:injection-scanner' <<< "$(summary)" || fail "deprecated not named"

    # 5. No OpenAI date: unknown, not alerted. No Anthropic lifecycle: this
    # check's reading of the API is wrong, a tool error.
    model claude-haiku-4-5 '{"id":"claude-haiku-4-5","lifecycle":"active"}'
    model gpt-4o-mini '{"id":"gpt-4o-mini","shutdown_date":null}'
    check; [ "$rc" = 0 ] || fail "no-date run exited $rc"
    grep -q 'unknown=1' <<< "$(summary)" || fail "unknown not counted"
    model claude-haiku-4-5 '{"id":"claude-haiku-4-5"}'
    check; [ "$rc" = 3 ] || fail "missing lifecycle exited $rc"
    grep -q 'failed: claude-haiku-4-5:no-lifecycle' <<< "$(summary)" || fail "missing lifecycle not named"
    model claude-haiku-4-5 '{"lifecycle":"active"}'

    # 6. Accepted.
    model gpt-4o-mini "{\"shutdown_date\":$near}"
    printf '# handled\n  gpt-4o-mini   replacement scheduled\n' > accepted.txt
    check; [ "$rc" = 0 ] || fail "accepted model exited $rc"
    grep -q 'gpt-4o-mini' "$run/findings.tsv" || fail "accepted finding not kept in findings.tsv"
    printf '# gpt-4o-mini commented out\n' > accepted.txt
    check; [ "$rc" = 1 ] || fail "a commented-out accept still accepted ($rc)"
    : > accepted.txt

    # 7. A lookup failure is 3, and the other model is still checked.
    status claude-haiku-4-5 500
    check; [ "$rc" = 3 ] || fail "HTTP 500 exited $rc"
    grep -q 'failed: claude-haiku-4-5:http500' <<< "$(summary)" || fail "500 not named"
    grep -q 'retiring: gpt-4o-mini:82d' <<< "$(summary)" || fail "finding hidden by a lookup failure"
    model claude-haiku-4-5 '{"lifecycle":"active"}'
    touch fake/models/claude-haiku-4-5.curlfail
    check; [ "$rc" = 3 ] || fail "transport error exited $rc"
    grep -q 'failed: claude-haiku-4-5:curl28' <<< "$(summary)" || fail "transport error not named"
    grep -q 'timed out' "$run/anthropic-claude-haiku-4-5.err" || fail "curl stderr not kept"
    rm fake/models/claude-haiku-4-5.curlfail
    mv creds/anthropic-api-key creds/off
    check; [ "$rc" = 3 ] || fail "missing key exited $rc"
    grep -q 'failed: anthropic-key' <<< "$(summary)" || fail "missing key not named"
    mv creds/off creds/anthropic-api-key
    model gpt-4o-mini "{\"shutdown_date\":$far}"

    # 8. Manifests: unreachable, malformed, bad entries, none configured.
    touch fake/manifests/1.fail
    check; [ "$rc" = 3 ] || fail "unreachable manifest exited $rc"
    grep -q 'failed: manifest-1' <<< "$(summary)" || fail "manifest failure not named"
    rm fake/manifests/1.fail
    echo '<html>rate limited</html>' > fake/manifests/1.json
    check; [ "$rc" = 3 ] || fail "non-JSON manifest exited $rc"
    manifest 1 injection-scanner "openai:gpt-4o-mini google:gemini-x openai:../../v1/files"
    check; [ "$rc" = 3 ] || fail "bad entries exited $rc"
    grep -q 'lookup gpt-4o-mini' calls.log || fail "good entry skipped next to bad ones"
    grep -q 'lookup \.\.\|files' calls.log && fail "a path-unsafe id reached a URL"
    echo '{"schema":1,"consumer":"injection-scanner","models":["gpt-4o-mini"]}' > fake/manifests/1.json
    check; [ "$rc" = 3 ] || fail "non-object model entries exited $rc"
    grep -q 'failed: manifest-1,no-models' <<< "$(summary)" || fail "non-object entries not named"
    manifests=""
    check; [ "$rc" = 3 ] || fail "no manifests exited $rc"
    grep -q 'failed: no-manifests' <<< "$(summary)" || fail "empty manifest list not named"

    # 9. Two consumers, one model: one lookup, both named.
    manifests="https://manifests.test/1 https://manifests.test/2"
    manifest 1 injection-scanner "openai:gpt-4o-mini"
    manifest 2 research-agent "openai:gpt-4o-mini"
    model gpt-4o-mini "{\"shutdown_date\":$near}"
    check; [ "$rc" = 1 ] || fail "shared model exited $rc"
    [ "$(grep -c '^lookup gpt-4o-mini' calls.log)" = 1 ] || fail "shared model looked up twice"
    grep -q 'gpt-4o-mini:82d:2027-01-14:injection-scanner_research-agent' <<< "$(summary)" || fail "consumers not joined"
    grep -q '^models=1 ' <<< "$(summary)" || fail "shared model counted twice"

    # Nothing any run left on disk carries a key.
    grep -rlF SECRET run* && fail "an API key was written into a run dir"

    mkdir -p "$out"; echo "security-batch model-retirement harness passed" > "$out/result"
  ''
