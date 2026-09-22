#!/usr/bin/env bash
set -euo pipefail
set -f
umask 077

usage() {
  cat >&2 <<'EOF'
Usage: smarthome-hydrate-release-paths.sh [--from CACHE_URL --trusted-key NAME:BASE64]... [--timeout-seconds SECONDS] [--interval SECONDS] [--attempts COUNT] PATH...

The first cache/key pair is the release-root trust anchor. Later pairs may
supply recursively referenced dependencies, but cannot authorize a root.
EOF
  exit 64
}

die() {
  printf 'smarthome-hydrate-release-paths:' >&2
  printf ' %s' "$@" >&2
  printf '\n' >&2
  exit 1
}

monotonic_milliseconds() {
  local uptime whole fraction milliseconds
  [ -r /proc/uptime ] || return 1
  IFS=' ' read -r uptime _ < /proc/uptime || return 1
  [[ "$uptime" =~ ^[0-9]+[.][0-9]+$ ]] || return 1
  whole=${uptime%%.*}
  fraction=${uptime#*.}
  milliseconds=${fraction:0:3}
  while [ "${#milliseconds}" -lt 3 ]; do
    milliseconds="${milliseconds}0"
  done
  printf '%s\n' "$((10#$whole * 1000 + 10#$milliseconds))"
}

milliseconds_as_duration() {
  local milliseconds=$1
  printf '%d.%03ds\n' \
    "$((milliseconds / 1000))" \
    "$((milliseconds % 1000))"
}

deadline_run() {
  local phase=$1 current_ms elapsed_ms remaining_ms duration status
  shift
  current_ms=$(monotonic_milliseconds) || die 'Linux monotonic clock is unavailable or malformed'
  elapsed_ms=$((current_ms - started_at_ms))
  [ "$elapsed_ms" -ge 0 ] || die 'Linux monotonic clock moved backwards'
  remaining_ms=$((timeout_ms - elapsed_ms))
  [ "$remaining_ms" -gt 0 ] || die "timed out during $phase"
  duration=$(milliseconds_as_duration "$remaining_ms")
  timeout --signal=KILL "$duration" "$@" || status=$?
  case ${status:-0} in
    0) ;;
    124|137) die "timed out during $phase" ;;
    *) return "$status" ;;
  esac
}

source_urls=()
trusted_keys=()
timeout=300
interval=5
attempts=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --from)
      [ "$#" -ge 2 ] || usage
      source_urls+=("$2")
      shift 2
      ;;
    --trusted-key)
      [ "$#" -ge 2 ] || usage
      trusted_keys+=("$2")
      shift 2
      ;;
    --timeout-seconds)
      [ "$#" -ge 2 ] || usage
      timeout=$2
      shift 2
      ;;
    --interval)
      [ "$#" -ge 2 ] || usage
      interval=$2
      shift 2
      ;;
    --attempts)
      [ "$#" -ge 2 ] || usage
      attempts=$2
      shift 2
      ;;
    --*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

