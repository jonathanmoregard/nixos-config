---
name: nixos-config-dev
description: >
  NixOS config edits via worktree + PR. Use whenever the agent
  modifies anything in the nixos-config repo. Routes into the right
  testing skills (`nixos-automated-testing`, `nixos-agent-testing`,
  `test-driven-development`, `advice-refine-test-loop`) based on
  the shape of the change.
---

## First action when triggered

`cd ~/Repos/nixos-config-worktrees/<slug>` — **never operate inside
/etc/nixos**, even though Claude Code's working-directory banner may
announce it. Edits to `/etc/nixos/` will be overwritten on the next
auto-deploy and require sudo. If no relevant worktree exists yet,
create one (see "Standard flow" below).

## The repo layout (you cannot edit /etc/nixos directly)

```
~/Repos/nixos-config/                    ← bare repo (no working tree)
~/Repos/nixos-config-worktrees/
    main/                                ← read-only browse
    <branch-slug>/                       ← work happens here, one per branch
/etc/nixos/                              ← root-owned; auto-deployed from
                                           origin/main on push:main events
```

`/etc/nixos/` is root-owned and auto-rewritten by `nixos-deploy.service`
on every merge to `main`. Edits there are pointless (overwritten on next
deploy) and require sudo. `~/Repos/nixos-config/` is bare — there's
literally no working tree to edit. **Always work in a worktree.**

## Standard flow

```bash
# 1. New worktree off main
cd ~/Repos/nixos-config
git worktree add ~/Repos/nixos-config-worktrees/<slug> -b feat/<slug> main
cd ~/Repos/nixos-config-worktrees/<slug>

# 2. Plan + edit
#    For anything beyond trivial, lead with the `brainstorming` skill
#    before code, then the `test-driven-development` skill while
#    coding (write the assertion first, watch it fail, make it pass).
$EDITOR home/whatever.nix
git add -A

# 3. Test before pushing — see "Testing skills" below.

# 4. Commit with the pre-push checklist in the message body
#    (safe-bash MCP refuses pushes whose HEAD commit lacks it; see
#    "Pre-push checklist trailer" below).
git commit -m "feat(scope): summary

Body explaining the change.

Pre-push checklist:
- Type: risky                                # or 'pure-data'
- Rebased on origin/main: yes
- Local gate: nix build .#checks.x86_64-linux.dellan-vm rc=0
- Interactive smoke (nixos-agent-testing): <yes — cmd + observed | N/A — reason>
- Advisor review (advice-refine-test-loop): <yes — rounds + verdict | N/A — reason>
- feature-vm.nix modified: no                # MUST match diff
- Risky markers in diff: <list, or 'none'>
- Behavioural evidence: <cmd + observed output>
"

# 5. Push, open PR
git push -u origin feat/<slug>
gh pr create --title "..." --body "..."

# 6. Watch CI
gh pr checks <PR_NUMBER>

# 7. For non-trivial PRs about to be merged, lead with the
#    `advice-refine-test-loop` skill — Opus advisor + empirical
#    re-verification across rounds catches fail-open paths, schema
#    mismatches, and silent regressions that single-pass review
#    misses. Cheap insurance on changes that auto-deploy to your
#    daily-driver.
```

## Pre-push checklist trailer

