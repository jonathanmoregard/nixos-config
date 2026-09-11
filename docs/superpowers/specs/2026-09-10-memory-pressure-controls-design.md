# RAM pressure controls

Date: 2026-09-10
Status: approved

## Problem

The desktop reached 28 GiB of 30.7 GiB RAM, filled all 31.3 GiB of swap, and
reported full-memory PSI above 18 percent. Three avoidable workload shapes
overlapped:

- each Claude/Codex pane held a private aggregator query/model server;
- feature VMs and Nix evaluation/build jobs ran concurrently without a shared
  memory admission gate;
- `systemd-oomd` was active but monitored zero cgroups.

High swap use is retained anonymous memory, not filesystem cruft. Forcing
`swapoff` while tens of GiB remain allocated would page data back into
insufficient RAM and worsen pressure. Remediation therefore removes duplicated
state, coordinates heavy work, and makes OOM killing local and early.

## Shared aggregator backend

The aggregator overlay will expose two commands from one Python environment:

- `aggregator-mcp`: stdio proxy with a fixed loopback backend URL;
- `aggregator-mcp-backend`: original server with FastMCP HTTP transport on
  `127.0.0.1:8765/mcp` and no proxy environment variable.

A Home Manager user service starts the backend at the user's default target.
It restarts on failure, writes only to aggregator state, permits only loopback
network traffic, and applies `MemoryHigh=6G` plus `MemoryMax=8G`. Existing MCP
manifests remain untouched, preserving schema-health command discovery.
Loopback is host-local, not user-private, so the service creates a bearer token
inside its mode-`0700` runtime directory. Both backend and stdio wrappers read
that mode-`0600` file; other local UIDs cannot authenticate or read personal
history. Restarts preserve the token so already-running proxies stay valid.

## Heavy-job coordination

`services.buildCoordination` will provide one fixed `nix-memory-run` helper and
a high-priority `nix` wrapper. One advisory lock at
`~/.nix-memory-pressure/lock`, owned by Jonathan at mode `0600`
below a mode-`0700` directory, admits a single memory-heavy workflow at a time.
Root can open that same file for auto-deploy without exposing a lock-based
denial-of-service primitive to other local users. The wrapper
coordinates `nix build`, `nix eval`, `nix flake check`, and the feature-VM apps;
lightweight commands and `feature-vm-screencap` bypass the lock. A marker
environment variable makes nested Nix calls bypass the same lock, preventing
self-deadlock. During first deployment, Jonathan creates this exact stable path
if needed; system tmpfiles later enforces ownership and mode. No fallback lock
namespace exists, so activation cannot split old and new launchers across two
simultaneously-unlocked files.

Coordinated interactive commands run in transient scopes below
`ram-heavy.slice`. Feature VMs always run in a named scope there, so QEMU and
its launcher are one disposable workload. Automated deployment uses the same
helper in nonblocking mode and defers to its next timer tick when another heavy
job owns the lock.

Nix daemon settings change from three concurrent derivations to one, retain
four cores per derivation, and enable per-build cgroups. This puts actual
builders below `nix-daemon.service`, not merely beneath the client pane.

## Targeted OOM policy

`systemd-oomd` monitors exactly two workload ancestors:

- `nix-daemon.service`, whose per-build descendants become kill candidates;
- `ram-heavy.slice`, whose transient scopes become kill candidates.

Both use `MemoryHigh=12G`, swap monitoring, and memory-pressure killing at 40
percent for 10 seconds. Global swap action begins at 80 percent used. No root,
system, broad user, or graphical-session slice is enrolled. This prevents a
busy builder or VM from turning the whole Cinnamon session into an OOM
candidate. Transient scopes use group kill semantics; the Nix daemon itself
stays alive when an offending build descendant is selected.

Hard `MemoryMax` is intentionally absent from heavy build ancestors. OOMD can
compare descendants and select the offender, while `MemoryHigh` supplies local
backpressure. Backend has a hard limit because it is a single restartable
service with a known steady-state envelope.

## Failure behavior

- lock acquisition waits with a clear diagnostic for interactive work;
- nonblocking deployment exits cleanly as deferred, leaving the next hourly
  tick to retry;
- deployment writes a child-start marker under its private state directory, so
  exit 75 means deferral only when lock contention prevented child startup; an
  actual rebuild that exits 75 remains a failed, poisoned target;
- malformed helper invocation returns usage status without running anything;
- child exit status and signals propagate through helper and transient scope;
- missing user systemd manager falls back to coordinated execution without a
  transient user scope, so serialization still holds;
- backend outage remains loud and never starts private model servers.

## Verification

`vm-base` will prove generated wrappers, backend sharing, exact OOMD monitored
units, lock serialization/bypass, transient scope placement, backend restart,
and preservation of an outside-session sentinel. `vm-auto-deploy` will prove a
busy lock defers deployment without poisoning state and a free lock permits it.

Cheap evaluation and Home Manager closure inspection precede lane builds.
Interactive `feature-vm` smoke will prove QEMU lands below `ram-heavy.slice`, a
second heavy operation waits, screencap remains usable, and releasing the VM
releases the lock. No local host rebuild is performed.

Deployment order is aggregator PR first, then the NixOS PR pinned to its
reviewed commit.
