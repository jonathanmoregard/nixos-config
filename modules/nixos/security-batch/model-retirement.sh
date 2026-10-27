# shellcheck shell=bash
# security-batch runner: weekly check that no pinned vendor model is about to
# be shut down (runs under modules/nixos/security-batch.nix; contract in that
# file's header).
#
# Why: gpt-4.1-nano shut down on 2026-10-23 under the injection-scanner
# honeypot, and the first sign was the nightly live eval failing the next
# morning. The providers publish retirement dates machine-readably, so the
# warning can come months ahead instead.
#
# 1. Manifests: each URL in $MODEL_RETIREMENT_MANIFESTS is a consumer's
#    model-pins.json (schema 1: consumer, models[].{provider,id,used_by}),
#    fetched from the branch its call sites run. The consumer's own tests
#    keep the file equal to the pins in its code.
# 2. Per model, the provider's Models API:
#      openai     GET /v1/models/<id>  optional `shutdown_date`
#      anthropic  GET /v1/models/<id>  `lifecycle` (active|deprecated|retired)
#    Finding = HTTP 404 (already gone), a shutdown_date within
#    $MODEL_RETIREMENT_WARN_DAYS (default 90) or past, or a lifecycle of
#    deprecated/retired. An OpenAI 200 without shutdown_date is "no date
#    announced": counted as unknown=, not alerted. An Anthropic 200 without
#    lifecycle is a tool error (the field is unconditional there).
#
# No diff against the previous run: a retirement deadline does not age into
# a baseline, so a finding fails every week until the pin moves (the
# consumer's manifest changes with it) or the id is listed in accepted.txt.
#
# accepted.txt: one model id per line, `#` comments.
#   gpt-4o-mini   replacement scheduled in injection-scanner#NN
#
# Keys come from $CREDENTIALS_DIRECTORY/{openai,anthropic}-api-key and reach
# curl on stdin (-K -), never argv or disk.
#
# Exit: 0 clean, 1 findings, 3 a fetch or lookup failed (every model is still
# checked). summary.txt: counts and model ids only.
set -euo pipefail

run=${RUN_DIR:?}
accepted=${ACCEPTED_FINDINGS:-/dev/null}
warn_days=${MODEL_RETIREMENT_WARN_DAYS:-90}
now=${MODEL_RETIREMENT_NOW:-$(date -u +%s)}
read -r -a manifests <<< "${MODEL_RETIREMENT_MANIFESTS:-}"
errors=()
findings=()
unknown=0

id_re='^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$'
accepted_ids=$(sed -e 's/#.*//' "$accepted" | awk 'NF { print $1 }' | sort -u)

# curl with a secret header fed through the config channel. $1 = header line
# or "" ; the rest are curl arguments.
fetch() {
  local header=$1; shift
  if [ -n "$header" ]; then
    printf 'header = "%s"\n' "$header" | curl -K - "$@"
  else
    curl "$@"
  fi
}

key() {  # key <name> → prints the key, or nothing
  local f="${CREDENTIALS_DIRECTORY:-/nonexistent}/$1"
  [ -r "$f" ] && tr -d '\r\n' < "$f"
}

# ── 1. manifests ──
[ "${#manifests[@]}" -gt 0 ] || errors+=("no-manifests")
: > "$run/models.tsv"
i=0
for url in "${manifests[@]}"; do
  i=$((i + 1))
  out="$run/manifest-$i.json"
  if ! fetch "" -fsS --proto '=https' --max-time 30 -o "$out" "$url" 2> "$run/manifest-$i.err" \
     || ! jq -e '.schema == 1 and (.consumer | type == "string")
                 and (.models | type == "array" and length > 0 and all(type == "object"))' "$out" > /dev/null 2>&1; then
    errors+=("manifest-$i")
    continue
  fi
  consumer=$(jq -r '.consumer' "$out")
  [[ "$consumer" =~ $id_re ]] || { errors+=("manifest-$i-consumer"); continue; }
  # provider <TAB> id <TAB> consumer; anything malformed is a tool error.
  while IFS=$'\t' read -r provider id; do
    if { [ "$provider" != openai ] && [ "$provider" != anthropic ]; } || ! [[ "$id" =~ $id_re ]]; then
      errors+=("manifest-$i-entry")
      continue
    fi
    printf '%s\t%s\t%s\n' "$provider" "$id" "$consumer" >> "$run/models.tsv"
  done < <(jq -r '.models[] | [(.provider // "" | tostring), (.id // "" | tostring)] | @tsv' "$out")