The safe-bash MCP refuses `git push` from any clone of the nixos-config
repo whose HEAD commit message lacks a `Pre-push checklist:` block (or
carries internally inconsistent claims). This exists because two recent
PRs (#57, #61) shipped broken changes despite the HARD RULE being in
context the whole time — the skill prose alone wasn't enough; this gate
enforces structurally.

**Detection is by remote URL, not filesystem path.** Any candidate path
(parsed from `cd <path>` in the command, `git -C <path>` flag, or the
MCP server's cwd) is probed with `git rev-parse --show-toplevel`; if it
resolves to a working tree whose configured remotes include a URL
matching `jonathanmoregard/nixos-config` (any of: ssh `git@github.com:…`,
https, with or without `.git` suffix), the gate fires. A scratch clone
at `/tmp/foo/`, a worktree under `~/projects/`, or anywhere else outside
`~/Repos/nixos-config-worktrees/` is gated identically. Conversely, a
worktree that happens to live under the canonical worktrees dir but
points its origin elsewhere is NOT gated.

### Pure-data (package add, version bump, comment, doc edit)

```
Pre-push checklist:
- Type: pure-data
```

Accepted iff the diff has **no** risky markers (mkIf / optionals / ExecStart /
writeShellApplication / `sh -c` / microvm / virtiofsd / networking.useDHCP /
activationScripts / systemd.services.\*) AND does not touch
`modules/nixos/feature-vm.nix`. If either is true → promote to `Type: risky`.

### Risky (anything else)

```
Pre-push checklist:
- Type: risky
- Rebased on origin/main: yes
- Local gate: nix build .#checks.x86_64-linux.dellan-vm rc=0
- Interactive smoke (nixos-agent-testing): <yes — cmd + observed | N/A — reason>
- Advisor review (advice-refine-test-loop): <yes — rounds + verdict | N/A — reason>
- feature-vm.nix modified: no
- Risky markers in diff: <list, or 'none'>
- Behavioural evidence: <cmd + observed output>
```

| Field | Verified by gate | Notes |
|---|---|---|
| `Type` | yes (literal `pure-data` or `risky`) | Mismatch with diff = reject |
| `Rebased on origin/main` | yes (`merge-base HEAD origin/main == origin/main`) | `yes` claim while behind main = reject |
| `Local gate` | no — typed claim | Audited post-hoc via `git log` |
| `Interactive smoke (nixos-agent-testing)` | no — typed claim | Required for branching / multistep / GUI / daemon-poke. `N/A` only when the VM can't model the change (hardware-only). |
| `Advisor review (advice-refine-test-loop)` | no — typed claim | Required before merge on medium/high-risk PRs. `N/A` only for small / contained risky changes. |
| `feature-vm.nix modified` | **yes — diff cross-checked** | `no` claim with feature-vm.nix in diff = reject |
| `Risky markers in diff` | no — typed claim | Forces enumeration |
| `Behavioural evidence` | no — typed claim | "Build green" / "verified locally" do NOT count |

**The `Behavioural evidence` field is what historically went hollow.** Quote the actual command + observed output that proves the runtime path works. **User-realistic = what the user does** (run, press, hit), not what activates around it. `systemctl is-active` proves the unit is loaded; it does not prove the feature works. Valid examples:

- `nix run .#feature-vm; ssh -p 2222 jonathan@localhost 'systemctl is-active research-agent'; curl localhost:8080/health → 200`
- `xvfb-run kitty; xdotool key ctrl+shift+c; xclip -o -selection clipboard → "foo" (no trailing \n)`
- "hardware-only change (touchpad palm rejection); cannot model in VM; will verify on real host after auto-deploy with `nixos-rebuild switch --rollback` ready"

**`feature-vm.nix modified: yes (<reason>)`** is fine for legit reasons (wiring a new module into vmVariant, adding a fixture). It's only the **`no` claim while the diff DOES touch the file** that gets rejected — that combination is the PR #61 anti-pattern (agent stubbed virtiofsd shares to make boot succeed, smoke ran against the stub, prod path never exercised).

### Override (audited)

`Override: [skip-vm-gate] <reason>` line in the commit message bypasses the gate. Logged to stderr by the MCP; visible in `git log` forever. Reserve for true emergencies. Not a shortcut.

## Testing skills

Two complementary VM testing layers, both important. Pick by what
the change actually does, not by mood. **Rows below are additive,
not either/or** — a single change can match several rows (e.g.
branching logic with a TDD-amenable assertion → write the assertion
first via `test-driven-development`, then smoke-test in the feature
VM via `nixos-agent-testing`).

| Change shape | Skill(s) to invoke |
|--------------|--------------------|
| Anything that builds — *required* | `nixos-automated-testing` (the assertion gate CI runs on every PR; runs locally before pushing) |
| Branching logic (`mkIf`, `optionals`, `if`/`case`), multistep scripts (`writeShellApplication`, activation scripts), GUI changes, daemons that need poking — *required pre-PR* | `nixos-agent-testing` (boot the feature VM, drive via SSH/QMP/screencap, capture proof for the PR body) |
| Modules emitting executable shell (`pkgs.writeShellScript`, `pkgs.writeShellApplication`, `serviceConfig.ExecStart =`, `nix.settings.post-build-hook`, `system.activationScripts.*`) — *required pre-PR* | **Runtime invocation test** of the generated script with adversarial inputs: empty/missing input, sub-command exits non-zero, sub-command hangs past timeout. Eval validates types; the VM gate validates integration but may not exercise the script (e.g. a post-build-hook whose agenix token is absent in the test VM). Pattern: `nix build` the derivation, run `/nix/store/.../<name>` directly with crafted env; OR write a parameterized analogue in `/tmp` swapping the real binary for `coreutils/false` / `coreutils/sleep`. Past incident (PR #67): a cachix post-build-hook's `if ! cmd; then rc=$?` looked correct on eval but bash zeroed `rc`, hiding timeout-vs-failure distinction from the journal and producing misleading diagnostics. |
| Anything touching the injection-scanner — a scanner pin bump in a consuming repo, a wrapper env change, a new call site — *required pre-PR* | **Agent-test EVERY call site, at the MOST RECENT scanner version.** Call sites on this host: `research-agent-mcp` (home/research-agent-mcp.nix), `futuresearch-gate-mcp` (home/futuresearch-gate-mcp.nix), `claude-cl-sync-wrap` (home/claude-services.nix). The gate and cl-sync self-update the scanner to origin/main at runtime, so a test against an older pinned rev proves nothing about what prod will run. Test on the real host, not the VM (the VM has no agenix keys and no egress): build the wrappers, then run each built binary directly — `timeout 90 /nix/store/…/research-agent-mcp </dev/null` and the gate equivalent must log `boot smoke ok` and exit 0; for cl-sync run the wrap script or `systemctl --user start claude-cl-sync` post-deploy and check the journal for a clean scan. Past incidents, both from testing only ONE call site: #144 (gate lacked LAKERA_API_KEY — only research-agent-mcp had been smoked) and scanner fb31c84 (stdlib urllib needs SSL_CERT_FILE on NixOS — every call site broke, none had been re-smoked after the pin bump). |
| Pre-implementation planning for non-trivial work | `brainstorming` |
| While writing the change | `test-driven-development` — extend the right `tests/<feature>.nix` lane (base / desktop / keyring / kitty / claude-pane) before the code, watch it fail, then make it pass |
| Before clicking merge on a medium/high-risk PR | `advice-refine-test-loop` — multi-round Opus review with empirical re-verification |

Do not ask the user whether to run these. The only changes that
legitimately skip `nixos-agent-testing` are those where **no
downstream code branches on the changed value and no script reads
it** — e.g. adding a package to `environment.systemPackages`, bumping
a version pin, fixing a comment. If the change flips a boolean that
gates an `mkIf`, alters a value an `optionals` reads, modifies a
script that runs at boot, or changes the input to anything
conditional anywhere downstream, treat it as branching → run the
interactive VM. When in doubt, run it; the cost is cheap.

## What you'll see on the PR

| Status check | Meaning |
|---|---|
| `eval (dellan)`, `build (dellan)` | Flake evaluates + system derivation builds |
| `vm-minimal (1..3)` | Three parallel ephemeral-VM e2e tests |
| `vm-graphical` | Runs only when desktop files change |

## After merge

Auto-deploy: GitHub `push: main` event → webhook → `nixos-deploy.service`
on dellan does `git fetch origin main + reset --hard + nixos-rebuild
switch`. Desktop notification fires on success (low priority) or failure
(critical, with rollback command).

**Don't `sudo nixos-rebuild switch` casually** — bypasses the gate stack.
Reserved for: bootstrap install, hardware-config edits the VM gate
can't model (touchpad, GPU, LUKS), emergency rollback
(`sudo nixos-rebuild switch --rollback`).

## Don't try

- `git push origin main` — branch protection rejects (no direct push)
- editing `~/Repos/nixos-config/<file>` — bare repo, file doesn't exist
- editing `/etc/nixos/<file>` — root-owned + auto-deploy will overwrite;
  Claude Code's permissions also deny Edit/Write on this path
- `nixos-rebuild switch --flake /etc/nixos#vm` — `vm` host is legacy
  (being phased out); target is `dellan`
- `gh pr merge` (any flags) — denied at the safe-bash MCP layer; merges
  happen via the GitHub UI's merge button so required checks stay the
  deliberate gesture, not a CLI autopilot
- `git push --force` — branch protection rejects force-pushes to `main`

## Cleanup after PR closes

```bash
git -C ~/Repos/nixos-config worktree remove ~/Repos/nixos-config-worktrees/<slug>
```

Stale worktrees waste disk; the daily `nixos-worktree-sweep` systemd
user timer (home/worktree-sweep.nix) removes a worktree + its branch
only when ALL of: its PR is merged with the merged head matching the
local tip, the tip commit is >7 days old, `git status --porcelain` is
empty, and no live process has its cwd inside. It also deletes
worktree-less local branches whose PR is merged and tip is >7 days
old. Everything else is kept with a journal-logged reason
(`journalctl --user -u nixos-worktree-sweep`); a gh outage means zero
deletions. Still tidier to remove eagerly.

## Failure-mode quick reference

- `Path '<file>' in the repository "/etc/nixos" is not tracked by Git`
  → `git add -A` before commit; flake eval ignores untracked files
- "Permission denied (publickey)" pushing → root has no GH creds; push
  from your worktree (jonathan) not from `/etc/nixos`
- `agenix` / `.age` errors at activation → secret was encrypted with
  wrong recipients OR plaintext was empty (322-byte ciphertext is the
  empty-baseline tell). Re-encrypt with `nix run github:ryantm/agenix --
  -e <name>.age` from `secrets/` dir
- VM gate fails on autodoro → known interaction; see
  `docs/proposals/2026-05-04-split-vm-tests.md`
- Branch protection rejects merge → check the failing required
  status check (eval / build / vm-minimal); fix and push again
- `nixos-deploy.service` poisoned → see desktop notification's
  rollback command, then
  `sudo rm /var/lib/nixos-deploy/current-poison && sudo systemctl reset-failed nixos-deploy`
