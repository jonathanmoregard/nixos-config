{ pkgs, ... }:
# Daily sweep of merged-and-stale nixos-config worktrees + local
# branches. PRs merge by squash, so `git branch --merged` never
# matches — GitHub PR state is the source of truth. The script's
# fail-closed predicates live in home/worktree-sweep-script.nix; the
# contract harness is tests/worktree-sweep.nix (flake check
# `worktree-sweep`, wired into ci.yml's flake-check job).
#
# Home-manager side (not a NixOS module) because the worktrees are
# jonathan-owned and gh auth (keyring) is jonathan's.
let
  sweepScript = import ./worktree-sweep-script.nix { inherit pkgs; };
in
{
  systemd.user.services.nixos-worktree-sweep = {
    Unit.Description = "Sweep merged-and-stale nixos-config worktrees and local branches";
    Service = {
      Type = "oneshot";
      # tests/worktree-sweep.nix asserts this ExecStart is byte-identical
      # to the derivation under test — keep both importing the same file.
      ExecStart = "${sweepScript}/bin/nixos-worktree-sweep";
      Nice = 10;
      # Light hardening only: the job's whole purpose is deleting
      # jonathan-owned worktrees under ~/Repos, and gh needs the
      # keyring + network — ProtectHome/ProtectSystem=strict would
      # neuter it.
      NoNewPrivileges = "yes";
      PrivateTmp = "yes";
    };
  };

  systemd.user.timers.nixos-worktree-sweep = {
    Unit.Description = "Daily merged-and-stale worktree sweep";
    Timer = {
      OnCalendar = "daily";
      # Laptop: catch up after suspend/boot when midnight was missed.
      Persistent = true;
      RandomizedDelaySec = "30min";
    };
    Install.WantedBy = [ "timers.target" ];
  };
}
