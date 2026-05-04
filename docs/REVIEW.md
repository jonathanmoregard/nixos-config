# CI/CD workflow — review report

Catalog of what changed, what's skipped, what may be redundant, what was tested, and how to set this up. Companion to `docs/specs/2026-05-04-cicd-driven-nixos-workflow.md` and `pending_for_human.md`.

---

## 1. Additions from advisor (holes patched)

35 issues caught across 7 advisor rounds (6 spec + 1 implementation). Grouped by category:

### Trust-boundary leaks
| Caught | Why bad | Fix |
|---|---|---|
| `pull_request` workflows on private repo + self-hosted runner run as `github-actions[bot]` from PR-controlled code | Malicious PR could rewrite `scripts/classify-pr.sh` to emit TRIVIAL, OR add `gh pr edit --add-label ai-approved` step → bypass entire gate | Split into `ci.yml` (`pull_request`, no labels) + `gate.yml` (`pull_request_target`, base-branch code, holds all label/merge-gating logic) |
| `gh` shell wrapper auths as `jonathan` (admin); admin in Rulesets bypass list | Claude agent with shell access could `gh pr review --approve` its own PR → bypass human gate | Threat model adds dedicated `claude-agent-{1..N}` users (no wheel/sudo/gh); ai-approved label-add allowlist restricts to `github-actions[bot]` only — even leaked jonathan creds can't shortcut |
| Force-push past stale APPROVED review | Old human approval survives force-push → bypass gate | `label-gate.yml` filters reviews by `commit_id == HEAD_SHA` — fresh approval required |
| Label-add allowlist relied on `sender.login` from labeled events only | Labels added between events not validated | `label-gate` re-walks PR timeline every run, validates each current label's last `labeled` actor |

### Fail-open defaults
| Caught | Why bad | Fix |
|---|---|---|
| Classifier rule table mixed package-name + path-prefix patterns (`linux-firmware` next to `etc/systemd/system/`) but `nix store diff-closures` emits package names only | Rule table was dead code for half the buckets | Split into 3 data sources (Source 1: diff-closures package delta, Source 2: walk etc-tree derivation, Source 3: git diff). Per-source rule tables. EXACT/PREFIX/SUFFIX matching specified explicitly |
| `boot.json` and `kernel-modules/` listed in `etcPaths.critical` | Verified empirically: those paths live under `/run`, not `/etc` → dead rules | Dropped from etcPaths; kernel/bootloader risk covered by Source 1 (`linux`, `systemd-boot`, `grub`, `bootspec` packages) |
| `default = MEDIUM` rule misclassified true no-op PRs (whitespace-only) as MEDIUM | Required AI review for derivation-identical no-ops | No-op short-circuit: all 3 diffs empty → TRIVIAL by definition; only fall back to MEDIUM when signal exists but no rule matches |
| `nixos-deploy.service` with `git reset --hard` + failed `switch` | Broken commit stays at HEAD; every deploy re-applies it | `/var/lib/nixos-deploy/{last-good,current-poison,poisoned.log}` latch; refuses to re-apply poisoned SHA until manual `rm /var/lib/nixos-deploy/current-poison` |
| `notify-send` from root (no DBUS_SESSION_BUS_ADDRESS) | Operator never sees deploy failure → spec's "rollback signal" was theatre | Flag-file pattern: root deploy writes `notify-{success,failure}` flags; user-bus path-watcher pair (one per flag, since `Path.PathExists` watches one path) surfaces via libnotify on jonathan's session bus |
| `Conflicts=self` on deploy unit | Reverses systemd's natural oneshot serialization (stops the running one instead of queuing) | Drop `Conflicts`; systemd oneshots already serialize |
| Rulesets bootstrap before workflow's first green run | Could lock out all merges to main, including the fix | Two-phase bootstrap (`evaluate` → `active`); explicit `[human-checkpoint]` gating activation |
| `${GITHUB_OUTPUT:-/dev/stdout}` fallback in classifier | Local test invocations would pollute markdown output | Drop fallback; only emit when `$GITHUB_OUTPUT` set |
| Matrix concurrency `vm-lane-${{ matrix.lane }}` as job-level group | GHA concurrency is mutex (not pool) → 3 lanes serialize repo-wide instead of running in parallel slots | Drop per-job concurrency; rely on `strategy.max-parallel: 3` + workflow-level `pr-cancel` |
| `polkit` rule for github-webhook to start deploy unit | Socket-activated handlers run without D-Bus session → polkit falls back to PID 1 socket → EACCES | Sudoers stanza scoped to exact command, handler invokes via `sudo` |

