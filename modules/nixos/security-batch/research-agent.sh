# security-batch runner: research-agent weekly sweep (runs under
# modules/nixos/security-batch.nix; contract in that file's header).
#
# 1. vulnix on both microVM runner closures. Finding = a CVE with CVSSv3
#    >= 7.0 that is not in the previous passing run and not accepted.
#    vulnix alone, not a vulnxscan consensus: vulnxscan adds grype and OSV
#    downloads (two more network dependencies, ~10x the runtime) for a
#    weekly diff whose noise is already bounded by "new since last pass".
#    CVEs NVD has not scored yet are counted, not alerted; once scored >= 7
#    they appear as new and alert then.
# 2. systemd-analyze security on the units that confine the guests. Finding
#    = an exposure score higher than in the previous passing run, unless
#    accepted.txt allows that unit up to the new score.
#
# accepted.txt: one finding per line, `#` comments.
#   CVE-2025-12345            why it does not apply
#   microvm@scraper.service 9.6   why the regression is fine
#
# Exit: 0 clean (also: first run, which seeds), 1 new findings, 3 a tool
# failed (every step still runs). summary.txt: counts and IDs only.
set -euo pipefail

vms=(research-agent scraper)
units=(
  microvm@research-agent.service microvm@scraper.service
  microvm-virtiofsd@research-agent.service microvm-virtiofsd@scraper.service
  research-agent-healthcheck.service scraper-healthcheck.service
)
min_cvss=7.0
microvms_dir=${SECURITY_BATCH_MICROVMS_DIR:-/var/lib/microvms}

run=${RUN_DIR:?}
prev=${PREVIOUS_DIR:-}
accepted=${ACCEPTED_FINDINGS:-/dev/null}
errors=()

accepted_cves=$(grep -oE '^[[:space:]]*CVE-[0-9]{4}-[0-9]+' "$accepted" | tr -d ' \t' | sort -u || true)

# ── 1. vulnix ──
: > "$run/cves.all"
for vm in "${vms[@]}"; do
  out="$run/vulnix-$vm.json"
  rc=0
  vulnix --closure --json --cache-dir "${CACHE_DIRECTORY:-$run}/vulnix" \
    "$microvms_dir/$vm/current" > "$out" 2> "$run/vulnix-$vm.err" || rc=$?
  # vulnix: 0 = nothing found, 2 = vulnerable; anything else is a failure.
  if { [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; } || ! jq -e 'type == "array"' "$out" > /dev/null 2>&1; then
    errors+=("vulnix-$vm")
    continue
  fi
  jq -r '.[] | .cvssv3_basescore as $s | .affected_by[] | "\(.)\t\($s[.] // "none")"' "$out" >> "$run/cves.all"
done
awk -F'\t' -v min="$min_cvss" '$2 != "none" && $2 + 0 >= min + 0 { print $1 }' "$run/cves.all" \
  | grep -E '^CVE-[0-9]{4}-[0-9]+$' | sort -u > "$run/cves.txt" || true
unscored=$(awk -F'\t' '$2 == "none" { print $1 }' "$run/cves.all" | sort -u | wc -l)

new_cves=()
if [ -n "$prev" ] && [ -f "$prev/cves.txt" ]; then
  mapfile -t new_cves < <(comm -23 "$run/cves.txt" "$prev/cves.txt" | comm -23 - <(printf '%s\n' "$accepted_cves" | sed '/^$/d'))
fi

# ── 2. systemd-analyze security ──
: > "$run/scores.tsv"
for unit in "${units[@]}"; do
  score=$(systemd-analyze security --no-pager "$unit" 2> /dev/null \
    | sed -n 's/^.*Overall exposure level for .*: \([0-9][0-9]*\.[0-9]\).*$/\1/p' | tail -1 || true)
  if [ -z "$score" ]; then
    errors+=("systemd-analyze:$unit")
    continue
  fi
  printf '%s\t%s\n' "$unit" "$score" >> "$run/scores.tsv"
done

regressions=()
if [ -n "$prev" ] && [ -f "$prev/scores.tsv" ]; then
  while IFS=$'\t' read -r unit score; do
    old=$(awk -F'\t' -v u="$unit" '$1 == u { print $2 }' "$prev/scores.tsv")
    [ -n "$old" ] || continue
    allowed=$(awk -v u="$unit" '$1 == u { print $2 }' "$accepted" | tail -1)
    if awk -v n="$score" -v o="$old" -v a="${allowed:-}" \
         'BEGIN { exit !(n + 0 > o + 0 && (a == "" || n + 0 > a + 0)) }'; then
      regressions+=("$unit $old>$score")
    fi
  done < "$run/scores.tsv"
fi

# ── verdict ──
high=$(wc -l < "$run/cves.txt")
seed=""; [ -n "$prev" ] || seed=" seeded=yes"
{
  printf 'new_cves=%s regressions=%s tool_errors=%s high_cves=%s unscored=%s%s' \
    "${#new_cves[@]}" "${#regressions[@]}" "${#errors[@]}" "$high" "$unscored" "$seed"
  [ "${#new_cves[@]}" -eq 0 ] || printf '; new: %s' "$(IFS=,; echo "${new_cves[*]}")"
  [ "${#regressions[@]}" -eq 0 ] || printf '; regressed: %s' "$(IFS=,; echo "${regressions[*]}")"
  [ "${#errors[@]}" -eq 0 ] || printf '; failed: %s' "$(IFS=,; echo "${errors[*]}")"
  printf '\n'
} > "$run/summary.txt"
cat "$run/summary.txt"

[ "${#errors[@]}" -eq 0 ] || exit 3
[ "${#new_cves[@]}" -eq 0 ] && [ "${#regressions[@]}" -eq 0 ] || exit 1
exit 0