done

# One lookup per (provider, id); consumers joined with "_" for the summary
# (summary.txt keeps only [A-Za-z0-9 =:;,.@_>-]).
sort -u "$run/models.tsv" | awk -F'\t' '
  { k = $1 "\t" $2; c[k] = (k in c) ? c[k] "_" $3 : $3; if (!(k in seen)) { seen[k] = 1; order[++n] = k } }
  END { for (j = 1; j <= n; j++) print order[j] "\t" c[order[j]] }' > "$run/lookups.tsv"
# Nothing to look up is never a clean pass.
[ -s "$run/lookups.tsv" ] || errors+=("no-models")

# ── 2. provider lookups ──
openai_key=$(key openai-api-key || true)
anthropic_key=$(key anthropic-api-key || true)
: > "$run/findings.tsv"
while IFS=$'\t' read -r provider id consumers; do
  body="$run/$provider-$id.json"
  case "$provider" in
    openai)
      [ -n "$openai_key" ] || { errors+=("openai-key"); continue; }
      header="Authorization: Bearer $openai_key"
      url="https://api.openai.com/v1/models/$id"
      extra=() ;;
    anthropic)
      [ -n "$anthropic_key" ] || { errors+=("anthropic-key"); continue; }
      header="x-api-key: $anthropic_key"
      url="https://api.anthropic.com/v1/models/$id"
      extra=(-H "anthropic-version: 2023-06-01") ;;
  esac
  crc=0
  code=$(fetch "$header" -sS --proto '=https' --max-time 30 "${extra[@]}" -o "$body" -w '%{http_code}' "$url" 2> "$run/$provider-$id.err") || crc=$?

  verdict=""
  if [ "$crc" -ne 0 ]; then
    errors+=("$id:curl$crc")
    continue
  elif [ "$code" = 404 ]; then
    verdict="gone"
  elif [ "$code" != 200 ] || ! jq -e 'type == "object"' "$body" > /dev/null 2>&1; then
    errors+=("$id:http$code")
    continue
  elif [ "$provider" = openai ]; then
    sd=$(jq -r '.shutdown_date | if type == "number" then floor | tostring elif type == "string" then . else empty end' "$body")
    if [ -z "$sd" ]; then
      unknown=$((unknown + 1))
    else
      if [[ "$sd" =~ ^[0-9]+$ ]]; then epoch=$sd
      elif ! epoch=$(date -u -d "$sd" +%s 2> /dev/null); then errors+=("$id:shutdown_date"); continue
      fi
      days=$(( (epoch - now) / 86400 ))
      day=$(date -u -d "@$epoch" +%Y-%m-%d)
      if [ "$epoch" -le "$now" ]; then verdict="gone:$day"
      elif [ "$days" -le "$warn_days" ]; then verdict="${days}d:$day"
      fi
    fi
  else
    lc=$(jq -r '.lifecycle | if type == "object" then (.status // .state // empty) elif type == "string" then . else empty end' "$body")
    case "$lc" in
      deprecated|retired) verdict="$lc" ;;
      # Unlike OpenAI's optional date, lifecycle is on every model; its
      # absence means this check's reading of the API is wrong, and that
      # must not pass as a clean week.
      "") errors+=("$id:no-lifecycle"); continue ;;
      *) ;;
    esac
  fi

  [ -n "$verdict" ] || continue
  printf '%s\t%s\t%s\t%s\n' "$provider" "$id" "$verdict" "$consumers" >> "$run/findings.tsv"
  grep -qxF -- "$id" <<< "$accepted_ids" && continue
  findings+=("$id:$verdict:$consumers")
done < "$run/lookups.tsv"

# ── verdict ──
models=$(wc -l < "$run/lookups.tsv")
{
  printf 'models=%s retiring=%s unknown=%s tool_errors=%s' \
    "$models" "${#findings[@]}" "$unknown" "${#errors[@]}"
  [ "${#findings[@]}" -eq 0 ] || printf '; retiring: %s' "$(IFS=,; echo "${findings[*]}")"
  [ "${#errors[@]}" -eq 0 ] || printf '; failed: %s' "$(IFS=,; echo "${errors[*]}")"
  printf '\n'
} > "$run/summary.txt"
cat "$run/summary.txt"

[ "${#errors[@]}" -eq 0 ] || exit 3
[ "${#findings[@]}" -eq 0 ] || exit 1
exit 0
