---
status: proposed
category: drift
subcategory: skills
date: 2026-06-25
source: incident — nixos-agenix-secret stale during agenix-rekey migration
---

## Cross-repo skill staleness — migrate the last `nixos-*` skill + add a docs-linter

### Incident motivating this

While setting up agenix-managed EUIPO secrets in PR #127, the `nixos-agenix-secret` skill at `~/.claude/skills/nixos-agenix-secret/SKILL.md` was followed verbatim and produced commands that **do not work** in this repo. Specifically:

- The skill told the agent to run `agenix -e <name>.age` from the `secrets/` dir.
- That command requires `secrets/secrets.nix` (the legacy ryantm/agenix rules file).
- `secrets/secrets.nix` was **deleted** in commit `e451e78` ("feat(secrets): migrate to agenix-rekey master-identity model") as part of the agenix-rekey migration.
- The legacy `agenix` CLI on PATH errors at decrypt time with `path 'secrets/secrets.nix' does not exist`.

Diagnosis took multiple rounds. The agent guessed at agenix-rekey CLI shapes, gave wrong commands twice, hit explicit user frustration. Root cause: **the skill file lives in the `.claude` repo, gets edited in isolation from nixos-config, and went out of sync silently when the migration landed.**

The corrected skill is now in `~/.claude/skills/nixos-agenix-secret/SKILL.md` (updated this session). But the same staleness gap remains structurally: anything else in `.claude` that references nixos-config conventions can drift again, undetected, until a session hits the wall.

### Current state — pattern already exists for 3 of 4 `nixos-*` skills

`home/claude-skills.nix` already symlinks three skills from this repo into `~/.claude/skills/`:

```nix
skills = [
  "nixos-config-dev"
  "nixos-automated-testing"
  "nixos-agent-testing"
];
```

Each skill's content lives at `home/claude-skills/<name>/SKILL.md` and Home Manager creates `~/.claude/skills/<name>/SKILL.md` as a symlink into the Nix store. Edits go through the worktree → PR → auto-deploy gate. CI on the PR runs the eval + build + VM lanes against the *same* commit that ships the skill content, so a flake-attribute rename and the matching skill update are *one atomic diff*.

The outlier is **`nixos-agenix-secret`** — still a real file in `.claude` repo. It's the one that broke.

### Proposal — two changes, one PR

