# Pending for human — CI/CD-driven nixos-config workflow

## 2026-05-04: review the spec + worktree implementation

**Why pending**: 6 rounds of /advice-refine-test-loop produced a 700-line spec at `docs/specs/2026-05-04-cicd-driven-nixos-workflow.md`. Implementation in this worktree (`~/Repos/nixos-config-worktrees/cicd-workflow/`, branch `feat/cicd-workflow`) covers all `[auto]` steps. Three classes of work need human action:

1. Reviewing the spec + impl
2. Running `[human]` bootstrap steps (token retrieval, destructive `/etc/nixos` conversion, GitHub webhook setup, Rulesets activation, agenix secret creation)
3. Wiring the new modules into `hosts/dellan/default.nix`

**Steps for human**:

1. **Read the spec.** `docs/specs/2026-05-04-cicd-driven-nixos-workflow.md` (700 lines). Five sub-specs A–E. Skim the locked-decisions table, then dive into whichever sub-spec interests you. Threat-model section (~line 654) is the most important new content.

2. **Skim the implementation.** New files (all on `feat/cicd-workflow` branch):
   - `scripts/risk-rules.nix` + `scripts/classify-pr.sh` + `scripts/risk-rules.test.sh` (11 tests, all passing)
   - `modules/nixos/{nixos-deploy,github-webhook,actions-runner,atticd,claude-agent-users,ci-state,build-coordination}.nix`
   - `.github/workflows/{ci,gate}.yml`
   - `scripts/bootstrap-{bare-repo,deploy-target,rulesets}.sh`

3. **Decide whether to merge spec to main.** The spec is documentation; merging it to main is low blast (no impact on the build). Consider `git checkout main && git cherry-pick <spec commits 3bf1140..5d19e19>` then push, OR merge the whole feat branch.

4. **Implement per the spec's implementation order** (see end of spec doc, steps 1-17). Step 12 is a `[human-checkpoint]` — STOP there and verify before activating Rulesets.

5. **Run the existing VM gate before any rebuild:** `cd /etc/nixos && nix build .#checks.x86_64-linux.dellan-vm -L`.

**Things deliberately deferred (not in this worktree)**:

- VM-graphical tier (E.1) — placeholder in `ci.yml`
- AI-review subagent (D.3) — placeholder shellout to `./scripts/ai-review.sh`
- Wiring new modules into `hosts/dellan/default.nix` — held back so you review first
- Actual runner registration, Tailscale Funnel webhook setup, Rulesets activation — all `[human]` per the spec

**Known gaps from the round-1 implementation review** (advisor surfaced; not fixed because either deferred or out-of-scope):

- `nixos-deploy.service` runs `git fetch origin main` as root with no SSH credentials; will fail until either (a) the `origin` URL is HTTPS+anonymous (won't work for private), (b) a deploy key is wired via `GIT_SSH_COMMAND`, or (c) the `actions-runner-ssh-key` is reused. **Add to bootstrap procedure.**
- D.4 circuit-breaker logic (3-consecutive-AI-merges, 24h-post-failure window) is spec'd but not implemented in `ai-review.sh`.
- Tamper-detection on `/var/lib/ci-state/ai-approved-merges.jsonl` is spec'd but not wired to `classify-pr.sh`.
- GitHub Rulesets bootstrap state file is created on first run; need to commit `scripts/rulesets-state.json` after the first `evaluate`-mode run.
- `actions-runner.nix` known-hosts pin uses GitHub's ed25519 fingerprint hardcoded; rotate manually if GitHub rotates.

**Everything else done**:

- 6 rounds of spec refinement (caught: trust-boundary leak via `pull_request_target` split, classifier data-source mismatch, deploy-loop poison latch, notify-as-root failure, gh-wrapper self-approval, rule-table dead paths, label-add allowlist)
- 1 round of implementation review (caught: matrix concurrency mutex bug, self-Conflicts deploy unit, polkit-vs-no-D-Bus failure, force-push-past-stale-approval, GITHUB_OUTPUT fallback pollution, several module parse / shell / path issues)
- All 11 classifier unit tests pass; all 7 NixOS modules parse clean; shellcheck clean; existing VM gate eval green

**Total commits on `feat/cicd-workflow`**: ~12, in three groups — spec rounds 1-5, implementation, implementation round-1 fixes.

**To clean up if you don't want this work**:

```bash
git -C ~/Repos/nixos-config worktree remove ~/Repos/nixos-config-worktrees/cicd-workflow
git -C /etc/nixos branch -D feat/cicd-workflow
```
