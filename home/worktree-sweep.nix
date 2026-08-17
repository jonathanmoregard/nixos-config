{ pkgs, ... }:
# Daily sweep of merged-and-stale worktrees + local branches, across
# every repo that has a worktree under one of the roots below. PRs merge
# by squash, so `git branch --merged` never matches — GitHub PR state is
# the source of truth. The script's fail-closed predicates live in
# home/worktree-sweep-script.nix; the contract harness is
# tests/worktree-sweep.nix (flake check `worktree-sweep`, wired into
# ci.yml's flake-check job).
#
# Was nixos-config-only until 2026-08-17. Every other repo's worktrees
# accumulated untouched — ~/worktrees alone holds worktrees for eleven
# repos — so the sweep now discovers repos from the roots rather than
# naming one. Repos are found through their worktrees, so a repo that has
# never had one under a root is never touched at all.
#
# Home-manager side (not a NixOS module) because the worktrees are
# jonathan-owned and gh auth (keyring) is jonathan's.
let
  # No arguments: the swept roots are the script's own defaults. The
  # drift gate in tests/worktree-sweep.nix compares this unit's ExecStart
  # against `import ./home/worktree-sweep-script.nix { inherit pkgs; }`,
  # so passing roots here would silently build a second derivation and
  # turn a byte-identical assertion into a maintenance trap.
  sweepScript = import ./worktree-sweep-script.nix { inherit pkgs; };
in
{
  systemd.user.services.worktree-sweep = {
    Unit.Description = "Sweep merged-and-stale worktrees and local branches";
    Service = {
      Type = "oneshot";
      # tests/worktree-sweep.nix asserts this ExecStart is byte-identical
      # to the derivation under test — keep both importing the same file.
      ExecStart = "${sweepScript}/bin/worktree-sweep";
      Nice = 10;
      # Light hardening only: the job's whole purpose is deleting
      # jonathan-owned worktrees under ~/Repos and ~/worktrees, and gh
      # needs the keyring + network — ProtectHome/ProtectSystem=strict
      # would neuter it.
      NoNewPrivileges = "yes";
      PrivateTmp = "yes";
    };
  };

  systemd.user.timers.worktree-sweep = {
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