**1. Migrate `nixos-agenix-secret` into the existing pattern.**

  - Add the file at `home/claude-skills/nixos-agenix-secret/SKILL.md` (copy of the current corrected content).
  - Append `"nixos-agenix-secret"` to the `skills` list in `home/claude-skills.nix`.
  - In the matching `.claude` PR, delete `~/.claude/skills/nixos-agenix-secret/` from the repo so the auto-deploy can land the symlink without home-manager refusing to clobber a tracked file.

  Migration mechanics — order matters because Home Manager refuses to overwrite untracked content:
  1. Open the nixos-config PR with the new file + list entry.
  2. Open the `.claude` PR that removes `skills/nixos-agenix-secret/`.
  3. **Locally**: `rm -rf ~/.claude/skills/nixos-agenix-secret` to clear the path before the deploy.
  4. Merge both PRs (order doesn't matter once the local path is clear).
  5. Auto-deploy lands the symlink; `.claude` PR removes the obsolete duplicate from the git index.

**2. Add a docs-linter that catches stale `nix run .#X` references across both repos.**

  Drop `scripts/check-docs-commands.sh`:

  ```bash
  #!/usr/bin/env bash
  # Greps every doc/script in this repo + any extra search roots passed
  # as args for `nix run .#<attr>` references and asserts each <attr>
  # resolves on the current flake via `nix eval` (no realization).
  set -euo pipefail
  ROOTS=("$@")
  ROOTS+=(home modules hosts docs proposals scripts CLAUDE.md)
  fail=0
  grep -rEho 'nix run \.#[a-zA-Z0-9._-]+' "${ROOTS[@]}" 2>/dev/null \
    | sort -u \
    | while read -r ref; do
        attr="${ref#nix run .#}"
        if ! nix eval ".#${attr}" --apply 'x: null' >/dev/null 2>&1; then
          echo "STALE: $ref" >&2
          fail=1
        fi
      done
  exit $fail
  ```

  Wire into `.github/workflows/ci.yml` as a new fast job alongside `flake check (eval)`:

  ```yaml
  docs-cross-repo:
    runs-on: ubuntu-latest
    if: head.repo == base.repo  # fork-guard
    steps:
      - uses: actions/checkout@v4   # nixos-config
      - uses: actions/checkout@v4   # .claude alongside
        with: { repository: jonathanmoregard/.claude, path: dotclaude }
      - uses: DeterminateSystems/determinate-nix-action@v3
      - run: scripts/check-docs-commands.sh ./dotclaude
  ```

  Mirror job in `.claude` CI: checks out nixos-config@main + runs the same script. Catches `.claude` PRs that reference attributes the current nixos-config no longer has. The script lives once in nixos-config; `.claude`'s workflow just clones nixos-config and invokes it.

  Cost: one warmed `nix eval` (~5–10s on cold runner; faster with cache-nix-action) + N near-instant attribute lookups. Sub-minute job.

### Why both changes in one PR

Migrating the skill alone closes the *immediate* hole (the one we just hit). The docs-linter alone catches *future* drift but doesn't fix the present orphan. Together: the present orphan goes away, and the next attempt to introduce one fails CI loudly.

The linter is also the safety net for skills that legitimately can't migrate — anything in `.claude` that has cross-cutting use beyond this repo (e.g. `brainstorming`, `test-driven-development`) but still happens to reference nixos-config attributes in examples will be caught.

### Open questions

1. **Cross-PR ordering**: `.claude` CI evaluates against `nixos-config@main`, so a coordinated change (rename a flake attr + update a `.claude`-resident skill) must merge nixos-config first, then `.claude`. Mitigation: have the linter failure message spell this out explicitly so the next agent doesn't loop on it.

2. **Skills that *should* stay in `.claude`**: generic ones (`brainstorming`, `test-driven-development`, `verification-before-completion`, `using-git-worktrees`, etc.) shouldn't migrate — they have no nixos-config dependency and would coupling them to this flake constrains where they're usable. Heuristic: if `grep -rEho 'nix run \.#' skill.md | head -1` is empty, leave in `.claude`.

3. **What about `nixos-binary-debug`?** Listed in `home/claude-skills/` but not in the `skills` list. Either it's WIP or the list is incomplete. Audit during this PR; either add to the list or document why it's excluded.

4. **Secrets in skill content**: skills going into nixos-config are public via git. Any skill that needs a real credential in an example is a no-go; redact to `<KEY>` placeholders. None of the current `nixos-*` skills appear to have this issue, but flag for future.

### Implementation phases

1. **Phase 1 (this PR)**: skill migration + docs-linter + workflow job, all in nixos-config. Companion `.claude` PR deletes the duplicate file.
2. **Phase 2 (separate PR, `.claude` side)**: add the mirror docs-linter workflow in `.claude` that clones nixos-config.
3. **Phase 3 (followup, optional)**: audit other skills in `.claude` for `nix run .#X` references; migrate any that meet the "intrinsically about this flake" bar. `repo-autosync`, `nixos-binary-debug`, and any `gha-debug`-style skill that references this repo's CI conventions are candidates.

### Verify

Migration verification:
```bash
# After PR merges + auto-deploy:
readlink ~/.claude/skills/nixos-agenix-secret/SKILL.md
# Expect: a /nix/store/.../home/claude-skills/nixos-agenix-secret/SKILL.md path
```

Docs-linter verification:
```bash
cd ~/Repos/nixos-config-worktrees/<slug>
scripts/check-docs-commands.sh ~/.claude   # expect: rc=0 on clean tree
# Then temporarily reintroduce a bad ref to confirm it catches:
sed -i 's|nix run \.#agenix-rekey|nix run .#agenix-DEAD|' \
    home/claude-skills/nixos-agenix-secret/SKILL.md
scripts/check-docs-commands.sh ~/.claude   # expect: rc=1, "STALE: nix run .#agenix-DEAD"
git checkout home/claude-skills/nixos-agenix-secret/SKILL.md
```

### Cost / risk

- **Implementation cost**: small. Phase 1 is ~30 lines of shell + 10 lines of YAML + a file move + a list-line edit.
- **Risk**: Home Manager clobber-refuse during deploy if the user forgets to `rm` the existing real file. Mitigated by spelling it out in the PR body and by `home/claude-skills.nix`'s existing comment ("If `~/.claude/skills/<name>/` already exists as a real directory, remove it before the rebuild").
- **Maintenance**: linter requires zero ongoing care unless command-naming conventions in the flake change (e.g. `nix run .#agenix-rekey.<system>.<cmd>` → some new convention). At that point the linter is one regex edit.

### Recommendation

Proceed. Skill staleness is a recurring failure mode (this is the second incident: the [agenix-rekey migration commit message itself](https://github.com/jonathanmoregard/nixos-config/commit/e451e78) documents `nix run .#agenix -- edit ...` which never worked — same class of drift, in the canonical source). One small PR closes both the present orphan and the future-drift gap.
