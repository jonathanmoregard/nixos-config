#!/usr/bin/env bash
set -euo pipefail
set -f
umask 077

usage() {
  cat >&2 <<'EOF'
Usage: smarthome-activate-package PACKAGE_PATH REVISION STATE_DIR PROFILE SERVICE HEALTH_URL
EOF
  exit 64
}

die() {
  printf 'smarthome-activate-package:' >&2
  printf ' %s' "$@" >&2
  printf '\n' >&2
  exit 1
}

[ "$#" -eq 6 ] || usage
package_path=$1
revision=$2
state_dir=$3
profile=$4
service=$5
health_url=$6

store_dir=${NIX_STORE_DIR:-/nix/store}
store_dir=${store_dir%/}
[ -n "$store_dir" ] || usage
[[ "$store_dir" == /* ]] || usage

is_store_path() {
  local candidate=$1 store_name
  [[ "$candidate" == "$store_dir"/* ]] || return 1
  store_name=${candidate#"$store_dir"/}
  [[ "$store_name" =~ ^[0123456789abcdfghijklmnpqrsvwxyz]{32}-[A-Za-z0-9+._?=-]{1,211}$ ]]
}

is_safe_absolute_path() {
  local candidate=$1
  [[ "$candidate" == /* ]] || return 1
  [ "$candidate" != / ] || return 1
  [[ "$candidate" != *$'\n'* && "$candidate" != *$'\r'* ]]
}

is_store_path "$package_path" || usage
[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || usage
is_safe_absolute_path "$state_dir" || usage
is_safe_absolute_path "$profile" || usage
if [ "$service" = - ]; then
  [ "$health_url" = - ] || usage
else
  [ "$health_url" != - ] || usage
  [[ "$service" =~ ^[A-Za-z0-9_.@:-]+$ ]] || usage
  [[ "$health_url" == http://* || "$health_url" == https://* ]] || usage
  [[ "$health_url" != *$'\n'* && "$health_url" != *$'\r'* ]] || usage
fi
[ -x "$package_path/bin/house-automationd" ] || die 'package has no executable bin/house-automationd'

mkdir -p -- "$state_dir" "$(dirname -- "$profile")" || die 'could not create state/profile directory'
chmod 0700 "$state_dir" || die 'could not secure state directory'

old_path=none
old_generation=
declare -a original_generations=()
generations_before=$(nix-env --profile "$profile" --list-generations) || \
  die 'could not list profile generations before activation'
while IFS= read -r line; do
  read -r number _ <<< "$line"
  [[ "$number" =~ ^[0-9]+$ ]] || continue
  original_generations+=("$number")
  if [[ "$line" == *'(current)'* ]]; then
    [ -z "$old_generation" ] || die 'profile has multiple current generations'
    old_generation=$number
  fi
done <<< "$generations_before"
if [ -e "$profile" ] || [ -L "$profile" ]; then
  old_path=$(readlink -f -- "$profile") || die 'could not resolve current profile'
  is_store_path "$old_path" || die 'current profile does not resolve to a store path'
  [ -x "$old_path/bin/house-automationd" ] || die 'current profile has no executable bin/house-automationd'
  [ -n "$old_generation" ] || die 'current profile has no active generation'
elif [ -n "$old_generation" ]; then
  die 'profile has an active generation but no current profile link'
fi

transaction_started=0
marker_tmp=

cleanup_marker_tmp() {
  if [ -n "$marker_tmp" ]; then
    rm -f -- "$marker_tmp" || true
    marker_tmp=
  fi
}

write_marker() {
  local marker_name=$1 marker_contents=$2
  marker_tmp=$(mktemp "$state_dir/.${marker_name}.XXXXXXXX") || return 1
  if ! printf '%s' "$marker_contents" > "$marker_tmp" || \
     ! chmod 0600 "$marker_tmp" || \
     ! mv -f -- "$marker_tmp" "$state_dir/$marker_name"; then
    cleanup_marker_tmp
    return 1
  fi
  marker_tmp=
}

printf -v success_contents 'rev=%s\npath=%s\nprevious_path=%s\n' \
  "$revision" "$package_path" "$old_path"

success_marker_committed() {
  local active_path marker_contents
  [ -f "$state_dir/last-success" ] || return 1
  active_path=$(readlink -f -- "$profile" 2>/dev/null) || return 1
  [ "$active_path" = "$package_path" ] || return 1
  # Sentinel prevents command substitution from stripping the marker's final
  # newline, which is part of the atomic commit record.
  marker_contents=$(cat "$state_dir/last-success"; printf '\036') || return 1
  [ "$marker_contents" = "$success_contents"$'\036' ]
}

health_check() {
  local attempt
  [ "$service" != - ] || return 0
  for attempt in $(seq 1 30); do
    if curl --fail --silent --show-error "$health_url" > /dev/null; then
      return 0
    fi
    [ "$attempt" -eq 30 ] || sleep 1
  done
  return 1
}

restart_and_check() {
  [ "$service" != - ] || return 0
  systemctl restart "$service" && health_check
}

rollback_profile() {
  local rollback_ok=0 profile_restored=0
  if [ "$old_path" = none ]; then
    if rm -f -- "$profile"; then
      profile_restored=1
    else
      rollback_ok=1
    fi
  else
    if nix-env --profile "$profile" --switch-generation "$old_generation" > /dev/null; then
      profile_restored=1
    else
      rollback_ok=1
    fi
  fi
  if [ "$profile_restored" -eq 1 ] && [ "$service" != - ]; then
    systemctl reset-failed "$service" || rollback_ok=1
    systemctl restart "$service" || rollback_ok=1
    health_check || rollback_ok=1
  fi
  if [ "$profile_restored" -eq 1 ]; then
    remove_new_generations || rollback_ok=1
  fi
  return "$rollback_ok"
}

remove_new_generations() {
  local generations_output line number original found
  local -a delete_generations=()
  generations_output=$(nix-env --profile "$profile" --list-generations) || return 1
  while IFS= read -r line; do
    read -r number _ <<< "$line"
    [[ "$number" =~ ^[0-9]+$ ]] || continue
    found=0
    for original in "${original_generations[@]}"; do
      [ "$number" = "$original" ] && found=1
    done
    [ "$found" -eq 1 ] || delete_generations+=("$number")
  done <<< "$generations_output"
  if [ "${#delete_generations[@]}" -gt 0 ]; then
    nix-env --profile "$profile" --delete-generations "${delete_generations[@]}" > /dev/null
  fi
}

write_failure_marker() {
  local reason=$1 rollback_state=$2 contents
  printf -v contents 'rev=%s\npath=%s\nprevious_path=%s\nreason=%s\nrollback=%s\n' \
    "$revision" "$package_path" "$old_path" "$reason" "$rollback_state"
  write_marker last-failure "$contents"
}

fail_transaction() {
  local reason=$1 rollback_state=complete status=1
  # Rollback is a critical section. A second signal must not interrupt profile
  # restoration or leave last-failure unwritten.
  trap '' HUP INT TERM
  cleanup_marker_tmp
  if ! rollback_profile; then
    rollback_state=incomplete
    status=2
  fi
  if ! write_failure_marker "$reason" "$rollback_state"; then
    status=2
  fi
  transaction_started=0
  return "$status"
}

fail_and_exit() {
  local reason=$1 status=0
  fail_transaction "$reason" || status=$?
  exit "$status"
}

on_signal() {
  local signal_name=$1
  trap '' HUP INT TERM
  if [ "$transaction_started" -eq 1 ]; then
    # Marker rename is the commit point. A signal delivered immediately after
    # it must not roll back a release already recorded as successful.
    if success_marker_committed; then
      cleanup_marker_tmp
      transaction_started=0
      if ! prune_generations; then
        die 'release committed but profile generation pruning failed'
      fi
      exit 0
    fi
    fail_and_exit "received $signal_name"
  fi
  cleanup_marker_tmp
  exit 128
}

trap 'on_signal HUP' HUP
trap 'on_signal INT' INT
trap 'on_signal TERM' TERM

prune_generations() {
  local generations_output line number keep_from index
  local -a generations=() sorted_generations=() delete_generations=()
  generations_output=$(nix-env --profile "$profile" --list-generations) || return 1
  while IFS= read -r line; do
    read -r number _ <<< "$line"
    [[ "$number" =~ ^[0-9]+$ ]] && generations+=("$number")
  done <<< "$generations_output"
  [ "${#generations[@]}" -gt 0 ] || return 1
  mapfile -t sorted_generations < <(printf '%s\n' "${generations[@]}" | sort -n)
  if [ "${#sorted_generations[@]}" -le 2 ]; then
    return 0
  fi
  keep_from=$((${#sorted_generations[@]} - 2))
  for ((index = 0; index < keep_from; index++)); do
    delete_generations+=("${sorted_generations[$index]}")
  done
  nix-env --profile "$profile" --delete-generations "${delete_generations[@]}" > /dev/null
}

# Set this before invoking nix-env: interruption can arrive after nix-env has
# mutated the profile but before control returns to Bash.
transaction_started=1
if ! nix-env --profile "$profile" --set "$package_path" > /dev/null; then
  fail_and_exit 'profile switch failed'
fi
if ! restart_and_check; then
  fail_and_exit 'service restart or health check failed'
fi
if ! write_marker last-success "$success_contents"; then
  fail_and_exit 'success marker write failed'
fi

# Success-marker rename is the commit point. Pruning is irreversible cleanup,
# so it happens only after commit and never on a rollback path.
trap '' HUP INT TERM
transaction_started=0
if ! prune_generations; then
  die 'release committed but profile generation pruning failed'
fi
cleanup_marker_tmp
trap - HUP INT TERM
