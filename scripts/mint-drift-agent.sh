#!/usr/bin/env bash
# Mint-side drift analyzer — finds changes made on Mint that aren't captured in nixos-config.
# Runs daily via cron. Findings written as proposals to ~/Repos/nixos-config/proposals/.
#
# Improvements over earlier rev:
#   - Reads scripts/mint-drift-dontadd.txt skip-list (explicit "do not add" decisions).
#   - Inventories existing proposals/ slugs and tells the LLM not to re-emit them.
#   - Collects more imperative-install state (npm, pip --user, pipx, cargo, flatpak runtimes).
#   - Diffs ~/.config/autostart against home/cinnamon.nix declared entries.
#   - Diffs ~/.config/systemd/user against home-manager declarations.
#   - Validates cron-line executable paths exist (catches stale paths early).
#   - Post-filters every JSON candidate against skip-list + existing-slug set.

set -euo pipefail

NIXOS_CONFIG="$HOME/Repos/nixos-config"
PROPOSALS_DIR="$NIXOS_CONFIG/proposals"
DONTADD_FILE="$NIXOS_CONFIG/scripts/mint-drift-dontadd.txt"
LOG_DIR="$HOME/.local/share/mint-drift-analyzer"
RUNLOG="$LOG_DIR/run.log"

mkdir -p "$LOG_DIR" "$PROPOSALS_DIR"

log() { echo "$(date -Iseconds): $*" >> "$RUNLOG"; }

CLAUDE="$(command -v claude 2>/dev/null || echo "$HOME/.local/bin/claude")"
if [ ! -x "$CLAUDE" ]; then
  log "claude not found at $CLAUDE, skipping"
  exit 0
fi

log "starting mint drift analysis"

# --- Load skip-list patterns (one regex per line, # comments, blanks) ---
DONTADD_PATTERNS=""
if [ -f "$DONTADD_FILE" ]; then
  DONTADD_PATTERNS=$(sed -E 's/[[:space:]]*#.*$//' "$DONTADD_FILE" | grep -v '^[[:space:]]*$' || true)
fi

# --- Existing drift-proposal filenames (full names so LLM can do semantic
#     dedup, not just literal-slug match — same drift gets different slugs
#     across days, e.g. cron-wellbeing-trackers-missing vs
#     cron-missing-wellbeing-jobs). Filter to *-mint-drift-*.md so non-drift
#     proposals (dellan-de-switch, RSI tickets, umbrella mint-drift.md)
#     don't poison the dedup pool. ---
EXISTING_DRIFT_FILENAMES=$(ls "$PROPOSALS_DIR" 2>/dev/null \
  | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}-mint-drift-.+\.md$' \
  | sort -u || true)

# --- gsettings dump for schemas we care about ---
GSETTINGS=""
for schema in \
  org.cinnamon \
  org.cinnamon.sounds \
  org.cinnamon.desktop.interface \
  org.cinnamon.desktop.sound \
  org.cinnamon.desktop.peripherals.keyboard \
  org.cinnamon.desktop.peripherals.touchpad \
  org.cinnamon.gestures \
  org.cinnamon.desktop.default-applications.terminal \
  org.cinnamon.settings-daemon.plugins.color \
  org.cinnamon.settings-daemon.plugins.power \
  org.cinnamon.desktop.wm.preferences \
  org.gnome.desktop.interface \
  org.gnome.desktop.sound \
  org.gnome.desktop.wm.preferences \
  org.nemo.preferences; do
  GSETTINGS+="
=== $schema ===
$(gsettings list-recursively "$schema" 2>/dev/null || echo '(not available)')
"
done

# --- apt user-installed packages ---
APT_MANUAL=$(apt-mark showmanual 2>/dev/null | sort || echo '(unavailable)')

# --- flatpak apps + runtimes (apps + runtime versions both signal install state) ---
FLATPAK_APPS=$(flatpak list --app --columns=name,application 2>/dev/null || echo '(none or not installed)')
FLATPAK_RUNTIMES=$(flatpak list --runtime --columns=name,branch 2>/dev/null || echo '(none or not installed)')

