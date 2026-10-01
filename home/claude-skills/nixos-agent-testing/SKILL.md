---
name: nixos-agent-testing
description: >
  Interactive NixOS smoke testing in a sandbox VM. Use ONLY in the
  nixos-config repo (~/Repos/nixos-config-worktrees/) for complex
  changes — branching logic, multistep scripts, GUI/desktop side
  effects, or a daemon that needs poking. Pair with
  `nixos-automated-testing`.
---

## When to invoke this skill

- Change contains **branching logic** (if/case, Nix `mkIf`,
  `optionals`, conditional service enable). The automated gate only
  exercises one branch of any config; the interactive VM lets you
  exercise the actual code path the user will hit.
- Change is a **multistep script** (`writeShellApplication`,
  activation script, systemd `ExecStart` chain of several commands).
- Change touches **user-visible UI / desktop** (Cinnamon, kitty,
  LightDM theming, applet behavior).
- A **daemon needs poking** to verify its actual job (curl the
  endpoint, fire the timer, hit the URL, press the GUI binding, run
  the CLI as the user) — `systemctl is-active` is NOT enough. The
  test must reach the user's perspective, not the kernel's.
- A **PR is risk:medium or higher** per the classifier, and you want
  to convince yourself before clicking merge.

Skip only when the change has **no** downstream branch and **no**
script reading it — e.g. adding a package to
`environment.systemPackages`, bumping a version pin, fixing a
comment.

To decide, **trace the value you changed**: grep for the option /
variable / file path it lives at, follow each reference through
`mkIf` / `optionals` / `if`/`case` and into every script that
interpolates it. If the value influences any of those, it has a
downstream branch and is NOT pure-data. A boolean flip that gates
`mkIf` / `optionals` is the canonical example; so is changing the
input to a `writeShellApplication` or the right-hand side of an
`ExecStart`. When in doubt, run the interactive VM — the cost is
cheap.

## Quick start

```bash
cd ~/Repos/nixos-config-worktrees/<your-branch>
nix run .#feature-vm -- up                 # boot in the background, returns when ssh answers
nix run .#feature-vm -- run 'systemctl --failed'
nix run .#feature-vm -- down
```

`up` boots **this machine's** config from the worktree you are in
(`--host dellan|tuxedo` for another host, `--flake DIR` for another
checkout). `nix run .#feature-vm -- --help` lists every command.

| Command | Does |
|---|---|
| `up` / `down` | start in the background / stop and clean up |
| `run 'CMD'` | shell command in the VM; exit code passes through |
| `run PROG ARG...` | program + args, each quoted for you |
| `ssh` | interactive shell |
| `put SRC DEST` / `get SRC DEST` | copy in / out (recursive) |
| `apply` | rebuild the VM config from the worktree's current edits and activate it in the running VM — no reboot |
| `apply mod.nix` | same, with an extra NixOS module layered on (try a change without editing the repo) |
| `reset` | reboot to the pristine boot config — drops every change and `apply` |
| `status` | up/down, host, mode |
| `screencap out.png` | capture the display |

No command (`nix run .#feature-vm`) boots in the foreground as before;
Ctrl+C stops it.

## Locked (default) vs trusted

| | Locked (default) | `--trusted` |
|---|---|---|
| Guest internet | none (`restrict=on`; the ssh forward still works) | on |
| `/mnt/worktrees`, research-agent share | read-only (enforced by QEMU on the host) | read-write |
| Your keys / agenix secrets | none; every secret is a throwaway fixture | same |

Use locked for everything that does not need the internet or to write
host files — including running commands you would not run on the host.
Pass `--trusted` only when the change under test must reach the network
or write through a share (e.g. the research-agent microvm writing
reports), and say so in the PR evidence. The mode is chosen at `up`;
`reset` keeps it.

## Headless vs headful

| Mode | Command | When |
|------|---------|------|
| Headless (default) | `nix run .#feature-vm -- up` | Agentic flows, scripted smoke. No window. Drive via `run` + QMP + serial. |
| Headful (GUI) | `nix run .#feature-vm-headful` | Human at the laptop wants to see / drive the GUI. Foreground. Requires `$DISPLAY`. Same control sockets. |

Claude Code should default to **headless** every time. Only invoke
headful when the user has explicitly asked for a window.

## What you get inside the VM

- The host's hostname, same modules as prod. Every secret under
  `/run/agenix/` is a fixture (see below).
- `/mnt/worktrees` — host's `~/Repos/nixos-config-worktrees`
  (read-only unless `--trusted`).
- The host `/nix/store`, read-only — anything built on the host is
  instantly visible in the guest. That is what makes `apply` fast.
- `jonathan` user, in `wheel` + `keys`, sudo without password.
- SSH on host:2222, key `~/.ssh/id_ed25519`.
- `-snapshot` mode → every boot (and `reset`) is clean state.

## Control channels

The launcher's run dir is `~/.cache/feature-vm/run/`, holding
`qmp.sock` and `serial.sock`. It is recreated on every boot.

### QMP — JSON control over `qmp.sock`

```bash
sock=~/.cache/feature-vm/run/qmp.sock
{ printf '{"execute":"qmp_capabilities"}\n'
  printf '{"execute":"<COMMAND>","arguments":{...}}\n'
  sleep 0.5
} | socat -t 5 - UNIX-CONNECT:"$sock"
```

Useful commands:

