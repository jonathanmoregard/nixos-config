{ pkgs, ... }:
# Daily sweep of Cargo build artifacts whose lifetime has come uncoupled from
# the worktree that owns them. Complements worktree-sweep rather than
# duplicating it: worktree-sweep removes whole worktrees that are merged or
# inactive, and correctly keeps the dirty and unmerged ones — but a kept
# worktree's target/ can still be a month stale and tens of GB. On 2026-11-10
# that gap was 1181 GB across 85 target dirs.
#
# The script's fail-closed predicates live in
# home/cargo-target-sweep-script.nix; the contract harness is
# tests/cargo-target-sweep.nix.
#
# Home-manager side, matching worktree-sweep: the worktrees are
# jonathan-owned and the sweep must run as the user whose builds they are,
# so that /proc liveness inspection and the per-worktree Cargo flock refer
# to the same session that would be harmed by a bad delete.
let
  # No arguments: the swept roots and ages are the script's own defaults, so
  # tests/cargo-target-sweep.nix can compare this unit's ExecStart against
  # `import ./home/cargo-target-sweep-script.nix { inherit pkgs; }` and have
  # a byte-identical assertion rather than a second derivation.
  sweepScript = import ./cargo-target-sweep-script.nix { inherit pkgs; };
in
{
  systemd.user.services.cargo-target-sweep = {
    Unit.Description = "Reclaim stale Cargo target directories";
    Service = {
      Type = "oneshot";
      # tests/cargo-target-sweep.nix asserts this ExecStart is byte-identical
      # to the derivation under test — keep both importing the same file.
      ExecStart = "${sweepScript}/bin/cargo-target-sweep";
      # Compiling lanes are the point of this machine; reclaiming disk is not
      # worth stealing CPU or IO from them.
      Nice = 15;
      IOSchedulingClass = "idle";
      NoNewPrivileges = "yes";
      # NOT PrivateTmp: the sweep reads /proc to find live builds, and a
      # private /tmp would hide nothing relevant but costs a namespace.
    };
  };

  systemd.user.timers.cargo-target-sweep = {
    Unit.Description = "Daily stale Cargo target directory sweep";
    Timer = {
      # 03:00 (+45min jitter) against worktree-sweep's 00:00 (+30min), so
      # the two are not walking the same trees at once on a machine that
      # stays up: worktree-sweep may remove a whole worktree this would
      # otherwise have swept first, and both are IO-heavy.
      #
      # An earlier revision claimed this offset in a comment while both
      # units read `OnCalendar = "daily"` — the same instant, differing
      # only by jitter. tests/cargo-target-sweep.nix now asserts the two
      # OnCalendar values differ, so the claim cannot rot again.
      #
      # Persistent catch-up after a suspend or a shutdown can still land
      # both in the same boot; that is accepted, since each is liveness-
      # gated and neither depends on the other's result.
      OnCalendar = "*-*-* 03:00:00";
      # Laptop: catch up after suspend/boot when the window was missed.
      Persistent = true;
      RandomizedDelaySec = "45min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
