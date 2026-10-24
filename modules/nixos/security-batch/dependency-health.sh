# shellcheck shell=bash
# security-batch runner: nightly dependency health of the watched repos
# (runs under modules/nixos/security-batch.nix; contract in that file's
# header). Argument: a JSON config written by dependency-health.nix,
#   {"repos": ["owner/name", ...], "app_id": N, "installations": {"owner": N}}
#
# Per repo, read-only REST through `gh api`:
#   1. open Dependabot alerts, counted by severity. A 403/404 whose message
#      says alerts are disabled is the finding "alerts disabled"; any other
#      error is a tool error (an under-scoped token must not look clean);
#   2. open PRs by dependabot[bot] created over 7 days ago (stale), or whose
#      latest run of some workflow on the PR head concluded failure,
#      timed_out or startup_failure (failing);
#   3. per workflow that is still active, its own latest scheduled run on
#      the default branch (one query per workflow, so a busy hourly schedule
#      cannot push a weekly one out of a shared page), if that concluded
#      failure, timed_out or startup_failure.
#
# No diff against the previous run and no accepted.txt: acceptance lives in
# GitHub (a dismissed alert is not open, a closed PR is not open), so a
# finding fails every night until it is handled there.
#
# Auth: one installation token per owner, minted by `gh-token` (nixpkgs,
# Link-/gh-token) from the App's private key at
# $CREDENTIALS_DIRECTORY/github-app-key. The token lives in this process only
# and reaches gh as GH_TOKEN (gh's own interface), never argv or disk; it
# expires within the hour.
#
# Output: summary.txt, one line in the framework's character set (repos by
# name, counts only); report.txt, per repo: IDs, packages, severities, URLs.
# No GitHub free text (titles, advisory summaries) in either.
#
# Exit: 0 clean, 1 findings, 3 a repo could not be fully checked (every repo
# and step still runs).
set -euo pipefail

run=${RUN_DIR:?}
config=${1:?usage: dependency-health.sh <config.json>}
key="${CREDENTIALS_DIRECTORY:-/nonexistent}/github-app-key"
mapfile -t repos < <(jq -r '.repos[]' "$config")
app_id=$(jq -r '.app_id // empty' "$config")
declare -A tokens=()
export GH_TOKEN=""
stale_days=7
failed='["failure", "timed_out", "startup_failure"]'
attention=()   # summary pieces "name: counts"
errors=()      # summary pieces "could not check name: reason"
report=$run/report.txt
: > "$report"

safe() { tr -cd 'A-Za-z0-9 =:;,.@_>-'; }
plural() { if [ "$1" -eq 1 ]; then echo "$1 $2"; else echo "$1 $2s"; fi; }

# api <out> <endpoint> [gh flags]: 0 = JSON in <out>; 1 = failed, $reason
# set and $http_status set when GitHub answered with an error.
api() {
  local out=$1 endpoint=$2 rc=0; shift 2
  http_status=""; reason=""
  gh api "$@" "$endpoint" > "$out" 2> "$out.err" || rc=$?
  if [ "$rc" -ne 0 ]; then
    http_status=$(grep -oE 'HTTP [0-9]{3}' "$out.err" | tail -1 | cut -c6- || true)
    if [ -n "$http_status" ]; then
      reason="HTTP $http_status $(jq -r '.message? // empty' "$out" 2> /dev/null | safe | head -c 80 || true)"
    else
      reason="gh exit $rc $(head -n 1 "$out.err" | safe | head -c 80)"
    fi
    return 1
  fi
  # --paginate prints one JSON document per page; join arrays, keep objects.
  if ! jq -se 'length > 0 and (all(type == "array") or (length == 1 and (.[0] | type == "object")))' \
       "$out" > /dev/null 2>&1; then
    reason="malformed JSON from $(basename "$out" .json)"
    return 1
  fi
  jq -s 'if .[0] | type == "array" then add else .[0] end' "$out" > "$out.tmp" && mv "$out.tmp" "$out"
}

