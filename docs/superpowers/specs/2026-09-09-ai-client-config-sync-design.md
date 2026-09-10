# Recurring Claude-to-Codex Sync Design

## Goal

Keep Codex configuration aligned with Claude configuration by running the latest
`ai-client-config` `main` branch automatically.

## Design

A Home Manager user timer fires shortly after boot and on each hourly calendar
boundary. `Persistent=true` catches a missed run after laptop suspend.

Each run shallow-clones `jonathanmoregard/ai-client-config` `main` into a private
runtime directory, records the exact commit, and executes
`scripts/sync_codex.py`. The temporary clone is always discarded, so the job
cannot consume or damage a dirty developer checkout.

Clone remains network-enabled, but fetched renderer code runs in private user,
mount, PID, IPC, UTS, and network namespaces with only loopback visible. It sees
a staged fake home, read-only Claude inputs, an empty runtime directory, empty
`/proc`, and fresh loopback-only sysfs. Codex credentials, sessions, history,
logs, caches, memories, user D-Bus, and runtime databases remain inaccessible.

Only after a successful render does the trusted wrapper publish an explicit
allowlist of managed Codex and plugin paths from staging into the real home.
Renderer failure cannot touch live output; a publish or bookkeeping failure
restores the pre-run snapshot. Unmanaged staged writes are discarded.

The service bounds both the clone and renderer. It writes a recoverable failure
record under `~/.local/state/ai-client-config-sync/`, clears that record after a
successful run, logs to the user journal, and sends a best-effort desktop alert.

## Test Strategy

`vm-base` creates a local Git fixture and points the production service at it
through an adapter-level environment seam. It proves the first revision runs,
a later commit is picked up on the next invocation, a failing renderer is
reported without changing managed output, renderer network visibility is
loopback-only, D-Bus and host process roots are hidden, unmanaged writes are
discarded, and a hanging renderer is terminated by the configured deadline.
It also covers empty configuration and an upstream revision missing the
renderer. Interactive `feature-vm` smoke runs the same user unit against a local
fixture, including D-Bus escape and destructive plugin/runtime attempts, before
the PR opens.
