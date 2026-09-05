# claude-egress-slice — put interactive Claude Code sessions into an
# observed cgroup.
#
# Pairs with modules/nixos/claude-egress-observe.nix, which binds an
# nftables logging rule to this slice. Phase 1 of two: the rule LOGS and
# never drops. See ~/.claude/tasks/nixos-config/claude-egress-phase1-spec.md.
#
# ── Why a shell FUNCTION and not a wrapper package ────────────────────
#
# home/jonathan.nix:247 prepends $HOME/.local/bin to PATH so the
# self-updating Claude Code native installer wins over the nixpkgs
# build. `whence -a claude` on dellan therefore resolves, in order:
#
#   1. /home/jonathan/.local/bin/claude      ← native installer, the one in use
#   2. /etc/profiles/per-user/jonathan/bin/claude
#   3. /run/current-system/sw/bin/claude
#
# A wrapper shipped through the home-manager profile lands at position 2
# and is never reached. Worse, a VM test of such a wrapper passes green,
# because no native installer exists in the VM. A shell function takes
# precedence over every PATH entry, so it is the only launch point that
# actually intercepts the real invocation.
#
# For the same reason the function must resolve the binary with
# `whence -p claude` AT CALL TIME rather than pinning a store path: the
# native installer self-updates, and pinning would mean phase 1 observed
# a different workload than phase 2 constrains.
#
# ── Why the definitions live here and not in home/jonathan.nix ────────
#
# `programs.zsh.initContent` is a `lines` option, so this module's
# `lib.mkAfter` block is concatenated AFTER home/jonathan.nix's own
# initContent. The later definition of `claude()` / `claudee()` wins,
# and jonathan.nix — contested by two open PRs — is not touched.
#
# ── Deliberate deviation from the spec: no `exec` ─────────────────────
#
# The spec says `exec systemd-run …`. It must not: `exec` inside an
# interactive zsh function replaces the login shell, so quitting Claude
# Code would close the terminal instead of returning to the prompt. That
# is a silent regression of the primary workflow — the PR #184 failure
# class this whole design is a reaction to. `systemd-run --scope` execs
# the command in its own process anyway, so the cgroup placement, the
# tty and signal delivery are identical without it. The surviving-shell
# property is asserted behaviourally in tests/claude-egress.nix.
{ config, lib, pkgs, ... }:
{
  # The slice is a long-lived unit rather than a per-invocation transient
  # one. nftables bakes the cgroup's INODE into the rule at parse time
  # (see the observer module's header), so a slice that is destroyed and
  # recreated silently invalidates the binding. Keeping the cgroup alive
  # continuously — with `users.users.<user>.linger` keeping
  # user@<uid>.service alive across logout — makes rebinding the
  # exception rather than the rule.
  systemd.user.slices.claude-egress = {
    Unit = {
      Description = "Observed cgroup for interactive Claude Code sessions";
      Documentation = [ "https://github.com/jonathanmoregard/nixos-config" ];
    };
    Install.WantedBy = [ "default.target" ];
  };

  programs.zsh.initContent = lib.mkAfter ''
    # ── claude-egress (home/claude-egress-slice.nix) ──────────────────
    # Launches Claude Code inside claude-egress.slice so its egress (and
    # that of every MCP server it spawns, which are stdio children and
    # therefore inherit the cgroup) is observable. Redefines the
    # claude()/claudee() pair from home/jonathan.nix; `clear` and the
    # `--continue` policy are preserved verbatim — the policy itself
    # lives in `_claude_selects_session`, defined once in
    # home/jonathan.nix and called from both wrappers so the shadowing
    # copy here cannot drift from the one it shadows.
    _claude_slice() {
      local bin runner nop
      bin="$(whence -p claude 2>/dev/null)"
      if [[ -z "$bin" ]]; then
        print -ru2 -- "claude-egress: no 'claude' binary on PATH"
        return 127
      fi

      runner="$(whence -p systemd-run 2>/dev/null)"
      nop="$(whence -p true 2>/dev/null)"
      # `local -x`, never a bare `export`: the default has to reach the
      # child, but exporting it would set it in the CALLING interactive
      # shell for the rest of that terminal's life — and on the fallback
      # path below it is a guess this function just proved wrong. zsh
      # restores the caller's value (or its absence) on return.
      local -x XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

      # Observation degrades; the tool never fails to start. Every exit
      # below still runs Claude Code — it just says so on stderr, because
      # an unobserved session that looks observed is the failure mode
      # this design exists to avoid.
      if [[ -z "$runner" || ! -S "$XDG_RUNTIME_DIR/bus" ]]; then
        print -ru2 -- "claude-egress: UNOBSERVED (no systemd-run, or no user bus at $XDG_RUNTIME_DIR/bus)"
        "$bin" "$@"
        return $?
      fi

      # Probe with a no-op before committing the real invocation. Testing
      # the scope up front is what makes the fallback reachable at all —
      # once systemd-run is running the session there is no way back.
      if [[ -n "$nop" ]] \
         && ! "$runner" --user --scope --quiet --slice=claude-egress.slice -- "$nop" >/dev/null 2>&1; then
        print -ru2 -- "claude-egress: UNOBSERVED (a scope in claude-egress.slice would not start)"
        "$bin" "$@"
        return $?
      fi

      "$runner" --user --scope --quiet --slice=claude-egress.slice -- "$bin" "$@"
    }

    # Every branch goes through _claude_slice, so the slice confinement
    # is unconditional — the --continue decision only picks the argv.
    claude() {
      clear
      if _claude_selects_session "$@"; then
        _claude_slice "$@"
      else
        _claude_slice --continue "$@"
      fi
    }
    claudee() { clear; _claude_slice "$@"; }
  '';
}