### Missing prereqs
| Caught | Where it was buried |
|---|---|
| `users.users.jonathan.linger = true` not currently set | Only in test scaffolding, not host config; first-boot deploy would have no user session to notify |
| `ANTHROPIC_API_KEY` missing from secrets list | Spec mentioned AI subagent but never named the credential |
| Sudoers stanza for jonathan to delete `/var/lib/nixos-deploy/notify-*` flag files | Implicitly relied on global `wheelNeedsPassword=false` (couples notify path to a setting that may tighten) |
| `actions-runner-ssh-key.age` for runner to clone private repo | Spec assumed runner could fetch flake inputs; default GHA-bot token has only `contents:read` |
| `gh-janitor-token.age` for stale-job cleanup cron | Janitor `gh run cancel` needed a token; not named |
| Pre-flight refuse on uncommitted/unpushed/stashed/untracked work in bare-repo bootstrap | Original draft would silently drop local work |
| Pre-flight build of origin/main + dirty-tree refuse in `/etc/nixos` bootstrap | Could strand host on broken commit / nuke diagnostic edits |
| Bootstrap snapshot step (`/etc/nixos.bak.<timestamp>`) before destructive ops | No recovery path if step 4/5 fails partway |

### Spec semantic / matching ambiguities
| Caught | Fix |
|---|---|
| Rule-matching semantics undefined (`linux` ⊂ `linux-firmware`?) | EXACT match for packages, PREFIX for etc paths, SUFFIX for `.age`. Unit-test cases cover boundary: `linux-firmware` exact-matches `linux-firmware` (CRITICAL) but does NOT substring-match `linux` |
| `EnvironmentFile` for ANTHROPIC_API_KEY | agenix decrypts to raw payload, NOT `KEY=VALUE`; .age file MUST be `ANTHROPIC_API_KEY=sk-ant-...` |
| GHA `permissions:` block | Default `${{ github.token }}` is `contents:read` on private repos; label-add silently 403s without `pull-requests:write, issues:write`. Permissions split: `ci.yml` read-only, `gate.yml` write |
| `label-gate.yml` workflow trigger types | `pull_request` doesn't re-fire on label changes by default; need `types: [labeled, unlabeled]` |
| Replay protection on webhook | `X-GitHub-Delivery` UUID dedup with 24h TTL — `seen` file pruned per-request |
| Slowloris hardening on webhook | `socket.settimeout(5)` + `MaxConnections=4` + `TimeoutStartSec=10s` (rate-limit alone only governs accept rate, not held-open connections) |
| Webhook listen on `127.0.0.1` only | Tailscale Funnel forwards to localhost; `0.0.0.0:9091` was needless attack surface |
| Webhook RateLimitBurst raised 5→10 | GH webhook retries 3x with exp backoff; burst=5 risked dropping retries |
| AI circuit-breaker per-PR scope | Global reset (any human approval anywhere) lets unrelated PR clear malicious PR's path |
| Per-host Attic public-key list | First-deploy chicken-and-egg; multi-host would have one host's pub-key fail equality check forever — list-membership instead |

### Misc cleanups
| Caught | Fix |
|---|---|
| `pkgs.shadow/bin/nologin` wrong path | Use `/run/current-system/sw/bin/nologin` |
| `cat <<'EOF'` heredoc preserves Nix indentation in known_hosts | Use `printf '%s\n'` |
| `gh pr diff --name-only` doesn't exist | Use `gh pr view --json files --jq '.files[].path'` |
| `contains(github.event.pull_request.changed_files, '...')` — `changed_files` is integer count | Use `dorny/paths-filter@v3` or `paths:` filter on workflow trigger (deferred — VM-graphical placeholder) |
| Implementation order `[auto]` vs `[human]` annotations | Autonomous implementer might blast through `[human-checkpoint]` step 12 (Rulesets activation) → marked explicitly with "MUST NOT proceed" |

