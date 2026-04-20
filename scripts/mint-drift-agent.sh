#!/usr/bin/env bash
# Mint-side drift analyzer — finds changes made on Mint that aren't captured in nixos-config.
# Runs daily via cron. Findings written as proposals to ~/Repos/nixos-config/proposals/

set -euo pipefail

NIXOS_CONFIG="$HOME/Repos/nixos-config"
PROPOSALS_DIR="$NIXOS_CONFIG/proposals"
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

# --- flatpak apps ---
FLATPAK=$(flatpak list --app --columns=name,application 2>/dev/null || echo '(none or not installed)')

# --- autostart entries ---
AUTOSTART=$(ls ~/.config/autostart/*.desktop 2>/dev/null | xargs -I{} basename {} || echo '(none)')

# --- dotfiles symlink status ---
DOTFILES_STATUS=""
for f in ~/.zshrc ~/.gitconfig ~/.huskyrc ~/.zshenv ~/.p10k.zsh \
         ~/.config/git/ignore ~/.config/ghostty/config.ghostty; do
  if [ -L "$f" ]; then
    DOTFILES_STATUS+="  symlinked: $f -> $(readlink "$f")\n"
  elif [ -f "$f" ]; then
    DOTFILES_STATUS+="  UNTRACKED file: $f\n"
  fi
done

# --- systemd user units (enabled, non-static) ---
SYSTEMD_UNITS=$(systemctl --user list-unit-files --state=enabled 2>/dev/null | grep -v "^UNIT\|^$\|listed" | awk '{print $1}' || echo '(unavailable)')

# --- ~/.config/systemd/user/ (manually placed unit files) ---
SYSTEMD_USER_FILES=$(find ~/.config/systemd/user/ -name "*.service" -o -name "*.timer" 2>/dev/null | sort || echo '(none)')

# --- ~/.local/share/sounds ---
SOUNDS=$(ls ~/.local/share/sounds/ 2>/dev/null || echo '(empty)')

# --- crontab ---
CRONTAB=$(crontab -l 2>/dev/null || echo '(empty)')

# --- key nixos-config files ---
CONFIG=""
for f in \
  home/jonathan.nix \
  home/jonathan-linux.nix \
  home/desktop-apps.nix \
  home/cinnamon.nix \
  home/ghostty.nix \
  modules/nixos/desktop.nix; do
  full="$NIXOS_CONFIG/$f"
  if [ -f "$full" ]; then
    CONFIG+="
=== $f ===
$(cat "$full")
"
  fi
done

DATE=$(date +%Y-%m-%d)
PROPOSAL_FILE="$PROPOSALS_DIR/$DATE-mint-drift.md"

PROMPT=$(cat <<PROMPT_EOF
You are a drift analyzer for a Linux Mint 22.2 / Cinnamon system being mirrored into a NixOS config.

Your goal: find things on the live Mint system NOT yet captured in nixos-config that would be LOST on a fresh install.

## Live Mint state

### gsettings
$GSETTINGS

### apt user-installed packages (apt-mark showmanual)
$APT_MANUAL

### Flatpak apps
$FLATPAK

### Autostart entries (~/.config/autostart/)
$AUTOSTART

### Systemd user units (enabled)
$SYSTEMD_UNITS

### ~/.config/systemd/user/ files
$SYSTEMD_USER_FILES

### Dotfile tracking status
$(printf "%s" "$DOTFILES_STATUS")

### ~/.local/share/sounds
$SOUNDS

### User crontab
$CRONTAB

## Current nixos-config
$CONFIG

## Instructions

1. Compare live Mint state to what is declared in the config.
2. Flag gaps in these categories:
   - gsettings values that differ from dconf.settings in cinnamon.nix
   - apt packages not present in desktop-apps.nix or home.packages
   - Flatpak apps not in config
   - Autostart entries not in config
   - Untracked dotfiles (not symlinked + not home.file managed)
   - Sounds or assets in ~/.local/share not in assets/
   - Cron jobs not captured anywhere
   - Systemd user services/timers enabled on live but not declared in home-manager (systemd.user.services/timers)
3. For each gap, write the exact Nix snippet OR shell command to fix it.
4. Be conservative — only flag things you are confident about.
5. If there are findings, output ONLY a JSON array (no preamble, no markdown fence):

[
  {
    "slug": "short-kebab-case-id",
    "title": "One-line problem summary",
    "body": "Problem description paragraph.",
    "fix": "exact nix snippet or shell command"
  },
  ...
]

6. If there is nothing to report, output only: NO_DRIFT
PROMPT_EOF
)

OUTPUT=$("$CLAUDE" --model claude-sonnet-4-6 --print "$PROMPT" 2>> "$RUNLOG")

if [ "$OUTPUT" = "NO_DRIFT" ]; then
  log "no drift detected"
else
  TMPJSON=$(mktemp)
  printf '%s' "$OUTPUT" > "$TMPJSON"
  COUNT=0
  # validate JSON first
  if ! jq -e '.' "$TMPJSON" > /dev/null 2>&1; then
    log "JSON parse error — raw output: $(cat "$TMPJSON" | head -5)"
    rm -f "$TMPJSON"
    exit 1
  fi
  while IFS= read -r item; do
    slug=$(printf '%s' "$item" | jq -r '.slug // "unknown"')
    title=$(printf '%s' "$item" | jq -r '.title')
    body=$(printf '%s' "$item" | jq -r '.body')
    fix=$(printf '%s' "$item" | jq -r '.fix')
    outfile="$PROPOSALS_DIR/$DATE-mint-drift-${slug}.md"
    [ -f "$outfile" ] && continue
    printf '%s\n' "---" "status: proposed" "category: drift" "date: $DATE" "source: mint-drift-agent" "---" "" "## $title" "" "$body" "" '```' "$fix" '```' > "$outfile"
    COUNT=$((COUNT + 1))
  done < <(jq -c '.[]' "$TMPJSON")
  rm -f "$TMPJSON"
  log "$COUNT new proposal(s) written to $PROPOSALS_DIR"
fi
