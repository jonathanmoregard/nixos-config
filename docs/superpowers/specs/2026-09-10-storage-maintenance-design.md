# Storage Maintenance Design

## Goal

Prevent root-filesystem exhaustion by collecting old Nix generations and stale worktrees while preserving active work and recoverable Git history.

## Scope

- Run Nix garbage collection weekly and delete generations older than 14 days.
- Run Nix store optimisation weekly.
- Treat `nix build --no-link` as the default for disposable local builds; do not alias or wrap `nix build` globally.
- Remove eligible worktrees when either their exact-tip pull request is merged or their branch tip is at least seven days old.
- Remove conventional Nix result links when removing an eligible worktree.
- Keep PostgreSQL test lifecycle changes in a separate Klaffat repository change.

## Worktree Eligibility and Safety

The existing discovery and safety model remains. A registered, branch-backed worktree is eligible when either:

1. GitHub reports a merged pull request whose `headRefOid` exactly equals the local branch tip; or
2. the local branch tip commit is at least seven days old.

Eligibility never bypasses mandatory safety checks. The worktree must live below a configured sweep root, must not be a protected/default branch or repository's own checkout, must be unlocked and present, must have clean `git status --porcelain` output, and must have no visible live process working directory inside it.

Merged-at-tip removal deletes both worktree and local branch immediately. Age-only removal deletes the worktree but preserves its branch, so committed work remains easy to recover even when no merged PR exists. Detached worktrees remain protected because no branch provides that recovery point.

GitHub authentication or API failure disables only merged-PR eligibility. It does not block age-only cleanup. Repositories without GitHub remotes can use age-only cleanup, but their branches are never deleted based on unavailable PR state. Any ambiguity still keeps the item and logs why.

## Nix Result Links

After eligibility and all safety checks pass, the sweeper inspects only top-level symlinks named `result` or `result-*`. It unlinks them only when `readlink` reports an absolute `/nix/store/*` target. A matching link with any other target makes removal fail closed. The final `git worktree remove` stays non-force, so ignored files other than verified Nix result links can still prevent deletion.

Removing an out-link makes its daemon-managed auto GC root stale; the next Nix GC removes that stale root. Future disposable builds should use `nix build --no-link`, avoiding persistent out-links in the first place.

## Nix Scheduling

Shared NixOS configuration enables `nix.gc.automatic` with a weekly calendar and `--delete-older-than 14d`. It also enables `nix.optimise.automatic` weekly. Existing boot-entry retention remains unchanged. No `min-free` emergency policy or `keep-derivations` change is included.

## Testing

- Extend the destructive worktree harness first. New fixtures prove recent merged worktrees are removed, old unmerged worktrees lose only their worktree, dirty/live/locked/default/detached worktrees remain, GitHub outage still permits age-only cleanup but no PR-based branch deletion, non-GitHub age-only cleanup works, and only verified Nix result links are removed.
- Add a fast Nix check asserting the evaluated Dellan configuration enables weekly GC with 14-day retention and weekly optimisation.
- Build both fast checks locally.
- Manually invoke the generated sweeper against disposable fixture repositories, including GitHub failure and unsafe result-link inputs.

## Non-goals

- No force-removal of dirty or ignored worktree contents.
- No deletion of unmerged local branches.
- No global alias changing normal `nix build` semantics.
- No PostgreSQL changes in this repository.