---

## 2. Features skipped vs initial prompt

What you asked for vs what's in the worktree:

| Initial ask | Status | Notes |
|---|---|---|
| Production = `/etc/nixos`, auto-pulls main | Spec'd + implemented (B) | Not deployed (per "no deploy") |
| Repos/nixos-config = dev, worktree-driven | Spec'd + bootstrap script written (C.1) | Not run (destructive) |
| Worktree-only enforcement | Spec'd: bare-repo conversion | Bootstrap script ready; not run |
| advice-refine-loop on branch | Used (6+1 rounds) | Spec + impl both refined |
| VM tool for branch testing | Spec'd: 5-tier ladder (eval → build → vm-minimal → vm-graphical → vm-realapp) | vm-minimal = existing `dellan-vm.nix`; vm-graphical = placeholder; vm-realapp = deferred |
| Merge check (config valid) | Spec'd + classifier implemented | Tests pass; needs gate.yml deploy |
| User approval for serious changes | Spec'd: GitHub Rulesets + label-gate | Bootstrap script ready; not activated |
| AI review for small stuff | Spec'd: D.4 AI subagent | `ai-review.sh` is a placeholder shellout; subagent invocation not wired |
| Multiple agents in parallel VMs | Spec'd: 3 lanes, claude-agent-{1..N} users | claude-agent module written; users not created |
| GHA vs local CI/CD logic | Resolved: self-hosted GHA runner on dellan, free for private repo | Module written; runner not registered |
| VM ↔ userspace fidelity tradeoff | Spec'd: section E + tier table + documented gaps | Tier 4 placeholder; tier 5 explicitly deferred |

**Explicitly deferred (in spec out-of-scope):**
- Multi-host CI matrix beyond Linux (mac-mini darwin)
- Hydra-style build farm
- Custom approval UI
- Real-hardware test bed
- Migration of MCP server / dotfile repos to same workflow

**Implementation gaps inside scoped features:**
- VM-graphical tier (E.1) — workflow has placeholder; baseline diff harness not written
- AI-review subagent (D.3) — `gate.yml` calls `./scripts/ai-review.sh` which doesn't exist; falls through to "request-changes" verdict
- Circuit-breaker logic (3-consecutive-AI-merges, 24h-post-failure) — spec'd in D.4 prose, not implemented in any script
- Tamper-detection on `ai-approved-merges.jsonl` — `ci-state.nix` writes hourly snapshots but `classify-pr.sh` doesn't compare live vs snapshot
- `nixos-deploy.service` SSH credentials for `git fetch origin main` — module wires no credential; first deploy will poison-latch on auth failure unless bootstrap procedure adds a deploy key

---

## 3. Possible redundancies (belt + suspenders)

Areas where layered defenses may exceed actual threat:

| Layer | Possibly redundant given | Verdict |
|---|---|---|
| Per-PR circuit-breaker counter (3-consecutive AI-approved) | `pull_request_target` trust split + label-add allowlist | Probably keep; cheap and catches a different failure mode (slow erosion via repeated "trustworthy" small PRs) |
| Tamper-detection snapshots of `ai-approved-merges.jsonl` | Already runner-only-writeable, classifier ID pinned by SHA | Likely overkill — runner identity is the trust boundary; snapshots add ops burden without strong gain. Consider dropping unless you actively care about runner-compromise scenarios |
| `RateLimitIntervalSec` on socket + `socket.settimeout(5)` + `TimeoutStartSec=10s` + `MaxConnections=4` | All hardenings against the same class (held-open / slowloris) | Each catches different timing window. Keep all four — total cost is 4 lines of NixOS config |
| Bootstrap dirty-tree pre-flight in BOTH `bootstrap-bare-repo.sh` AND `bootstrap-deploy-target.sh` | They run sequentially | Keep — they protect different directories (`~/Repos/nixos-config` vs `/etc/nixos`); user might run only one |
| `Conflicts=` removed but oneshot still serial | Was misuse, not redundancy | Already fixed |
| Two separate path units (failure + success notify) | Could combine via `Path.PathChanged=` on parent dir | Spec rejected combining (false-fires on `last-good` writes). Keep split |
| Rulesets two-phase (`evaluate` → `active`) bootstrap | Step 12 `[human-checkpoint]` already gates activation | Belt + suspenders; the dry-run mode lets you see real evaluation results before committing. Keep |
| Sudoers + polkit considered for webhook → deploy | Was an alternative, not layered | Polkit dropped; sudoers wins |
| `inactive_text_alpha 0.55` + `bold tab font` + `text_composition_strategy 2.0` for kitty theming | (Different feature, but pattern same) | Each addresses different visual element; not redundant |

