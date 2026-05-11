---
name: nixos-config-dev
description: >
  NixOS config edits via worktree + PR. Use whenever the agent
  modifies anything under /etc/nixos/, ~/Repos/nixos-config/, or
  ~/Repos/nixos-config-worktrees/ — direct edits to the first two
  fail by construction, so the worktree → PR → auto-deploy flow
  this skill encodes is the only working path. Triggers on edits
  to flake.nix, hosts/*.nix, modules/*.nix, home/*.nix, on phrases
  like "rebuild dellan", "switch nixos config", "update
  home-manager", and on creating PRs in the nixos-config repo.
  Routes the agent into the right testing skills
  (`nixos-automated-testing`, `nixos-agent-testing`,
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
git commit -m "feat(scope): summary"

# 3. Test before pushing — see "Testing skills" below.

# 4. Push, open PR
git push -u origin feat/<slug>
gh pr create --title "..." --body "..."

# 5. Watch CI
gh pr checks <PR_NUMBER>

# 6. For non-trivial PRs about to be merged, lead with the
#    `advice-refine-test-loop` skill — Opus advisor + empirical
#    re-verification across rounds catches fail-open paths, schema
#    mismatches, and silent regressions that single-pass review
#    misses. Cheap insurance on changes that auto-deploy to your
#    daily-driver.
```

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
| Pre-implementation planning for non-trivial work | `brainstorming` |
| While writing the change | `test-driven-development` — extend `tests/dellan-vm.nix` before the code, watch it fail, then make it pass |
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
| `classify` | Posts `risk:trivial/low/medium/high/critical` label + per-source breakdown comment |
| `label-gate` | Enforces merge gate based on the label + reviews |

`risk:trivial` / `risk:low` → auto-merge once green.
`risk:medium` / `risk:high` / `risk:critical` → fresh human approval
required (filtered by `commit_id == HEAD_SHA` so a force-push past a
stale review doesn't pass).

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

Stale worktrees waste disk; daily cron sweeps them after 7 days, but
it's tidier to remove eagerly.

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
- Branch protection rejects merge → check the `label-gate` status; PR
  likely needs human approval for its risk bucket
- `nixos-deploy.service` poisoned → see desktop notification's
  rollback command, then
  `sudo rm /var/lib/nixos-deploy/current-poison && sudo systemctl reset-failed nixos-deploy`