| Goal | QMP `execute` | Arguments |
|------|--------------|-----------|
| Liveness | `query-status` | — |
| Send keystroke | `send-key` | `{"keys":[{"type":"qcode","data":"down"}]}` |
| Move mouse | `input-send-event` | `{"events":[{"type":"abs","data":{"axis":"x","value":0..32767}},{"type":"abs","data":{"axis":"y","value":0..32767}}]}` |
| Click | `input-send-event` | `{"events":[{"type":"btn","data":{"button":"left","down":true}}]}` then `down:false` |
| Type text | repeated `send-key` | qcodes: `a`-`z`, `0`-`9`, `ret`, `tab`, `shift`, `ctrl`, `alt`, `spc` |
| Graceful shutdown | `system_powerdown` | — |
| Hard quit | `quit` | — (skips guest shutdown — use with care) |

Mouse coordinate space is 0–32767, mapped to the VM's 1024x768
display. To click pixel (x, y): send `value = x * 32767 / 1024` and
`value = y * 32767 / 768`.

### Serial console — getty over a Unix socket

```bash
socat - UNIX-CONNECT:$HOME/.cache/feature-vm/run/serial.sock
```

Send two newlines to get a login prompt. Useful before sshd is up,
or when debugging a kernel panic — the kernel `console=ttyS0` arg
writes here too.

## Diagnose-then-act pattern

The interactive VM's value vs. the automated gate is that you can
**ask questions** of the running system. Pattern:

1. Boot the VM (`nix run .#feature-vm -- up`).
2. `run 'systemctl --failed'`, `run 'journalctl -u <unit> -n 50'`.
   Understand what's actually there.
3. Trigger the new behavior the way a user would. CLI command → run
   it as the user. GUI binding → send the keystroke and observe the
   side effect. HTTP endpoint → curl it. Daemon → exercise its actual
   job. **Don't grep the config and call it tested. Don't
   `systemctl is-active` and call it tested. Press the key. Make the
   request.** (Patterns behind PR #57's render-grep-only and PR #61's
   is-active-only broken merges.)
4. Edit, `apply`, poke again — no reboot per iteration. `reset` when
   state from earlier attempts could be masking the result.
5. Capture proof: `journalctl --since`, `systemctl status`, a
   screencap if it's UI, the actual artifact the script was supposed
   to produce.
6. `down`, push the PR.

The proof from step 5 belongs in the PR body. Future humans reading
the PR will trust a screencap or a `journalctl` excerpt much more
than a "verified locally" line.

## Recipes

### Verify a new systemd unit ran

```bash
nix run .#feature-vm -- up
nix run .#feature-vm -- run 'systemctl is-active <unit>; journalctl -u <unit> -n 30 --no-pager'
```

### Try a change without editing the repo

```nix
# /tmp/probe.nix
{ ... }: { systemd.services.probe = { wantedBy = [ "multi-user.target" ]; script = "echo hi"; }; }
```

```bash
nix run .#feature-vm -- apply /tmp/probe.nix
nix run .#feature-vm -- run 'systemctl status probe'
nix run .#feature-vm -- reset       # gone again
```

### Capture a screencap of a login / desktop state

```bash
nix run .#feature-vm -- screencap /tmp/snap.png
```

### Drive a GUI flow without a human (sendkey + screencap)

```bash
sock=~/.cache/feature-vm/run/qmp.sock
{ printf '{"execute":"qmp_capabilities"}\n'
  printf '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"down"}]}}\n'
  sleep 0.5
} | socat -t 5 - UNIX-CONNECT:"$sock" >/dev/null
nix run .#feature-vm -- screencap /tmp/after.png
```

### Secret-consuming services

Every `/run/agenix/<name>` in the VM is a throwaway fixture
(`feature-vm-fixture-<name>`; the klaffat ones are real-shaped keys
from `tests/lib/klaffat-fixtures.nix`). A service finds its file, reads
it and starts, so wiring, ownership and modes are testable. Anything
that authenticates to an outside service with it fails — expected, not
a regression. The real secrets cannot be opened in a VM: agenix-rekey
encrypts them to each laptop's host key, which only root there can
read. Verify the real-credential path on the host after deploy.

## Caveats — what the feature VM can NOT model

- Real LUKS / btrfs subvolumes / GPU acceleration / sound /
  touchpad. Hardware-specific config still needs the real laptop.
- Tailscale (no real network identity in QEMU usermode NAT).
- `nixos-auto-deploy` (disabled in vmVariant — it's a host-specific
  service).
- Public-network reachability (other LAN hosts can't see the VM;
  only `host:2222` is exposed via QEMU usermode `hostfwd`). In locked
  mode the guest has no outbound network at all.
- One VM at a time (fixed ssh port 2222). `up` refuses while one runs.
- While a VM runs it holds the memory-coordination lock, so other
  memory-heavy Nix jobs (including auto-deploy) wait until `down`.
- Some services that hard-code paths under `/home/jonathan/.claude/`
  or `/home/jonathan/.local/bin/` will fail to start in the VM
  because those paths aren't populated. Don't panic — the boot
  still reaches `multi-user.target` and the channels above still
  work. Disable noisy units in `feature-vm.nix`'s `vmVariant` if
  they get in the way of the change you're testing.

When the change-under-test legitimately needs one of the above, fall
back to: stage your change in a worktree, run the automated gate
(`nixos-automated-testing` skill), open the PR, and verify on the
real host after auto-deploy with `sudo nixos-rebuild switch
--rollback` ready as the safety net.

## Where this skill plugs into the pipeline

```
edit nix file
  │
  ├─ nixos-automated-testing skill → assertion gate (`vm-minimal`)
  ├─ nixos-agent-testing skill     → interactive smoke (this skill)
  │     ← only when branching / multistep / GUI / daemon-poke
  │       changes warrant it; pure data changes skip this layer.
  ▼
git push → PR → CI → human merge → push:main webhook → auto-deploy
```

The automated gate runs every PR for free. This skill is the bit
that an agent (or human) reaches for when the gate alone isn't
enough evidence to merge confidently.