**Strongest redundancy candidate to remove:** ci-state snapshot timer + tamper-detection plumbing. The runner-can-write-its-own-state caveat is acknowledged in the threat model; layered protection adds complexity without changing the trust boundary.

---

## 4. What I tested and how

### Empirical verifications during spec rounds
| Claim | Verified by |
|---|---|
| `nix store diff-closures` exists, output format | `nix store diff-closures /nix/var/nix/profiles/system-31-link /run/current-system` — confirmed package-name-keyed lines like `unit-podman.service: ε → ∅`, `nerd-fonts-jetbrains-mono: ∅ → 3.4.0` |
| `attic-server` correct nixpkgs attribute (not `atticd`) | `nix eval -f '<nixpkgs>' attic-server.meta.description --raw` |
| `nvd` available | `nix eval -f '<nixpkgs>' nvd.meta.description --raw` |
| `tailscale funnel` works on dellan | `tailscale --version` v1.96.5; `tailscale funnel --help` |
| `/dev/kvm` available | `ls -l /dev/kvm` (mode 666) |
| `imagemagick compare` available | `which compare` |
| `linger` NOT currently in `hosts/dellan/default.nix` | grep'd `users.users.jonathan` block |
| `/etc/boot.json` doesn't exist | `ls /etc/boot.json` (file not found); bootspec lives at `/run/current-system/boot.json` |

