# Home-server CD VM simulation

## Goal

Prove the prepared `home-server` can consume a new Git revision through the
repository's existing pull-deploy machinery without touching physical hardware.
The test must exercise a real NixOS activation, not replace `nixos-rebuild` with
`true`, `false`, or another command stub.

## Chosen design

Add a dedicated `vm-home-server-cd` NixOS test lane. Keeping it separate from
`vm-home-server` isolates service-stack failures from deployment failures and
makes the CD contract visible in CI.

The target imports the production home-server modules and uses the target
resource envelope: x86-64, four virtual CPUs, 8 GiB RAM, and a sparse 128 GiB
ext4 disk. Test-only configuration supplies non-secret fixture values and keeps
hardware-only Zigbee and SMART startup out of the runtime path.

The VM contains an offline-capable fixture flake for its own configuration. A
local bare Git repository stands in for GitHub and Tailscale transport. This is
the only mocked boundary: `nixos-deploy.service` still performs its real fetch,
target resolution, hard reset, memory admission, `nixos-rebuild switch`, and
success bookkeeping.

## Scenario

1. Boot release `v1` and wait for target health.
2. Seed `/etc/nixos` plus a local bare origin at the `v1` commit.
3. Commit and push release `v2` to the local origin.
4. Start the real `nixos-deploy.service`, matching the timer's service target.
5. Require the working tree and `/var/lib/nixos-deploy/last-good` to equal the
   exact `v2` commit, the system generation to advance, and `/etc/cd-release`
   to read `v2`.
6. Require Mosquitto and the local automation health endpoint to remain healthy
   after activation, with no failed units or poison-latch entry.
7. Start deployment again and prove it is an idempotent no-op with no new
   generation.
8. Perform a real NixOS rollback to `v1`, start deployment again, and prove the
   rollback guard leaves `v1` active rather than forcing `v2` forward.

Diagnostics print generation numbers, active system paths, exact Git SHAs,
deploy journal output, and release marker values before assertions.

## Test seams and safety

No test-only HTTP or state mutation API is added. Release state changes only by
Git commit and the real deployment service. GitHub delivery and Tailscale
transport are external adapters and are replaced by a local Git remote; the
home server's configured timer and service share the same deploy entrypoint.

Everything runs in a disposable QEMU snapshot. No command addresses
`/etc/nixos` on the host, no real deploy key is loaded, no PR is merged, and no
physical NixOS profile is changed.

## Boundaries

QEMU can reproduce architecture, CPU count, memory, disk capacity, ext4,
systemd, Nix generations, and wired-network assumptions. It cannot faithfully
reproduce the J5005 microarchitecture, SSD SMART behavior, ZBDongle-E USB/Ember
firmware, RF conditions, BIOS power-after-AC-loss, or Tailscale control-plane
identity. Those remain bootstrap smoke checks on the physical machine.