[ "${#source_urls[@]}" -gt 0 ] || usage
[ "${#source_urls[@]}" -eq "${#trusted_keys[@]}" ] || usage
for index in "${!source_urls[@]}"; do
  source_url=${source_urls[$index]}
  trusted_key=${trusted_keys[$index]}
  case "$source_url" in
    https://*|file://*) ;;
    *) usage ;;
  esac
  [[ "$source_url" != *$'\n'* && "$source_url" != *$'\r'* && "$source_url" != *' '* ]] || usage

  [[ "$trusted_key" == *:* ]] || usage
  signer=${trusted_key%%:*}
  public_key=${trusted_key#*:}
  [[ "$signer" =~ ^[A-Za-z0-9._-]+$ ]] || usage
  [[ "$public_key" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || usage
  if ! decoded_key_bytes=$(printf '%s' "$public_key" | base64 --decode 2>/dev/null | wc -c); then
    usage
  fi
  [ "$decoded_key_bytes" -eq 32 ] || usage
done

primary_source_url=${source_urls[0]}
primary_trusted_key=${trusted_keys[0]}
primary_signer=${primary_trusted_key%%:*}
substituters=$(IFS=' '; printf '%s' "${source_urls[*]}")
all_trusted_keys=$(IFS=' '; printf '%s' "${trusted_keys[*]}")

[[ "$timeout" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$interval" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$attempts" =~ ^(0|[1-9][0-9]*)$ ]] || usage
# Bound user-controlled arithmetic to keep deadline calculations within the
# range supported by every Bash/NixOS target this helper runs on.
[ "${#timeout}" -le 10 ] || usage
[ "${#interval}" -le 10 ] || usage
[ "${#attempts}" -le 10 ] || usage
timeout=$((10#$timeout))
interval=$((10#$interval))
[ "$attempts" = 0 ] || attempts=$((10#$attempts))
[ "$timeout" -le 2147483647 ] || usage
[ "$interval" -le 2147483647 ] || usage
[ "$attempts" -le 2147483647 ] || usage
timeout_ms=$((timeout * 1000))
interval_ms=$((interval * 1000))

[ "$#" -gt 0 ] || usage
store_dir=${NIX_STORE_DIR:-/nix/store}
[[ "$store_dir" == /* ]] || usage
[[ "$store_dir" != *$'\n'* && "$store_dir" != *$'\r'* ]] || usage
store_dir=${store_dir%/}
[ -n "$store_dir" ] || usage

is_store_path() {
  local candidate=$1 store_name
  [[ "$candidate" == "$store_dir"/* ]] || return 1
  store_name=${candidate#"$store_dir"/}
  [[ "$store_name" =~ ^[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]{1,211}$ ]]
}

paths=("$@")
for path in "${paths[@]}"; do
  is_store_path "$path" || usage
done

started_at_ms=$(monotonic_milliseconds) || die 'Linux monotonic clock is unavailable or malformed'
attempt_count=0
while true; do
  current_ms=$(monotonic_milliseconds) || die 'Linux monotonic clock is unavailable or malformed'
  elapsed_ms=$((current_ms - started_at_ms))
  [ "$elapsed_ms" -ge 0 ] || die 'Linux monotonic clock moved backwards'
  remaining_ms=$((timeout_ms - elapsed_ms))
  [ "$remaining_ms" -gt 0 ] || die 'timed out waiting for release paths from configured caches'
  remaining_duration=$(milliseconds_as_duration "$remaining_ms")

  # A cache request can stall inside its transport. Hydration is read-only, so
  # kill the entire copy process group at the remaining hard deadline without
  # allowing a TERM grace period beyond the total budget.
  copy_status=0
  copy_diagnostics=$(timeout \
    --signal=KILL \
    "$remaining_duration" \
    nix build \
      --no-link \
      --refresh \
      --option max-jobs 0 \
      --option fallback false \
      --option builders "" \
      --option always-allow-substitutes true \
      --option substituters "$substituters" \
      --option trusted-public-keys "$all_trusted_keys" \
      "${paths[@]}" 2>&1) || copy_status=$?
  [ -z "$copy_diagnostics" ] || printf '%s\n' "$copy_diagnostics" >&2
  if [ "$copy_status" -eq 0 ]; then
    break
  fi
  case "$copy_status" in
    124|137)
      die 'timed out waiting for release paths from configured caches'
      ;;
  esac
  case "$copy_diagnostics" in
    *signature*|*Signature*)
      die 'release closure signature verification failed'
      ;;
  esac

  attempt_count=$((attempt_count + 1))
  [ "$attempts" -eq 0 ] || [ "$attempt_count" -lt "$attempts" ] || die 'release paths are not available from configured caches'

  current_ms=$(monotonic_milliseconds) || die 'Linux monotonic clock is unavailable or malformed'
  elapsed_ms=$((current_ms - started_at_ms))
  [ "$elapsed_ms" -ge 0 ] || die 'Linux monotonic clock moved backwards'
  remaining_ms=$((timeout_ms - elapsed_ms))
  [ "$remaining_ms" -gt 0 ] || die 'timed out waiting for release paths from configured caches'
  sleep_for_ms=$interval_ms
  if [ "$sleep_for_ms" -gt "$remaining_ms" ]; then
    sleep_for_ms=$remaining_ms
  fi
  sleep_duration=$(milliseconds_as_duration "$sleep_for_ms")
  sleep "$sleep_duration"
done

# `nix copy` skips paths already present in the local store. That is normally
# desirable, but it also means a bootstrap generation built locally can keep
# unsigned local metadata even when the cache has the pinned signature. Import
# the cache's signatures for the exact closure before verifying it; arbitrary
# signatures are harmless here because verification below accepts only the
# configured key.
current_ms=$(monotonic_milliseconds) || die 'Linux monotonic clock is unavailable or malformed'
elapsed_ms=$((current_ms - started_at_ms))
[ "$elapsed_ms" -ge 0 ] || die 'Linux monotonic clock moved backwards'
remaining_ms=$((timeout_ms - elapsed_ms))
[ "$remaining_ms" -gt 0 ] || die 'timed out waiting for release signatures from configured caches'
remaining_duration=$(milliseconds_as_duration "$remaining_ms")
for source_url in "${source_urls[@]}"; do
  signature_status=0
  signature_diagnostics=$(deadline_run 'release signature import' nix store copy-sigs \
    --refresh \
    --substituter "$source_url" \
    --recursive \
    "${paths[@]}" 2>&1) || signature_status=$?
  [ -z "$signature_diagnostics" ] || printf '%s\n' "$signature_diagnostics" >&2
  # A dependency cache need not contain every closure path. Final recursive
  # verification below is the authority; this pass only enriches signatures
  # for paths that predated hydration and were therefore not downloaded.
  [ "$signature_status" -eq 0 ] || \
    printf 'smarthome-hydrate-release-paths: signature import from %s was incomplete\n' \
      "$source_url" >&2
done

verify_status=0
verify_diagnostics=$(deadline_run 'local recursive verification' nix store verify \
  --recursive \
  --sigs-needed 1 \
  --option trusted-public-keys "$all_trusted_keys" \
  "${paths[@]}" 2>&1) || verify_status=$?
[ -z "$verify_diagnostics" ] || printf '%s\n' "$verify_diagnostics" >&2

case "$verify_diagnostics" in
  *"ignoring the client-specified setting 'trusted-public-keys'"*)
    die 'Nix refused the configured trusted key'
    ;;
esac
[ "$verify_status" -eq 0 ] || die 'release closure signature verification failed'

# Capture one recursive source view.  That exact JSON is rendered into a
# private immutable file-cache snapshot for signature verification and reused
# for the local metadata comparison.  Never make a second source request after
# the trust decision: doing so would compare metadata that was not verified.
source_metadata=$(deadline_run 'release cache metadata query' nix path-info --refresh --store "$primary_source_url" --json "${paths[@]}") || \
  die 'could not read release cache metadata'
for path in "${paths[@]}"; do
  printf '%s' "$source_metadata" | deadline_run 'release root signer validation' \
    jq -e --arg path "$path" --arg signer "$primary_signer:" \
      'has($path) and (.[$path].signatures | any(startswith($signer)))' \
      > /dev/null || die 'release root is not signed by the primary cache key'
done

snapshot_entries=$(printf '%s' "$source_metadata" | deadline_run 'release cache metadata validation' jq -er '
  if type != "object" or length == 0 then
    error("release cache metadata must be a nonempty object")
  elif all(to_entries[];
    ((.key | type) == "string") and
    ((.value | type) == "object") and
    ((.value.narHash | type) == "string") and
    ((.value.narHash | test("[\\r\\n]") | not)) and
    ((.value.narSize | type) == "number") and
    (.value.narSize >= 0) and
    (.value.narSize <= 9007199254740991) and
    (.value.narSize == (.value.narSize | floor)) and
    ((.value.references | type) == "array") and
    (all(.value.references[];
      (type == "string") and (test("[\\r\\n]") | not))) and
    ((.value.signatures | type) == "array") and
    (all(.value.signatures[];
      (type == "string") and (test("[\\r\\n]") | not)))
  ) then
    to_entries[] |
    [
      (.key | @base64),
      (.value.narHash | @base64),
      (.value.narSize | tostring),
      (.value.references | map(@base64) | join(",")),
      (.value.signatures | map(@base64) | join(","))
    ] | join("|")
  else
    error("release cache metadata has invalid field types")
  end
') || die 'could not validate release cache metadata'
[ -n "$snapshot_entries" ] || die 'release cache metadata is empty'

snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/smarthome-release-cache.XXXXXXXX") || \
  die 'could not create release cache metadata snapshot'
cleanup_snapshot() {
  rm -rf -- "$snapshot_dir"
}
trap cleanup_snapshot EXIT
trap 'exit 1' HUP INT TERM
chmod 700 "$snapshot_dir" || die 'could not secure release cache metadata snapshot'
{
  printf 'StoreDir: %s\n' "$store_dir"
  printf 'WantMassQuery: 1\n'
  printf 'Priority: 30\n'
} > "$snapshot_dir/nix-cache-info"

declare -A captured_paths=()
while IFS='|' read -r path_encoded nar_hash_encoded nar_size references_encoded signatures_encoded; do
  deadline_run 'release cache snapshot rendering' true
  source_path=$(deadline_run 'release cache path decoding' base64 --decode <<< "$path_encoded") || \
    die 'could not decode release cache path'
  nar_hash=$(deadline_run 'release cache hash decoding' base64 --decode <<< "$nar_hash_encoded") || \
    die 'could not decode release cache hash'
  is_store_path "$source_path" || die 'release cache metadata contains an invalid store path'
  [[ "$nar_size" =~ ^(0|[1-9][0-9]*)$ ]] || die 'release cache metadata contains an invalid NAR size'

  store_name=${source_path#"$store_dir"/}
  cache_hash=${store_name%%-*}
  [[ "$cache_hash" =~ ^[0123456789abcdfghijklmnpqrsvwxyz]{32}$ ]] || \
    die 'release cache metadata produced an unsafe cache filename'
  narinfo_path="$snapshot_dir/$cache_hash.narinfo"
  [ ! -e "$narinfo_path" ] || die 'release cache metadata contains a duplicate cache filename'

  reference_names=()
  IFS=',' read -r -a encoded_references <<< "$references_encoded"
  for encoded_reference in "${encoded_references[@]}"; do
    [ -n "$encoded_reference" ] || continue
    reference=$(deadline_run 'release cache reference decoding' base64 --decode <<< "$encoded_reference") || \
      die 'could not decode release cache reference'
    is_store_path "$reference" || die 'release cache metadata contains an invalid reference'
    reference_names+=("${reference#"$store_dir"/}")
  done
  references_line=$(IFS=' '; printf '%s' "${reference_names[*]}")

  signatures=()
  IFS=',' read -r -a encoded_signatures <<< "$signatures_encoded"
  for encoded_signature in "${encoded_signatures[@]}"; do
    [ -n "$encoded_signature" ] || continue
    signature=$(deadline_run 'release cache signature decoding' base64 --decode <<< "$encoded_signature") || \
      die 'could not decode release cache signature'
    [[ "$signature" != *$'\n'* && "$signature" != *$'\r'* ]] || \
      die 'release cache metadata contains an invalid signature'
    signatures+=("$signature")
  done

  {
    printf 'StorePath: %s\n' "$source_path"
    printf 'URL: nar/dummy\n'
    printf 'NarHash: %s\n' "$nar_hash"
    printf 'NarSize: %s\n' "$nar_size"
    printf 'References: %s\n' "$references_line"
    for signature in "${signatures[@]}"; do
      printf 'Sig: %s\n' "$signature"
    done
  } > "$narinfo_path"
  captured_paths["$source_path"]=1
done <<< "$snapshot_entries"

for path in "${paths[@]}"; do
  [ "${captured_paths[$path]+present}" = present ] || \
    die 'release cache metadata omitted a requested path'
done

# Local paths can be ultimately trusted, so verify the captured cache closure
# separately against the exact configured key.  --no-contents verifies only
# signed narinfo; local recursive verification above already hashed contents.
snapshot_verify_status=0
snapshot_verify_diagnostics=$(deadline_run 'release cache signature verification' nix store verify \
  --store "file://$snapshot_dir" \
  --sigs-needed 1 \
  --no-contents \
  --option trusted-public-keys "$primary_trusted_key" \
  "${paths[@]}" 2>&1) || snapshot_verify_status=$?
[ -z "$snapshot_verify_diagnostics" ] || printf '%s\n' "$snapshot_verify_diagnostics" >&2
[ "$snapshot_verify_status" -eq 0 ] || die 'release cache signature verification failed'

local_metadata=$(deadline_run 'hydrated release metadata query' nix path-info --json "${paths[@]}") || \
  die 'could not read hydrated release metadata'
source_contract=$(printf '%s' "$source_metadata" | deadline_run 'release cache metadata normalization' jq -S \
  'with_entries(.value |= {narHash, narSize, references})') || die 'could not normalize release cache metadata'
local_contract=$(printf '%s' "$local_metadata" | deadline_run 'hydrated release metadata normalization' jq -S \
  'with_entries(.value |= {narHash, narSize, references})') || die 'could not normalize hydrated release metadata'
[ "$source_contract" = "$local_contract" ] || die 'release closure signature verification failed'