# use_token <owner>: GH_TOKEN = that owner's installation token (minted once
# per run); 1 with $reason set when there is none.
use_token() {
  local owner=$1 id
  if [ -z "${tokens[$owner]:-}" ]; then
    id=$(jq -r --arg o "$owner" '.installations[$o] // empty' "$config")
    [ -n "$id" ] || { reason="no App installation for $owner"; return 1; }
    if ! tokens[$owner]=$(gh-token generate --app-id "$app_id" --installation-id "$id" \
           --key "$key" --token-only 2> "$run/token-$owner.err") || [ -z "${tokens[$owner]}" ]; then
      tokens[$owner]=""
      reason="App token for $owner failed: $(head -n 1 "$run/token-$owner.err" | safe | head -c 60)"
      return 1
    fi
  fi
  GH_TOKEN=${tokens[$owner]}
}

check_repo() {
  local repo=$1 name=${1##*/} d branch parts=() bad=()
  d="$run/repos/${repo//\//_}"
  mkdir -p "$d"
  echo "$repo" >> "$report"
  if ! use_token "${repo%%/*}"; then
    errors+=("could not check $name: $reason")
    echo "  ERROR $reason" >> "$report"
    return
  fi

  # ── 1. alerts ──
  if api "$d/alerts.json" "repos/$repo/dependabot/alerts?state=open&per_page=100" --paginate \
     && jq -e 'type == "array" and all(type == "object")' "$d/alerts.json" > /dev/null; then
    local count sev
    count=$(jq length "$d/alerts.json")
    if [ "$count" -gt 0 ]; then
      sev=$(jq -r '[.[] | (.security_vulnerability.severity // .security_advisory.severity // "unknown")]
        | group_by(.) | map({s: .[0], n: length})
        | map(select(.s == "critical" or .s == "high")) | sort_by(.s) | map("\(.n) \(.s)") | join(" ")' "$d/alerts.json")
      parts+=("$(plural "$count" alert)${sev:+ $sev}")
      jq -r '.[] | "  alert \(.security_vulnerability.severity // .security_advisory.severity // "unknown")"
        + " \(.security_advisory.ghsa_id // "-") \(.dependency.package.ecosystem // "-")/\(.dependency.package.name // "-")"
        + " \(.html_url // "")"' "$d/alerts.json" >> "$report"
    fi
  elif [[ "$http_status" =~ ^40[34]$ ]] && jq -e '.message | test("disabled"; "i")' "$d/alerts.json" > /dev/null 2>&1; then
    parts+=("alerts disabled")
    echo "  alerts disabled: Dependabot alerts are off for this repo" >> "$report"
  else
    bad+=("${reason:-malformed alerts}")
  fi

  # ── 2. Dependabot PRs ──
  if api "$d/pulls.json" "repos/$repo/pulls?state=open&per_page=100" --paginate \
     && jq -e 'type == "array"' "$d/pulls.json" > /dev/null; then
    local stale=0 failing=0 number created sha url age
    while IFS=$'\t' read -r number created sha url; do
      age=$(( ($(date -u +%s) - $(date -u -d "$created" +%s)) / 86400 ))
      if api "$d/runs-$number.json" "repos/$repo/actions/runs?head_sha=$sha&per_page=100" \
         && jq -e '.workflow_runs | type == "array"' "$d/runs-$number.json" > /dev/null; then
        local red
        red=$(jq -r --argjson f "$failed" '.workflow_runs | group_by(.workflow_id) | map(max_by(.created_at))
          | map(select(.conclusion as $c | $f | index($c))) | map(.path // .name // "?") | join(",")' "$d/runs-$number.json")
        if [ -n "$red" ]; then
          failing=$((failing + 1)); echo "  pr #$number failing: $red ${age}d $url" >> "$report"
        elif [ "$age" -gt "$stale_days" ]; then
          stale=$((stale + 1)); echo "  pr #$number stale: ${age}d $url" >> "$report"
        fi
      else
        bad+=("${reason:-malformed runs for PR $number}")
      fi
    done < <(jq -r '.[] | select(.user.login == "dependabot[bot]")
      | [(.number | tostring), .created_at, .head.sha, .html_url] | @tsv' "$d/pulls.json")
    [ "$stale" -eq 0 ] || parts+=("$(plural "$stale" "stale PR")")
    [ "$failing" -eq 0 ] || parts+=("$(plural "$failing" "failing PR")")
  else
    bad+=("${reason:-malformed pulls}")
  fi

  # ── 3. scheduled workflows on the default branch ──
  if api "$d/repo.json" "repos/$repo" && branch=$(jq -er '.default_branch | strings' "$d/repo.json"); then
    if api "$d/workflows.json" "repos/$repo/actions/workflows?per_page=100" \
       && jq -e '.workflows | type == "array"' "$d/workflows.json" > /dev/null; then
      local wf red_runs=0 ubranch
      ubranch=$(jq -rn --arg b "$branch" '$b | @uri')
      for wf in $(jq -r '.workflows[] | select(.state == "active") | .id | numbers' "$d/workflows.json"); do
        if api "$d/schedule-$wf.json" "repos/$repo/actions/workflows/$wf/runs?event=schedule&branch=$ubranch&per_page=1" \
           && jq -e '.workflow_runs | type == "array"' "$d/schedule-$wf.json" > /dev/null; then
          if jq -e --argjson f "$failed" '.workflow_runs[0].conclusion as $c | $c != null and ($f | index($c))' \
               "$d/schedule-$wf.json" > /dev/null; then
            red_runs=$((red_runs + 1))
            jq -r '.workflow_runs[0] | "  scheduled run failed: \(.path // .name // "?") \(.html_url // "")"' \
              "$d/schedule-$wf.json" >> "$report"
          fi
        else
          bad+=("${reason:-malformed runs for workflow $wf}")
        fi
      done
      [ "$red_runs" -eq 0 ] || parts+=("$(plural "$red_runs" "failed scheduled run")")
    else
      bad+=("${reason:-malformed workflows}")
    fi
  else
    bad+=("${reason:-no default branch}")
  fi

  local p joined=""
  for p in "${parts[@]}"; do joined="${joined:+$joined, }$p"; done
  [ -z "$joined" ] || attention+=("$name: $joined")
  # One error per repo in the summary (a bad token fails every call); all in the report.
  [ "${#bad[@]}" -eq 0 ] || errors+=("could not check $name: ${bad[0]}")
  for p in "${bad[@]}"; do echo "  ERROR $p" >> "$report"; done
  [ "${#parts[@]}" -gt 0 ] || [ "${#bad[@]}" -gt 0 ] || echo "  clean" >> "$report"
}

missing=()
[ -n "$app_id" ] || missing+=("no app id")
[ -s "$key" ] || missing+=("no key")
if [ "${#repos[@]}" -eq 0 ]; then
  errors+=("could not check: no repos configured")
elif [ "${#missing[@]}" -gt 0 ]; then
  errors+=("could not check any repo: GitHub App not provisioned, $(IFS=,; echo "${missing[*]}"), see dependency-health.nix")
else
  for repo in "${repos[@]}"; do check_repo "$repo"; done
fi

# ── verdict ──
pieces=("${errors[@]}")
if [ "${#attention[@]}" -eq 1 ]; then
  pieces+=("1 repo needs attention" "${attention[@]}")
elif [ "${#attention[@]}" -gt 1 ]; then
  pieces+=("${#attention[@]} repos need attention" "${attention[@]}")
elif [ "${#errors[@]}" -eq 0 ]; then
  pieces+=("${#repos[@]} repos checked, none need attention")
fi
# One line of at most 200 chars (the framework keeps no more): whole pieces
# while there is still room to say how many were left out.
line=""
for i in "${!pieces[@]}"; do
  p=$(safe <<< "${pieces[$i]}")
  left=$(( ${#pieces[@]} - i ))
  more=""; [ "$left" -eq 1 ] || more="; and $((left - 1)) more"
  if [ $(( ${#line} + 2 + ${#p} + ${#more} )) -gt 200 ]; then
    line="$line; and $left more"
    break
  fi
  line="${line:+$line; }$p"
done
echo "$line" > "$run/summary.txt"
cat "$run/summary.txt"

[ "${#errors[@]}" -eq 0 ] || exit 3
[ "${#attention[@]}" -eq 0 ] || exit 1
exit 0
