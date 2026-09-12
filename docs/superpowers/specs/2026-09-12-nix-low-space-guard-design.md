# Nix Low-Space Guard Design

## Goal

Prevent Nix builds from filling Dellan's shared root filesystem between scheduled garbage-collection runs, while retaining fourteen days of profile generations and avoiding custom deletion logic.

## Incident Evidence

The existing weekly maintenance had not reached its first Sunday run before the root filesystem fell to 9 GiB free. A manual `nix-store --gc` then deleted 9,508 unreachable store paths and freed 322.9 GiB. PostgreSQL and worktree cleanup recovered additional space, but the Nix store was the largest recurring source.

## Design

Use Nix's built-in daemon pressure controls and make scheduled collection daily:

- Keep `nix.gc.options = "--delete-older-than 14d"`, preserving the existing profile-generation retention policy.
- Change `nix.gc.dates` from Sunday-only to `daily`, so unreachable outputs are collected each day even when free space has not crossed the emergency threshold.
- Set `nix.settings.min-free` to 200 GiB. During a build, crossing this threshold asks the Nix daemon to collect unreachable paths.
- Set `nix.settings.max-free` to 300 GiB. Emergency collection stops once that much space is available or no more garbage remains.
- Keep weekly store optimisation unchanged.
- Give disposable VMs scaled 128 MiB/1 GiB thresholds. Their 12–20 GiB disks cannot inherit physical-host reserve values.

The 100 GiB gap gives active builds room to finish while avoiding an unbounded collection target. The values reserve roughly 20% and 30% of the 931 GiB root filesystem and are large enough to react before another one-day build spike exhausts the disk.

## Failure Behavior

Nix performs emergency collection only during Nix build activity. If less than 300 GiB can be recovered, it stops after exhausting unreachable paths; it never deletes live roots. The daily timer remains a second path for collecting unreachable outputs after build activity ends.

## Testing

Extend the existing evaluated `nix-maintenance` contract first. It must assert the daily calendar and exact byte values for `min-free` and `max-free`. Run the check before implementation to prove it fails against the weekly, zero-threshold configuration, then rerun it after implementation.

The full-host VM test must assert its scaled values and complete a real Nix build. This catches accidental inheritance of physical-host thresholds: the first integration run with 200/300 GiB on a 12 GiB test disk immediately entered auto-GC, coredumped its Nix daemon while scanning runtime roots, and timed out a later build assertion.

Build the Dellan system derivation to verify production settings through the full module graph. Boot the feature VM and confirm its Nix daemon reports the scaled values and can perform a build, proving the VM override without exercising production-sized disk pressure.

## Non-Goals

- No custom filesystem watcher or cleanup script.
- No reduction of the fourteen-day profile-generation retention period.
- No change to worktree cleanup or PostgreSQL lifecycle behavior.
- No automatic deletion of caches outside the Nix store.
