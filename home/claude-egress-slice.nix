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
# For the same reason the launch path must resolve the binary from PATH
# AT CALL TIME rather than pinning a store path: the native installer
# self-updates, and pinning would mean phase 1 observed a different
# workload than phase 2 constrains.
#
# That argument is about the NAME `claude` only, and it still holds. What
# the function no longer holds is the logic: that moved to
# home/claude-egress-launch.nix, a package named `claude-egress-launch`,
# so the VSCodium extension can spawn the identical code path through
# `claudeCode.claudeProcessWrapper`. A function intercepts the name; a
# package is what a GUI can launch. Both are needed, and the logic is
# written once.
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
let
  # THE launch path, shared verbatim with home/vscodium.nix's
  # claudeCode.claudeProcessWrapper. See home/claude-egress-launch.nix for
  # why the logic cannot live in this zsh function alone.
  claudeEgressLaunch = import ./claude-egress-launch.nix { inherit pkgs; };
in
{
  # The slice is a long-lived unit rather than a per-invocation transient
  # one. nftables bakes the cgroup's INODE into the rule at parse time
  # (see the observer module's header), so a slice that is destroyed and
  # recreated silently invalidates the binding. Keeping the cgroup alive
  # continuously — with `users.users.<user>.linger` keeping
  # user@<uid>.service alive across logout — makes rebinding the
  # exception rather than the rule.
  # On PATH as well as referenced by store path: it makes the GUI launch
  # path runnable by hand (`claude-egress-launch --version`), which is how
  # tests/claude-egress.nix exercises the extension's spawn without
  # building VSCodium into the test VM.
  home.packages = [ claudeEgressLaunch ];

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
    # One line on purpose. The resolution, the no-op probe, the degrade
    # paths and the systemd-run invocation all live in
    # home/claude-egress-launch.nix, because the VSCodium extension
    # spawns a process and cannot see a shell function — and two copies
    # of this logic would drift silently toward "looks observed, isn't".
    #
    # Still not `exec`: that would replace this interactive login shell,
    # so quitting Claude Code would close the terminal (the PR #184
    # failure class). The script execs internally, in its own process,
    # which is free.
    #
    # XDG_RUNTIME_DIR no longer needs zsh's `local -x` dance either: the
    # default is applied inside the child, so it cannot leak into the
    # calling terminal by construction rather than by care.
    _claude_slice() { "${claudeEgressLaunch}/bin/claude-egress-launch" "$@" }

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
