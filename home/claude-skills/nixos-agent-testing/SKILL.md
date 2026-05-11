---
name: nixos-agent-testing
description: >
  Use to interactively smoke-test NixOS config changes inside an
  ephemeral QEMU "feature VM" before opening / merging a PR. Drives
  the dellan host config in a sandbox with SSH on host:2222, 9p host
  worktrees mounted, agenix secrets decrypted, and QMP/serial/sendkey/
  screencap control channels exposed. Companion to
  `nixos-automated-testing` (that one is the assertion gate CI runs;
  this one is the interactive sandbox you reach for when a change
  needs eyes on real behavior — anything with branching logic, a
  multistep script, a graphical side effect, or a daemon you want to
  poke).
  Triggers on phrases like "spin up the VM", "boot the feature VM",
  "feature vm", "test in feature VM", "smoke test (the change)",
  "screencap the VM", "send keys to the VM", "QMP", "serial console",
  and any time the agent edits branching logic / `mkIf` / `optionals`
  / `writeShellApplication` / activation scripts in the nixos-config
  repo.
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
- A **daemon needs poking** to verify behavior (curl an endpoint,
  trigger a unit and read its log, watch a timer fire).
- A **PR is risk:medium or higher** per the classifier, and you want
  to convince yourself before clicking merge.

Skip when the change is pure data — package added, config value
flipped, string updated. The automated gate alone is the right level
for that.

## Quick start

```bash
cd ~/Repos/nixos-config-worktrees/<your-branch>
nix run .#feature-vm                                   # headless (Claude Code default)
```

In another terminal (or via the agent's next bash call):

```bash
ssh -p 2222 -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/id_ed25519 jonathan@localhost
```

SSH comes up in ~5-10 s after launch. Stop the VM with
`Ctrl+C` on the launcher (or `systemctl --user stop feature-vm`
if you launched via `systemd-run`).

## Headless vs headful

| Mode | Command | When |
|------|---------|------|
| Headless (default) | `nix run .#feature-vm` | Agentic flows, scripted smoke. No window. Drive via SSH + QMP + serial. |
| Headful (GUI) | `nix run .#feature-vm-headful` | Human at the laptop wants to see / drive the GUI. Requires `$DISPLAY` (i.e. logged-in Cinnamon session). Same control sockets still active. |

Claude Code should default to **headless** every time. Only invoke
headful when the user has explicitly asked for a window.

## What you get inside the VM

- `dellan` hostname, same modules as prod, agenix decrypted (5
  jonathan-readable secrets in `/run/agenix/`).
- `/mnt/worktrees` — host's `~/Repos/nixos-config-worktrees`
  9p-mounted R/W. Edits on the host appear inside the VM without a
  reboot.
- `jonathan` user, UID 1000, in `wheel` + `keys`, sudo without
  password (`security.sudo.wheelNeedsPassword = false`).
- SSH on host:2222, key `~/.ssh/id_ed25519`.
- `-snapshot` mode → every reboot is clean state. No carryover of
  dconf, journal, host keys, or test pollution between launches.

## Control channels (headless and headful both expose these)

The launcher prints the exact paths on startup. They live under
`$TMPDIR/feature-vm.XXXXXX/` so they auto-clean on exit.

### SSH — shell exec, file transfer, sudo

```bash
ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i ~/.ssh/id_ed25519 jonathan@localhost '<command>'
```

`sudo -n <cmd>` works (no password). `scp -P 2222` for transfer.

### QMP — JSON control over `qmp.sock`

```bash
sock=/tmp/feature-vm.<XXX>/qmp.sock
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

### Screencap — `feature-vm-screencap` helper

```bash
nix run .#feature-vm-screencap -- /tmp/feature-vm.<XXX>/qmp.sock /tmp/snap.png
```

Talks to QMP `screendump`, converts the resulting PPM to PNG via
`pnmtopng`, and prints the output path. Works on headless because
QEMU's VGA model is still present without `-display none` driving a
host-side window.

### Serial console — getty over a Unix socket

```bash
socat - UNIX-CONNECT:/tmp/feature-vm.<XXX>/serial.sock
```

Send two newlines to get `dellan login:`. Useful before sshd is up,
or when debugging a kernel panic — the kernel `console=ttyS0` arg
writes here too.

### 9p shared dir — live edits

`/mnt/worktrees/<branch>/...` inside the VM == host's
`~/Repos/nixos-config-worktrees/<branch>/...`. Bidirectional. Edit a
file on the host, run it inside the VM, no reboot required.

## Diagnose-then-act pattern

The interactive VM's value vs. the automated gate is that you can
**ask questions** of the running system. Pattern:

1. Boot the VM (`nix run .#feature-vm`).
2. SSH in and `systemctl --failed`, `systemctl is-active <unit>`,
   `journalctl -u <unit> -n 50`. Understand what's actually there.
3. Trigger the new behavior end-to-end (curl the endpoint, fire the
   timer, run the script that was added).
4. Capture proof: `journalctl --since`, `systemctl status`, a
   screencap if it's UI, the actual artifact the script was supposed
   to produce.
5. Decide: did the branching code go down the expected path? Are
   the side effects what you wanted?
6. Stop the VM, push the PR.

The proof from step 4 belongs in the PR body. Future humans reading
the PR will trust a screencap or a `journalctl` excerpt much more
than a "verified locally" line.

## Recipes

### Verify a new systemd unit ran

```bash
nix run .#feature-vm &              # headless, fresh state
ssh -p 2222 ... 'systemctl is-active <unit>; journalctl -u <unit> -n 30 --no-pager'
```

### Verify a new script's actual output (not just exit code)

```bash
ssh -p 2222 ... '<wrapper>'         # run it for real
ssh -p 2222 ... 'ls -la <expected output path>; cat <output>'
```

### Capture a screencap of a login / desktop state

```bash
tmpdir=$(ls -d /tmp/feature-vm.*/ | head -1)
nix run .#feature-vm-screencap -- "$tmpdir/qmp.sock" /tmp/snap.png
# then attach /tmp/snap.png to the PR
```

### Drive a GUI flow without a human (sendkey + screencap)

```bash
# QMP send-key, then screencap to verify state change
sock=/tmp/feature-vm.<XXX>/qmp.sock
{ printf '{"execute":"qmp_capabilities"}\n'
  printf '{"execute":"send-key","arguments":{"keys":[{"type":"qcode","data":"down"}]}}\n'
  sleep 0.5
} | socat -t 5 - UNIX-CONNECT:"$sock" >/dev/null
nix run .#feature-vm-screencap -- "$sock" /tmp/after.png
```

### Test a secret-consuming service end-to-end

agenix decrypts in initrd via the host-ssh 9p mount, so
`/run/agenix/<name>` is populated before any service starts.
Anything consuming `config.age.secrets.<name>.path` works
unchanged. If a secret is missing, the launcher's preflight refuses
to boot — that's the loud-failure mode by design.

## Caveats — what the feature VM can NOT model

- Real LUKS / btrfs subvolumes / GPU acceleration / sound /
  touchpad. Hardware-specific config still needs the real laptop.
- Tailscale (no real network identity in QEMU usermode NAT).
- `nixos-auto-deploy` (disabled in vmVariant — it's a host-specific
  service).
- Public-network reachability (other LAN hosts can't see the VM;
  only `host:2222` is exposed via QEMU usermode `hostfwd`).
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
