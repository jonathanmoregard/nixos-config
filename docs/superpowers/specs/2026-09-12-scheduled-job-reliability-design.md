# Scheduled Job Reliability Design

## Problem

Three unattended jobs currently fail for unrelated reasons:

1. `nixos-drift-analyzer` sends a large prompt to Claude every hour. During
   quota exhaustion the command exits non-zero, while direct shell redirection
   truncates the last successful report before Claude starts.
2. The nixos-config refresh cron runs `git pull --ff-only` in the `main`
   worktree. Global `pull.rebase=true` makes a dirty index fatal. More
   importantly, several linked worktrees currently attach to the shared
   `main` branch, so advancing that ref from any one checkout leaves the other
   worktree indexes behind.
3. The Mint drift cron points into a bare repository and targets an operating
   system no longer installed.

All three jobs also lack durable success state and visible failure reporting.

## Decision

Replace semantic, model-driven drift analysis with deterministic invariant
checks. Replace local-branch pulling with remote-tracking fetch. Remove the
obsolete Mint schedule. Use systemd user services for maintained jobs so
failures reach `OnFailure` notifiers.

## Deterministic Drift Analyzer

The analyzer remains an hourly user timer because deterministic checks are
cheap and offline. It performs no mutation and makes no network requests.

It reports these known drift classes:

- packages installed through the user `nix-env` profile;
- entries in `~/.local/bin` that do not resolve into `/nix/store`;
- tracked or untracked changes in the deployed `/etc/nixos` checkout;
- differences between the declarative crontab and installed crontab after
  removing Vixie cron's generated three-line header;
- more than one linked worktree attached to `refs/heads/main` in the
  nixos-config repository.

These checks prove violations of explicit invariants. They do not claim to
infer every possible desired-state mismatch. Report language therefore calls
ambiguous filesystem entries “drift candidates.”

The runner writes to a temporary file in the report directory, then renames it
over `latest.md` only after every check completes. Failure removes the
temporary file and preserves the previous report. A successful run records an
atomic `last-success` timestamp under XDG state. Unexpected command failure
exits non-zero and triggers a best-effort desktop notification plus a journal
message.

## NixOS Config Fetch

A generated `nixos-config-fetch` program and systemd user timer replace the
cron entry. Every run:

1. addresses the repository through the canonical anchor worktree;
2. runs `git fetch origin main`, updating `origin/main` without touching a
   checked-out branch, index, or working tree;
3. verifies `origin/main` resolves;
4. atomically records the fetched commit and timestamp as `last-success`.

The service never pulls, merges, rebases, stashes, resets, or advances local
`main`. Therefore dirty or multiply-attached `main` worktrees cannot corrupt
one another during refresh. Failures remain non-zero and trigger a dedicated
notification.

Active worktree instructions and examples will create branches from
`origin/main`, not local `main`. The anchor remains the supported command
entry point because `safe.bareRepository=explicit` intentionally rejects
direct bare-repository discovery.

Existing foreign worktrees will not be detached, switched, removed, or
cleaned by this change. They may contain active work. Fetch-only operation
removes the mechanism that made their shared branch attachment harmful.

## Mint Job

Remove only the Mint drift cron entry. Retain historical script and skip-list
files; deleting dormant source is unnecessary for stopping execution and is
outside this change.

## Error Handling and Visibility

- Atomic report and heartbeat publication prevents partial state.
- Both maintained services retain non-zero exit status.
- Each service has an `OnFailure` notifier that writes a useful journal line
  before attempting `notify-send`.
- Timers use `Persistent=true`, bounded accuracy, and small randomized delay.
- No notifier is timer-enabled directly.

## Tests

Add `vm-base` assertions before implementation and observe them fail. Tests
will prove:

- no active Mint drift cron command remains;
- no nixos-config `pull` command remains;
- fetch timer and service are installed, enabled, and carry `OnFailure`;
- worktree documentation and managed skills use `origin/main` as branch base;
- drift analyzer contains no Claude invocation;
- clean runtime state produces an atomic report and success heartbeat;
- injected imperative package, unmanaged local binary, crontab mismatch, and
  duplicate-main topology each produce a finding;
- forced probe failure preserves the last successful report and fires the
  notifier;
- fetch succeeds against a local fixture even when a checked-out `main`
  worktree has index changes, while remote-tracking state advances;
- fetch failure preserves prior heartbeat and fires the notifier.

Generated scripts also receive direct adversarial runtime checks for missing
paths, non-zero subcommands, and timeout behavior. An interactive feature VM
smoke will manually start both services and inspect reports, heartbeats, and
journals before PR creation.