# --- npm globals across all common prefixes ---
NPM_GLOBALS=""
for prefix in "$HOME/.local/share/npm-global" "$HOME/.npm-global" "/usr/local"; do
  if [ -d "$prefix/lib/node_modules" ]; then
    NPM_GLOBALS+="$prefix:
$(ls "$prefix/lib/node_modules" 2>/dev/null | grep -v '^\.' || true)
"
  fi
done
[ -z "$NPM_GLOBALS" ] && NPM_GLOBALS="(none)"

# --- pip --user installs ---
PIP_USER=$(pip list --user --format=freeze 2>/dev/null | head -100 || echo '(unavailable)')
PIPX_LIST=$(pipx list --short 2>/dev/null || echo '(unavailable)')

# --- cargo bin (rust binaries installed via cargo install) ---
CARGO_BIN="(none)"
if [ -d "$HOME/.cargo/bin" ]; then
  CARGO_BIN=$(ls "$HOME/.cargo/bin" 2>/dev/null | grep -vE '^(rustc|cargo|rustup|rustdoc|rust-)' || echo '(only rustup-managed)')
fi

# --- autostart entries ---
AUTOSTART=$(ls ~/.config/autostart/*.desktop 2>/dev/null | xargs -I{} basename {} | sort || echo '(none)')

# --- autostart diff: live vs declared in cinnamon.nix ---
DECLARED_AUTOSTART_NAMES=$(grep -oE '\.config/autostart/[^"]+\.desktop' "$NIXOS_CONFIG/home/cinnamon.nix" 2>/dev/null \
  | sed 's|.*/||' | sort -u || true)
UNDECLARED_AUTOSTART=$(comm -23 <(echo "$AUTOSTART" | sort -u) <(echo "$DECLARED_AUTOSTART_NAMES" | sort -u) 2>/dev/null || echo '')
[ -z "$UNDECLARED_AUTOSTART" ] && UNDECLARED_AUTOSTART="(none — all autostart entries declared)"

# --- dotfiles symlink status. HM-managed regular files (home.file.<x>.text)
#     end up as plain regular files at the target path, NOT symlinks into
#     the nix store, so a naive "symlink? else UNTRACKED" check false-flags
#     them every run. Skip files declared via home.file in any home/*.nix. ---
DECLARED_HM_FILES=$(grep -hoE 'home\.file\.\"[^\"]+\"' "$NIXOS_CONFIG"/home/*.nix 2>/dev/null \
  | sed -E 's/home\.file\.\"([^\"]+)\"/\1/' | sort -u || true)
is_hm_declared() {
  local f="$1"
  # strip leading $HOME/ if present
  local rel="${f#$HOME/}"
  # also strip leading ~/
  rel="${rel#~/}"
  echo "$DECLARED_HM_FILES" | grep -qFx "$rel"
}
DOTFILES_STATUS=""
for f in ~/.zshrc ~/.gitconfig ~/.huskyrc ~/.zshenv ~/.p10k.zsh \
         ~/.config/git/ignore ~/.config/ghostty/config.ghostty \
         ~/.config/kitty/kitty.conf ~/.xbindkeysrc; do
  if [ -L "$f" ]; then
    DOTFILES_STATUS+="  symlinked: $f -> $(readlink "$f")\n"
  elif [ -f "$f" ]; then
    if is_hm_declared "$f"; then
      DOTFILES_STATUS+="  declared (HM home.file regular): $f\n"
    else
      DOTFILES_STATUS+="  UNTRACKED file: $f\n"
    fi
  fi
done

# --- systemd user units (enabled, non-static) ---
SYSTEMD_USER_ENABLED=$(systemctl --user list-unit-files --state=enabled 2>/dev/null \
  | awk 'NR>1 && $1 ~ /\.(service|timer|target|socket)$/ {print $1}' | sort -u || echo '(unavailable)')

# --- ~/.config/systemd/user/ (manually placed unit files) ---
SYSTEMD_USER_FILES=$(find ~/.config/systemd/user/ -name "*.service" -o -name "*.timer" 2>/dev/null \
  | xargs -I{} basename {} | sort -u || echo '(none)')

# --- systemd user units: live vs declared in nixos-config ---
DECLARED_USER_UNITS=$(grep -hoE 'systemd\.user\.(services|timers)\.[A-Za-z0-9_-]+' "$NIXOS_CONFIG"/home/*.nix 2>/dev/null \
  | awk -F. '{print $NF}' | sort -u || true)
UNDECLARED_USER_UNITS=$(comm -23 \
  <(echo "$SYSTEMD_USER_FILES" | sed 's/\.\(service\|timer\)$//' | sort -u) \
  <(echo "$DECLARED_USER_UNITS" | sort -u) 2>/dev/null || echo '')
[ -z "$UNDECLARED_USER_UNITS" ] && UNDECLARED_USER_UNITS="(none — all user units declared)"

# --- systemd system units placed by user (not by NixOS) ---
SYSTEMD_SYSTEM_CUSTOM=$(ls /etc/systemd/system/ 2>/dev/null \
  | grep -E '\.(service|timer|socket)$' \
  | grep -vE '^(multi-user|graphical|getty)\.target' | sort -u || echo '(none)')

# --- ~/.local/share/sounds ---
SOUNDS=$(ls ~/.local/share/sounds/ 2>/dev/null || echo '(empty)')

# --- crontab + path-validity check.
#     Strip schedule (5 fields OR @reboot/@daily/etc), then -e-test every
#     absolute path token in the remaining command. Ignores redirect
#     operators (>>, >, 2>&1, <) and their operands.
CRONTAB=$(crontab -l 2>/dev/null || echo '(empty)')
CRON_INVALID=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  echo "$line" | grep -qE '^[A-Z_]+=|^[[:space:]]*#' && continue

  # Strip schedule: either `@token` (1 field) or 5 cron fields.
  remainder=""
  if echo "$line" | grep -qE '^[[:space:]]*@'; then
    remainder=$(echo "$line" | awk '{$1=""; print substr($0, 2)}')
  else
    remainder=$(echo "$line" | awk '{$1=$2=$3=$4=$5=""; print substr($0, 6)}')
  fi

  # Tokenize remainder; collect absolute paths that aren't redirect operands.
  prev_was_redirect=0
  for tok in $remainder; do
    case "$tok" in
      '>>'|'>'|'<'|'2>'|'2>&1'|'&>'|'|') prev_was_redirect=1; continue ;;
    esac
    if [ "$prev_was_redirect" = "1" ]; then
      prev_was_redirect=0
      continue
    fi
    case "$tok" in
      /*)
        if [ ! -e "$tok" ]; then
          CRON_INVALID+="  MISSING: $tok  (line: $line)\n"
        fi
        ;;
    esac
  done
done <<< "$CRONTAB"
[ -z "$CRON_INVALID" ] && CRON_INVALID="(all absolute paths in cron entries exist)"

# --- key nixos-config files (input to LLM for diff) ---
CONFIG=""
for f in \
  home/jonathan.nix \
  home/jonathan-linux.nix \
  home/desktop-apps.nix \
  home/cinnamon.nix \
  home/ghostty.nix \
  home/kitty.nix \
  home/claude-services.nix \
  modules/nixos/desktop.nix \
  modules/nixos/laptop.nix \
  modules/nixos/tailscale.nix; do
  full="$NIXOS_CONFIG/$f"
  if [ -f "$full" ]; then
    CONFIG+="
=== $f ===
$(cat "$full")
"
  fi
done

DATE=$(date +%Y-%m-%d)

PROMPT=$(cat <<PROMPT_EOF
You are a drift analyzer for a Linux Mint 22.2 / Cinnamon system being mirrored into a NixOS config.

Your goal: find things on the live Mint system NOT yet captured in nixos-config that would be LOST on a fresh install. Be CONSERVATIVE — false positives are worse than misses, since they generate review noise.

## Existing drift proposals already on disk (filename = date + slug)

The following proposals have ALREADY been filed. For each candidate you
consider emitting, ask: "Is this conceptually the same drift as one of
these, even if my slug wording differs?" If yes, SKIP. The point is to
avoid the historical pattern where the same drift was proposed three
times under three slug variants (e.g. \`cron-wellbeing-trackers-missing\`
on day 1, \`cron-missing-wellbeing-jobs\` on day 2,
\`cron-wellbeing-jobs-missing\` on day 3).

$EXISTING_DRIFT_FILENAMES

## Skip-list (do NOT propose anything matching these regex patterns)

$DONTADD_PATTERNS

## Live Mint state

### gsettings
$GSETTINGS

### apt user-installed packages (apt-mark showmanual)
$APT_MANUAL

### Flatpak apps
$FLATPAK_APPS

### Flatpak runtimes
$FLATPAK_RUNTIMES

### npm globals
$NPM_GLOBALS

### pip --user
$PIP_USER

### pipx
$PIPX_LIST

### cargo bin (excluding rustup-managed)
$CARGO_BIN

### Autostart entries (~/.config/autostart/)
$AUTOSTART

### Autostart entries NOT declared in home/cinnamon.nix
$UNDECLARED_AUTOSTART

### Systemd user units (enabled)
$SYSTEMD_USER_ENABLED

### ~/.config/systemd/user/ files
$SYSTEMD_USER_FILES

### Systemd user units NOT declared in home-manager (.nix files)
$UNDECLARED_USER_UNITS

### Custom systemd system units (/etc/systemd/system/)
$SYSTEMD_SYSTEM_CUSTOM

### Dotfile tracking status
$(printf "%s" "$DOTFILES_STATUS")

### ~/.local/share/sounds
$SOUNDS

### User crontab
$CRONTAB

### Cron lines with missing executable paths
$(printf "%s" "$CRON_INVALID")

## Current nixos-config (excerpts)
$CONFIG

## Instructions

1. Compare live Mint state against the declared nixos-config. Flag gaps.
2. Categories worth scanning, in priority order:
   - Cron lines whose executable doesn't exist (broken cron jobs).
   - Autostart entries undeclared (won't fire on fresh install).
   - Systemd user units undeclared (won't run on fresh install).
   - npm/pip/pipx/cargo binaries that the user appears to depend on.
   - Custom system services in /etc/systemd/system/ (won't survive rebuild).
   - apt packages not in desktop-apps.nix or systemPackages, EXCLUDING
     Mint defaults like cinnamon-*, mint-*, xapp-*, mate-*, libreoffice-*,
     firefox-*, thunderbird-* (these come with the distro).
   - Flatpak apps + runtimes not declared.
   - gsettings keys whose values diverge from declared dconf.settings.
   - Untracked dotfiles.
3. For each candidate, FIRST check:
   a) Does its slug match any existing proposal slug? → SKIP.
   b) Does its slug or title match any skip-list regex? → SKIP.
4. Generate slugs in kebab-case, descriptive (e.g. \`pip-user-keyring-not-tracked\`).
5. Output ONLY a JSON array (no preamble, no markdown fence). If nothing to report, output exactly: NO_DRIFT

[
  {
    "slug": "short-kebab-case-id",
    "title": "One-line problem summary",
    "body": "Problem description paragraph, ≤ 6 lines.",
    "fix": "exact nix snippet OR shell command to apply",
    "category": "cron|autostart|systemd|package|gsettings|dotfile|other"
  },
  ...
]

Be ruthless about deduplication. When in doubt, skip.
PROMPT_EOF
)

# --- Pre-LLM signal-counts log line.
#     Surfaces silent regressions in upstream collection (e.g. broken
#     gsettings dump → empty prompt → spurious NO_DRIFT). If every count
#     drops to zero on a host that previously had signal, something
#     broke in collection, not in the world.
count_lines() { echo "$1" | grep -cvE '^\s*$|^\s*#|^\s*\(' || true; }
log "candidates: apt=$(count_lines "$APT_MANUAL") flatpak-apps=$(count_lines "$FLATPAK_APPS") flatpak-rt=$(count_lines "$FLATPAK_RUNTIMES") npm=$(count_lines "$NPM_GLOBALS") pip=$(count_lines "$PIP_USER") pipx=$(count_lines "$PIPX_LIST") cargo=$(count_lines "$CARGO_BIN") autostart-undeclared=$(count_lines "$UNDECLARED_AUTOSTART") sysd-user-undeclared=$(count_lines "$UNDECLARED_USER_UNITS") sysd-system-custom=$(count_lines "$SYSTEMD_SYSTEM_CUSTOM") cron-invalid=$(count_lines "$CRON_INVALID")"

# --- Run LLM. Don't let a non-zero exit kill the whole script before we
#     log the rc — set -e is on, so capture rc via temporary disable.
set +e
OUTPUT=$("$CLAUDE" --model claude-sonnet-4-6 --print "$PROMPT" 2>> "$RUNLOG")
LLM_RC=$?
set -e
if [ "$LLM_RC" -ne 0 ]; then
  log "LLM call failed with rc=$LLM_RC; see runlog for stderr"
  exit 1
fi

if [ "$OUTPUT" = "NO_DRIFT" ]; then
  log "no drift detected"
  exit 0
fi

TMPJSON=$(mktemp)
printf '%s' "$OUTPUT" > "$TMPJSON"

if ! jq -e '.' "$TMPJSON" > /dev/null 2>&1; then
  log "JSON parse error — raw output: $(head -5 "$TMPJSON")"
  rm -f "$TMPJSON"
  exit 1
fi

WRITTEN=0
SKIPPED_DUP=0
SKIPPED_DONTADD=0

# Build a regex that matches any skip-list pattern (alternation)
SKIP_REGEX=""
if [ -n "$DONTADD_PATTERNS" ]; then
  SKIP_REGEX=$(echo "$DONTADD_PATTERNS" | tr '\n' '|' | sed 's/|$//')
fi

while IFS= read -r item; do
  slug=$(printf '%s' "$item" | jq -r '.slug // "unknown"')
  title=$(printf '%s' "$item" | jq -r '.title // ""')
  body=$(printf '%s' "$item" | jq -r '.body // ""')
  fix=$(printf '%s' "$item" | jq -r '.fix // ""')
  category=$(printf '%s' "$item" | jq -r '.category // "other"')

  # Post-filter: skip-list match against slug OR lowercased title
  if [ -n "$SKIP_REGEX" ]; then
    if echo "$slug" | grep -qE "$SKIP_REGEX" \
      || echo "$title" | tr '[:upper:]' '[:lower:]' | grep -qE "$SKIP_REGEX"; then
      log "skipped (don't-add list match): $slug"
      SKIPPED_DONTADD=$((SKIPPED_DONTADD + 1))
      continue
    fi
  fi

  # Post-filter: existing-proposal slug match (ignore date prefix)
  if ls "$PROPOSALS_DIR" 2>/dev/null | grep -qE "^[0-9-]+-mint-drift-${slug}\.md$"; then
    log "skipped (duplicate slug): $slug"
    SKIPPED_DUP=$((SKIPPED_DUP + 1))
    continue
  fi

  outfile="$PROPOSALS_DIR/$DATE-mint-drift-${slug}.md"
  [ -f "$outfile" ] && {
    log "skipped (file exists today): $outfile"
    SKIPPED_DUP=$((SKIPPED_DUP + 1))
    continue
  }

  printf '%s\n' \
    "---" \
    "status: proposed" \
    "category: drift" \
    "subcategory: $category" \
    "date: $DATE" \
    "source: mint-drift-agent" \
    "---" \
    "" \
    "## $title" \
    "" \
    "$body" \
    "" \
    '```' \
    "$fix" \
    '```' \
    > "$outfile"
  WRITTEN=$((WRITTEN + 1))
done < <(jq -c '.[]' "$TMPJSON")

rm -f "$TMPJSON"

log "drift run complete: $WRITTEN new, $SKIPPED_DUP duplicates, $SKIPPED_DONTADD skipped (don't-add)"
