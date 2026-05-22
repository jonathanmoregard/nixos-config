---
name: gha-debug
description: >
  Debug GitHub Actions failures, weird cache behaviour, or PR-trigger
  issues in the nixos-config repo. Use when CI looks broken: lane fails
  with an unhelpful error, cache-nix-action saves/restores wrong, PR
  doesn't trigger expected workflows, or job output is hard to parse.
  Don't trust action.yml or prose docs — clone the action source.
---

## When to invoke this skill

- A `vm-minimal` lane, `flake-check`, or `build` job failed and the
  failure message is generic ("Error: Process completed with exit
  code 1", "tar: command failed", "Permission denied").
- Cache-nix-action saved/restored slower than expected, missed the
  cache, or wrote a key that doesn't match the warm run.
- A PR opened/updated and CI didn't trigger (no run appears under
  `gh pr checks`), or a stale run from a previous SHA appears.
- An external action (cache-nix-action, determinate-nix-action,
  nothing-but-nix) behaves differently from what `action.yml` or
  the README claims.

## Quick start — 5-step recipe

```bash
# 1. PR + merge state
gh pr view <pr> --json state,headRefOid,mergeCommit,mergedAt

# 2. Recent runs (filter by branch or event)
gh run list --branch <branch> --limit 5 \
  --json databaseId,headSha,event,status,conclusion,name

# 3. Specific run's jobs
gh run view <run-id> --json status,conclusion,jobs

# 4. Save log to /tmp with semantic naming so re-inspection doesn't
#    re-fetch — pattern: /tmp/r<pr>-<lane>.log
gh run view --log --job=<job-id> > /tmp/r<pr>-<lane>.log
wc -l /tmp/r<pr>-<lane>.log

# 5. Targeted multi-pattern grep
grep -inE "error|fail|denied|gcroot|cache|killed|sock|mount" \
  /tmp/r<pr>-<lane>.log | tail -40
```

Naming convention `/tmp/r<pr>-<lane>.log` matters — multiple debug
sessions over the same PR can re-grep without re-fetching. Each `gh
run view --log` call costs ~10–30 s.

## Cache-nix-action specific recipe

GHA cache failures are the most common cause of "build slow / build
unstable" on this repo. Specific patterns to grep for:

```bash
# Save phase failures
grep -iE "Failed to save|tar.*failed|Permission denied|socket ignored" \
  /tmp/r<pr>-build.log

# Restore phase mismatches
grep -iE "Could not find|cache.*miss|primary-key.*not found" \
  /tmp/r<pr>-build.log

# GC / db inconsistency
grep -iE "Max bytes to free|deleting|gc.*finished|wal_checkpoint" \
  /tmp/r<pr>-build.log

# Upload size / speed
grep -iE "Saving cache|Cache.*saved.*MB|sec|upload" \
  /tmp/r<pr>-build.log
```

Common findings:

- `tar: /nix/lost+found: Permission denied` — the runner user can't
  read root-owned 700 dirs. Fix: `sudo rm /nix/lost+found` in a step
  before cache-save (or set permissions via a step). Real incident:
  unblocked cache-nix-action save in PR around commit `31b6125`.
- `socket ignored in archive` — caches can't include unix sockets;
  the warning is harmless but indicates an active service wrote a
  socket into the cache path. Stop the service before save if you
  care about reproducibility.
- Save-failure with no warning → next restore misses, cache key
  doesn't match warm run, full rebuild ensues.

## Don't trust the action — read its source

GitHub Action behaviour is often documented incorrectly or
incompletely. When a step does something unexpected, clone the
action repo and read the actual TypeScript/JavaScript.

```bash
# Find which version is pinned
grep -A 1 "uses: nix-community/cache-nix-action" .github/workflows/*.yml

# Clone the exact ref
git clone --depth=1 --branch <ref> \
  https://github.com/nix-community/cache-nix-action /tmp/cache-nix-action-v7
```

Then grep the source files that match the behaviour you're
investigating. For cache-nix-action specifically:

```bash
# Restore-phase logic
grep -n "copyDb\|chown\|sqlite3\|/nix/var/nix/db" \
  /tmp/cache-nix-action-v7/src/utils/restore.ts

# Save-phase logic
grep -n "createTarFile\|paths\|excludes" \
  /tmp/cache-nix-action-v7/src/utils/save.ts

# Database merge / db.sqlite handling
grep -n "mergeStoreDatabases\|wal_checkpoint" \
  /tmp/cache-nix-action-v7/src/utils/database.ts
```

Past incident: cache-nix-action's restore phase calls `sudo chown -R
runner:runner /nix/var/nix/db && sqlite3 ... 'PRAGMA
wal_checkpoint(TRUNCATE)'` BEFORE any nix command runs. That means
the `/nix/var/nix/db` directory must already exist — contradicting
the documentation's "plain tar, no nix needed" framing. Reading
`restore.ts` was the only way to discover the dependency. The fix
required reordering steps so determinate-nix-action runs first.

## PR doesn't trigger CI

Symptoms: open or update a PR, no CI run appears under
`gh pr checks <pr>`, or only a stale run from a previous SHA shows.

```bash
# 1. Check workflow trigger rules
grep -A 10 "^on:\s*$\|pull_request:" .github/workflows/ci.yml

# 2. Check concurrency cancellation
grep -A 4 "concurrency:" .github/workflows/ci.yml

# 3. Confirm PR state + head ref
gh pr view <pr> --json state,headRefName,headRefOid

# 4. List recent runs to spot what DID trigger
gh run list --repo jonathanmoregard/nixos-config --limit 8 \
  --json databaseId,headSha,event,workflowName,status,conclusion
```

Common causes:
- `paths:` filter on the workflow excludes the changed files. Check
  the filter. Path-filtered workflows can be intentional (e.g.
  `vm-graphical` only runs on theme/desktop diff).
- `concurrency: group: ... cancel-in-progress: true` cancelled the
  new run because a previous run for the same PR is still alive.
  `gh run list` will show a `cancelled` status next to the missing run.
- Fork-PR guard (`if: head.repo == base.repo`) — this repo doesn't
  accept fork PRs; the workflow body is gated. A fork PR shows
  green-but-skipped checks.
- Branch protection rule requires a status check that no workflow
  produces. Merge stays blocked, no clear "why" in the GitHub UI.
  Compare required-checks list against actual job names in CI.

## Pitfalls

- `gh run view --log` returns 404 for the first ~30 s after a job
  finishes. Fallback: `gh api /repos/<owner>/<repo>/actions/runs/<id>/logs > /tmp/logs.zip`,
  unzip, then grep individual job files.
- Job IDs (`--job=`) are different from run IDs (`<run-id>`). Get
  the job ID from `gh run view <run-id> --json jobs`.
- `gh run view --log --job=<job-id>` outputs ANSI escape codes for
  group folding (`::group::Foo` / `::endgroup::`). Add `| sed 's/\x1b\[[0-9;]*m//g'`
  if you need clean text for further grep chains.
- `gh run rerun --failed` re-runs only failed jobs in a workflow,
  not the whole thing. Useful for caching debug where one lane
  failed but the rest are green.

## When to escalate to advice-refine-test-loop

If the CI failure pattern is novel — not a one-off flake, not
explained by the cluster of known patterns above, and not obviously
the action's source code — and merging would auto-deploy the change:
invoke `advice-refine-test-loop` before pushing more commits. Round
1 with the seed hypothesis "this is happening because <X>" + the
log excerpt forces a fresh skeptical pass rather than chaining more
guesses.
