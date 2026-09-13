# Local Klaffat Google Calendar capability

Date: 2026-09-12

## Outcome

Jonathan can run a Klaffat development build against his real Google Calendar
at `http://localhost:3740` without typing `sudo` and without exposing the
Google OAuth client ID or secret to his login session or to an automation
agent. A fixed NixOS service obtains the encrypted environment from the
selected Klaffat worktree, decrypts it as root with the host SSH identity, and
starts the application as a dedicated unprivileged account.

The operator interface is deliberately small:

```text
klaffat-local-google start /home/jonathan/worktrees/klaffat-my-feature
klaffat-local-google status
klaffat-local-google stop
```

`start` prints `http://localhost:3740` only after the health endpoint answers.

## Security boundary

The encrypted source remains `deploy/secrets/klaffat-env.age` in the selected
Klaffat worktree. Only the root preparation process may decrypt it, using
`/etc/ssh/ssh_host_ed25519_key`. It copies only
`KLAFFAT_GOOGLE_CLIENT_ID` and `KLAFFAT_GOOGLE_CLIENT_SECRET` into a root-owned
runtime environment file. It rejects missing, duplicate, or malformed values
and never logs their contents. The complete decrypted environment is removed
before the application starts.

The application runs as the system user `klaffat-local-google`, not as
Jonathan. The runtime directory, state directory, environment file, and
process environment are inaccessible to Jonathan. The prepared application
binary and static assets are root-owned copies, so the service never traverses
Jonathan's home after privilege separation. Systemd hardening constrains the
process to its state and runtime directories.

This boundary prevents an interactive shell or automation agent running as
Jonathan from reading credentials through the environment file or
`/proc/<pid>/environ`. The selected development application necessarily
receives the OAuth secret: that is required for Google's server-side token
exchange. Therefore a deliberately malicious Klaffat build could transmit the
secret over its permitted network connection. Worktree validation and an
isolated service account prevent accidental disclosure; code review remains
the trust decision for the application itself.

## Authorization model

A polkit rule grants the local user `jonathan` permission to start, stop,
restart, or clear a failed-state latch on exactly
`klaffat-local-google.service`. It grants no general sudo or systemd-management
capability. The public launcher writes the selected path to Jonathan's XDG
state directory and invokes only those exact unit actions.

The root preparation step treats the selection as hostile input. It requires:

- a canonical absolute path immediately below
  `/home/jonathan/worktrees/`, named `klaffat-*`;
- an unprivileged launcher check that the worktree origin is the Klaffat
  GitHub repository (root never invokes Git in a user-owned repository);
- a regular, executable, Jonathan-owned application binary at
  `target/local-google/debug/klaffat`;
- regular source files without symlinks or special files in the static tree;
- the encrypted environment and test KEK at their fixed repository paths.

The origin check prevents an operator typo; it is not a trust proof for the
checked-out bytes. The launcher does not accept executable paths, environment assignments,
systemd unit names, ports, or additional arguments.

## Runtime preparation

Each start recreates `/run/klaffat-local-google/prepared`. Root copies the
validated binary, static tree, and test KEK there without following symlinks,
then changes ownership to the dedicated service account. The secret extractor
runs with a bounded timeout and writes atomically at mode `0400`, owned by the
service account, so only the application account can consume it.

The app is configured with:

- loopback bind and `BASE_URL=http://localhost:3740`;
- local development authentication and the in-memory mailer;
- the real Google authorization and token endpoints from application
  defaults—no OAuth mock overrides;
- a persistent PostgreSQL data directory owned by the service account;
- the copied static directory and KEK.

PostgreSQL listens only on the system Unix socket; TCP listening is disabled.
OAuth tokens and connected-calendar state therefore survive application
restarts while remaining isolated from Jonathan's account.

## Failure behavior

Preparation fails closed. A bad selector, unexpected repository, symlink,
missing artifact, malformed encrypted environment, decryption failure, or
decryption timeout prevents the service from starting. Temporary plaintext is
removed on every exit path. A health-check timeout returns a non-zero launcher
status and points to `systemctl status`; it never prints the service
environment.

## Verification

The existing non-cache-skippable `vm-klaffat-infra` lane covers the new
capability so no additional paid GitHub Actions matrix job is introduced. Its
fixture supplies a test-only decryptor and Klaffat server stand-in. Behavioral
assertions prove:

- Jonathan can start and stop only the intended service without a password;
- invalid paths, origins, ownership, symlinks, malformed secrets, decrypt
  failures, and decrypt timeouts fail closed;
- the server receives the two Google variables but not unrelated values;
- Jonathan cannot read the runtime environment, state, or process environment;
- the process has the dedicated UID and the HTTP health endpoint answers;
- no Google OAuth mock endpoint variables reach the server;
- the persistent database survives a service restart.

The production evaluation and toplevel build complement the VM behavior test.
After merge and automatic deployment, the real launcher is exercised against
the existing encrypted Klaffat environment without inspecting plaintext.
