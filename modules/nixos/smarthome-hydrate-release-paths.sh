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

# Render metadata captured from either the local store or the primary cache
# into an immutable file-cache view. Deliberately omit CA metadata: every path
# in these snapshots must prove an actual signature from the supplied keys,
# even when Nix would otherwise trust content-addressed or locally-built data.
render_metadata_snapshot() {
  local target_dir=$1 snapshot_entries path_encoded nar_hash_encoded nar_size
  local references_encoded signatures_encoded source_path nar_hash store_name
  local cache_hash narinfo_path encoded_reference reference references_line
  local encoded_signature signature
  local -a encoded_references reference_names encoded_signatures signatures

  snapshot_entries=$(printf '%s' "$snapshot_metadata" | deadline_run 'release metadata validation' jq -er '
    if type != "object" or length == 0 then
      error("release metadata must be a nonempty object")
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
      error("release metadata has invalid field types")
    end
  ') || die 'could not validate release metadata'
  [ -n "$snapshot_entries" ] || die 'release metadata is empty'

  chmod 700 "$target_dir" || die 'could not secure release metadata snapshot'
  {
    printf 'StoreDir: %s\n' "$store_dir"
    printf 'WantMassQuery: 1\n'
    printf 'Priority: 30\n'
  } > "$target_dir/nix-cache-info"

  unset captured_paths
  declare -gA captured_paths=()
  while IFS='|' read -r path_encoded nar_hash_encoded nar_size references_encoded signatures_encoded; do
    deadline_run 'release metadata snapshot rendering' true
    source_path=$(deadline_run 'release metadata path decoding' base64 --decode <<< "$path_encoded") || \
      die 'could not decode release metadata path'
    nar_hash=$(deadline_run 'release metadata hash decoding' base64 --decode <<< "$nar_hash_encoded") || \
      die 'could not decode release metadata hash'
    is_store_path "$source_path" || die 'release metadata contains an invalid store path'
    [[ "$nar_size" =~ ^(0|[1-9][0-9]*)$ ]] || die 'release metadata contains an invalid NAR size'

    store_name=${source_path#"$store_dir"/}
    cache_hash=${store_name%%-*}
    [[ "$cache_hash" =~ ^[0123456789abcdfghijklmnpqrsvwxyz]{32}$ ]] || \
      die 'release metadata produced an unsafe cache filename'
    narinfo_path="$target_dir/$cache_hash.narinfo"
    [ ! -e "$narinfo_path" ] || die 'release metadata contains a duplicate cache filename'

    reference_names=()
    IFS=',' read -r -a encoded_references <<< "$references_encoded"
    for encoded_reference in "${encoded_references[@]}"; do
      [ -n "$encoded_reference" ] || continue
      reference=$(deadline_run 'release metadata reference decoding' base64 --decode <<< "$encoded_reference") || \
        die 'could not decode release metadata reference'
      is_store_path "$reference" || die 'release metadata contains an invalid reference'
      reference_names+=("${reference#"$store_dir"/}")
    done
    references_line=$(IFS=' '; printf '%s' "${reference_names[*]}")

    signatures=()
    IFS=',' read -r -a encoded_signatures <<< "$signatures_encoded"
    for encoded_signature in "${encoded_signatures[@]}"; do
      [ -n "$encoded_signature" ] || continue
      signature=$(deadline_run 'release metadata signature decoding' base64 --decode <<< "$encoded_signature") || \
        die 'could not decode release metadata signature'
      [[ "$signature" != *$'\n'* && "$signature" != *$'\r'* ]] || \
        die 'release metadata contains an invalid signature'
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
}

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
allowed_signer_prefixes=()
for trusted_key in "${trusted_keys[@]}"; do
  allowed_signer_prefixes+=("${trusted_key%%:*}:")
done
allowed_signer_prefixes_json=$(printf '%s\n' "${allowed_signer_prefixes[@]}" | \
  deadline_run 'allowed signer list encoding' jq -Rsc \
    'split("\n") | map(select(length > 0))') || die 'could not encode allowed cache signers'

signature_attempt=0
while true; do
  for source_url in "${source_urls[@]}"; do
    signature_status=0
    signature_diagnostics=$(deadline_run 'release signature import' nix store copy-sigs \
      --refresh \
      --substituter "$source_url" \
      --recursive \
      "${paths[@]}" 2>&1) || signature_status=$?
    [ -z "$signature_diagnostics" ] || printf '%s\n' "$signature_diagnostics" >&2
    # A dependency cache need not contain every closure path. Closure-wide
    # signer validation below decides whether this full import pass succeeded.
    [ "$signature_status" -eq 0 ] || \
      printf 'smarthome-hydrate-release-paths: signature import from %s was incomplete\n' \
        "$source_url" >&2
  done

  local_closure_metadata=$(deadline_run 'hydrated closure metadata query' \
    nix path-info --json --recursive "${paths[@]}") || die 'could not read hydrated closure metadata'
  signer_validation_status=0
  printf '%s' "$local_closure_metadata" | deadline_run 'hydrated closure signer validation' \
    jq -e --argjson allowed "$allowed_signer_prefixes_json" '
      type == "object" and length > 0 and
      all(to_entries[];
        ((.value.signatures | type) == "array") and
        (.value.signatures as $signatures |
          [
            $signatures[] as $signature |
            $allowed[] as $prefix |
            select($signature | startswith($prefix))
          ] | length > 0)
      )
    ' > /dev/null || signer_validation_status=$?
  [ "$signer_validation_status" -eq 0 ] && break

  signature_attempt=$((signature_attempt + 1))
  [ "$attempts" -eq 0 ] || [ "$signature_attempt" -lt "$attempts" ] || \
    die 'release closure contains a path without an allowed cache signature'
  deadline_run 'release signature retry delay' sleep \
    "$(milliseconds_as_duration "$interval_ms")" || true
done

snapshot_dirs=()
cleanup_snapshots() {
  local snapshot
  for snapshot in "${snapshot_dirs[@]}"; do
    rm -rf -- "$snapshot"
  done
}
trap cleanup_snapshots EXIT
trap 'exit 1' HUP INT TERM

closure_snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/smarthome-release-closure.XXXXXXXX") || \
  die 'could not create release closure metadata snapshot'
snapshot_dirs+=("$closure_snapshot_dir")
snapshot_metadata=$local_closure_metadata
render_metadata_snapshot "$closure_snapshot_dir"

closure_snapshot_verify_status=0
closure_snapshot_verify_diagnostics=$(deadline_run 'release closure cache signature verification' \
  nix store verify \
    --store "file://$closure_snapshot_dir" \
    --recursive \
    --sigs-needed 1 \
    --no-contents \
    --option trusted-public-keys "$all_trusted_keys" \
    "${paths[@]}" 2>&1) || closure_snapshot_verify_status=$?
[ -z "$closure_snapshot_verify_diagnostics" ] || \
  printf '%s\n' "$closure_snapshot_verify_diagnostics" >&2
case "$closure_snapshot_verify_diagnostics" in
  *"ignoring the client-specified setting 'trusted-public-keys'"*)
    die 'Nix refused the configured trusted keys'
    ;;
esac
[ "$closure_snapshot_verify_status" -eq 0 ] || \
  die 'release closure cache signature verification failed'

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

# Capture one primary-cache view for the requested release roots. That exact
# JSON is rendered into a private immutable file-cache snapshot for signature
# verification and reused for the local metadata comparison. Never make a
# second source request after the trust decision: doing so would compare
# metadata that was not verified.
source_metadata=$(deadline_run 'release cache metadata query' nix path-info --refresh --store "$primary_source_url" --json "${paths[@]}") || \
  die 'could not read release cache metadata'
for path in "${paths[@]}"; do
  printf '%s' "$source_metadata" | deadline_run 'release root signer validation' \
    jq -e --arg path "$path" --arg signer "$primary_signer:" \
      'has($path) and (.[$path].signatures | any(startswith($signer)))' \
      > /dev/null || die 'release root is not signed by the primary cache key'
done

root_snapshot_dir=$(mktemp -d "${TMPDIR:-/tmp}/smarthome-release-root.XXXXXXXX") || \
  die 'could not create release root metadata snapshot'
snapshot_dirs+=("$root_snapshot_dir")
snapshot_metadata=$source_metadata
render_metadata_snapshot "$root_snapshot_dir"

for path in "${paths[@]}"; do
  [ "${captured_paths[$path]+present}" = present ] || \
    die 'release cache metadata omitted a requested path'
done

# Verify captured primary-cache root metadata against the exact primary key.
# Full closure metadata was verified above against the configured key union;
# --no-contents here keeps this second check scoped to root-signature policy.
snapshot_verify_status=0
snapshot_verify_diagnostics=$(deadline_run 'release cache signature verification' nix store verify \
  --store "file://$root_snapshot_dir" \
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