### Tests during implementation
| Component | Test method | Result |
|---|---|---|
| Risk classifier (11 unit tests from spec D.2) | `bash scripts/risk-rules.test.sh` — runs `risk-rules-classify-only.sh` against canned inputs | 11/11 pass |
| Test cases | `linux-firmware` exact-match → CRITICAL; `util-linux` no-match → MEDIUM; `openssh` → HIGH; `unit-podman.service` add → MEDIUM; `pam.d/sshd` prefix → HIGH; `dbus-1/systemd/system/foo` NOT prefix → MEDIUM; all-empty → TRIVIAL; docs-only + empty closure → TRIVIAL; `.age` suffix → HIGH; `linux` → CRITICAL; multi-source → max wins | All pass |
| 7 NixOS modules | `nix-instantiate --parse modules/nixos/<name>.nix` | All 7 parse clean |
| 6 shell scripts | `nix run nixpkgs#shellcheck -- scripts/*.sh` | All clean (after fixing one SC2318 warning) |
| Existing VM gate | `nix eval --no-warn-dirty .#checks.x86_64-linux.dellan-vm.drvPath` | Green (existing test still resolves; new files don't break flake) |
| Branch state vs origin/main | `git log --oneline origin/main..HEAD` | 12 commits ahead, all on `feat/cicd-workflow` |

### What I did NOT test
| What | Why not |
|---|---|
| Full VM gate (`nix build .#checks.x86_64-linux.dellan-vm -L`) | New modules not imported into `hosts/dellan/default.nix`; would just rerun existing check. Did eval-only verification |
| `gate.yml` / `ci.yml` end-to-end | Requires self-hosted runner registered + Tailscale Funnel configured (both `[human]`) |
| `classify-pr.sh` against real PR | Requires runner + worktree; the unit tests cover the bucket logic in isolation |
| `nixos-deploy.service` with real `nixos-rebuild switch` | Would deploy to dellan; user said don't |
| Bootstrap scripts | Destructive on first run; user said don't deploy |
| Webhook handler with real POST | Requires Funnel + GitHub webhook; can be tested locally with `curl` after rebuild |
| Rulesets bootstrap | Requires PAT with `repo:admin` |

### How to verify the impl yourself before merging
```bash
cd ~/Repos/nixos-config-worktrees/cicd-workflow

# parse-check all modules
for f in modules/nixos/*.nix; do nix-instantiate --parse "$f" >/dev/null && echo "OK $f"; done

# shellcheck all new scripts
nix run nixpkgs#shellcheck -- scripts/*.sh .github/workflows/*.yml || true

# classifier tests
bash scripts/risk-rules.test.sh

# eval-check the existing VM gate (still passes)
nix eval --no-warn-dirty .#checks.x86_64-linux.dellan-vm.drvPath

# (optional) full VM gate, ~90s warm
nix build .#checks.x86_64-linux.dellan-vm -L
```

---

## 5. Setup instructions

The spec's implementation order has 17 steps; this is the operator-runbook version with concrete commands.

### Prerequisites (one-time, before any `[auto]` step)

1. **Review the spec.** `docs/specs/2026-05-04-cicd-driven-nixos-workflow.md`. Pay attention to:
   - Locked decisions table (top)
   - Threat model section (~line 654)
   - Implementation order (~line 760)

2. **Decide which scope to land first.** Recommended minimal first slice: A.1 + A.2 + A.3 (`ci.yml`) only. Defer B/D until the runner has actually built one PR successfully.

### `[human]` setup steps (in order)

#### Step 1: Self-hosted runner registration

```bash
# 1a. Get registration token from GitHub
#     https://github.com/jonathanmoregard/nixos-config/settings/actions/runners/new
#     copy the displayed token (starts with A...)

# 1b. Encrypt via agenix
cd /etc/nixos
echo -n "$TOKEN" | sudo -E nix run --extra-experimental-features 'nix-command flakes' \
  github:ryantm/agenix -- -e secrets/github-runner-token.age

# 1c. Add to secrets/secrets.nix allKeys list
#     edit, then git add -A

# 1d. Wire actions-runner module into hosts/dellan/default.nix:
#     imports = [ ../../modules/nixos/actions-runner.nix ];
#     services.actionsRunner = {
#       enable = true;
#       url = "https://github.com/jonathanmoregard/nixos-config";
#       tokenFile = config.age.secrets.github-runner-token.path;
#       sshKeyFile = config.age.secrets.actions-runner-ssh-key.path;
#     };

# 1e. Generate runner SSH key, register public part as a Deploy Key on GitHub
ssh-keygen -t ed25519 -f /tmp/runner-key -N ''
sudo -E nix run github:ryantm/agenix -- -e secrets/actions-runner-ssh-key.age \
  < /tmp/runner-key
# Copy /tmp/runner-key.pub to https://github.com/jonathanmoregard/nixos-config/settings/keys/new
shred -u /tmp/runner-key /tmp/runner-key.pub

# 1f. Run the gate, then switch
nix build .#checks.x86_64-linux.dellan-vm -L
sudo nixos-rebuild switch --flake /etc/nixos#dellan
```

#### Step 2: Attic cache

```bash
# 2a. Wire atticd module into hosts/dellan/default.nix:
#     imports = [ ../../modules/nixos/atticd.nix ];
#     services.atticCache.enable = true;

# 2b. Switch (gate first)
nix build .#checks.x86_64-linux.dellan-vm -L
sudo nixos-rebuild switch --flake /etc/nixos#dellan

# 2c. After first start, capture the public key and commit it
sudo cat /var/lib/atticd/server.pub
# add to flake.nix's pkgsLinux.config.nix.settings.trusted-public-keys
git add flake.nix && git commit -m 'feat: pin Attic public key'
```

#### Step 3: Bare repo + worktree directory

```bash
# DESTRUCTIVE on ~/Repos/nixos-config. Run pre-flight first:
cd /etc/nixos
git status --porcelain    # must be empty
git stash list            # must be empty
git for-each-ref refs/heads/    # ensure all local branches pushed

# Then run:
~/Repos/nixos-config-worktrees/cicd-workflow/scripts/bootstrap-bare-repo.sh
```

#### Step 4: Deploy target (`/etc/nixos` reclone)

```bash
# Snapshot first (in case you need to roll back step 3)
sudo cp -a /etc/nixos /etc/nixos.bak.$(date +%s)

# Run the bootstrap (pre-flights build origin/main + refuse on uncommitted edits)
sudo ~/Repos/nixos-config-worktrees/cicd-workflow/scripts/bootstrap-deploy-target.sh

# Verify /etc/nixos is now a real git checkout
ls -la /etc/nixos/.git
```

#### Step 5: Webhook ingress (Tailscale Funnel)

```bash
# 5a. Generate webhook secret
openssl rand -hex 32 > /tmp/webhook-secret
sudo -E nix run github:ryantm/agenix -- -e secrets/github-webhook-secret.age \
  < <(echo "WEBHOOK_SECRET=$(cat /tmp/webhook-secret)")
shred -u /tmp/webhook-secret

# 5b. Wire github-webhook + nixos-deploy modules into hosts/dellan/default.nix:
#     imports = [
#       ../../modules/nixos/github-webhook.nix
#       ../../modules/nixos/nixos-deploy.nix
#     ];
#     services.githubWebhook = {
#       enable = true;
#       secretFile = config.age.secrets.github-webhook-secret.path;
#     };
#     services.nixosDeploy.enable = true;

# 5c. Gate + switch
nix build .#checks.x86_64-linux.dellan-vm -L
sudo nixos-rebuild switch --flake /etc/nixos#dellan

# 5d. Expose via Tailscale Funnel
sudo tailscale funnel --bg 9091
sudo tailscale funnel status
# note the URL — looks like https://<machine>.<tailnet>.ts.net/

# 5e. Configure GitHub webhook
#     https://github.com/jonathanmoregard/nixos-config/settings/hooks/new
#     Payload URL:  <funnel URL>/webhook
#     Content type: application/json
#     Secret:       <the value you generated above>
#     Events:       just push
```

#### Step 6: Workflows + classifier

```bash
# 6a. Wire CI scaffolding via merging feat/cicd-workflow's relevant pieces:
git checkout main
git checkout feat/cicd-workflow -- .github/ scripts/classify-pr.sh \
  scripts/risk-rules.nix scripts/risk-rules-classify-only.sh \
  scripts/risk-rules.test.sh
git add -A && git commit -m 'feat: CI workflows + risk classifier'
git push origin main

# 6b. Open a test PR — runner should pick it up; classifier should label it
```

#### Step 7: `[human-checkpoint]` — wait for green run

```bash
# Wait until at least one PR run on main produces ALL of:
#   - eval (status check)
#   - build (status check)
#   - vm-minimal (status check)
#   - classify (status check)
#   - label-gate (status check)
# Verify via: gh api repos/jonathanmoregard/nixos-config/commits/main/check-runs
```

#### Step 8: Rulesets (after green run)

```bash
# 8a. Get a PAT with repo:admin scope
#     https://github.com/settings/tokens/new
#     scopes: repo:admin
#     copy as $GH_TOKEN

# 8b. First in evaluate (dry-run) mode
GH_TOKEN=$TOKEN ~/Repos/.../scripts/bootstrap-rulesets.sh evaluate

# 8c. Review the dry-run results in GitHub UI
#     https://github.com/jonathanmoregard/nixos-config/rulesets

# 8d. Activate
GH_TOKEN=$TOKEN ~/Repos/.../scripts/bootstrap-rulesets.sh active

# 8e. Commit the state file
git add scripts/rulesets-state.json && git commit -m 'feat: pin Rulesets state'
```

### Testing end-to-end

```bash
# Open a TRIVIAL PR (e.g. README typo). Expect:
#   - ci.yml runs, all checks green
#   - gate.yml runs, classify posts "TRIVIAL" comment + applies risk:trivial label
#   - label-gate passes
#   - PR auto-mergeable

# Open a HIGH PR (e.g. modify modules/nixos/desktop.nix). Expect:
#   - ci.yml + gate.yml run
#   - label = risk:high
#   - label-gate FAILS until you push a manual approval
```

### Rollback

```bash
# Bad deploy reached dellan?
sudo nixos-rebuild switch --rollback

# Bad merge reached main?
gh api repos/jonathanmoregard/nixos-config/branches/main/protection \
  -X PATCH ...   # temporarily disable Rulesets
git revert <bad commit>
git push origin main

# Bare-repo conversion went wrong?
cd ~/Repos
mv nixos-config nixos-config.bare-failed
ln -s /etc/nixos.bak.<timestamp> nixos-config
# (only works if you took the snapshot from step 4)
```
