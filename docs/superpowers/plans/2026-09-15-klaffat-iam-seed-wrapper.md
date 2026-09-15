# Klaffat IAM Seed Wrapper Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provide one password-gated command that runs Klaffat's reviewed IAM seed with root-only AWS credentials and no credential handling by the caller.

**Architecture:** Extend the existing `klaffat-infra` NixOS module with a narrow `klaffat-iam-seed` wrapper. Reuse its root-only mirror, authenticated fetch, archive verification, agenix secrets, sudo policy, and cleanup pattern; execute only the reviewed seed entry point from remote `main`.

**Tech Stack:** NixOS modules, `pkgs.writeShellApplication`, Bash, Git archive, agenix, AWS CLI v2, NixOS VM tests.

---

### Task 1: Specify wrapper behavior in the VM lane

**Files:**
- Modify: `tests/klaffat-infra.nix`

- [ ] **Step 1: Add the failing behavioral assertions**

Extend the existing wrapper list and non-root/sudo checks with
`klaffat-iam-seed`. Add a reviewed-origin fixture:

```bash
#!/usr/bin/env bash
set -euo pipefail
command -v aws >/dev/null
printf 'seed-mode=%s\n' "${1-dry-run}"
printf 'aws-creds=%s/%s\n' \
  "${AWS_ACCESS_KEY_ID:+set}" "${AWS_SECRET_ACCESS_KEY:+set}"
case "${1-}" in
  --verify) exit 23 ;;
esac
```

Create minimal `deploy/iam/bootstrap/*.json` and
`deploy/iam/runtime/*.json` fixture files, commit them to the lane's remote,
then assert:

```python
rc, out = run("${bin}/klaffat-iam-seed")
assert rc == 0 and "seed-mode=dry-run" in out
assert "aws-creds=set/set" in out
assert "TEST-aws-access-key-id" not in out
assert "TEST-aws-secret-access-key" not in out

rc, out = run("${bin}/klaffat-iam-seed --apply")
assert rc == 0 and "seed-mode=--apply" in out

rc, out = run("${bin}/klaffat-iam-seed --verify")
assert rc == 23 and "seed-mode=--verify" in out
```

Also assert invalid argument/arity exits 2 before origin access, extracted
script provenance names remote `main`, non-root invocation exits 1, both sudo
path spellings require a password, rendered source never addresses
`/home/jonathan`, and no `iam-seed-*` extraction directory survives.

- [ ] **Step 2: Build the lane and verify RED**

Run:

```bash
nix build --no-link --rebuild .#checks.x86_64-linux.vm-klaffat-infra -L
```

Expected: FAIL because `/run/current-system/sw/bin/klaffat-iam-seed` does not
exist.

- [ ] **Step 3: Commit the red test**

```bash
git add tests/klaffat-infra.nix
git commit -m "test(klaffat): require safe IAM seed wrapper"
```

### Task 2: Add minimal root-only wrapper

**Files:**
- Modify: `modules/nixos/klaffat-infra.nix`
- Test: `tests/klaffat-infra.nix`

- [ ] **Step 1: Implement exact command interface**

Add `klaffat-iam-seed = pkgs.writeShellApplication` with runtime inputs
`awscli2`, `git`, `jq`, `coreutils`, `gnutar`, and `gawk`. Use
`rootOnlyPreamble` and `mirrorLib`. Accept exactly zero arguments,
`--apply`, or `--verify`; all other forms print
`usage: sudo klaffat-iam-seed [--apply|--verify]` and exit 2 before fetch.

- [ ] **Step 2: Extract and verify reviewed source**

After `mirror_sync`, resolve `mirror_main_tip`, print its provenance, and
archive only:

```text
deploy/iam
deploy/scripts/seed-aws-ci-identities.sh
```

into `${stateDir}/iam-seed-XXXXXXXX`. Refuse non-regular Git entries, archive
errors, hash differences caused by attributes, missing IAM directory, or
missing seed script. Remove extraction with an EXIT trap.

- [ ] **Step 3: Bind secrets only inside wrapper process and execute**

Require readable agenix files for `klaffat-aws-access-key-id` and
`klaffat-aws-secret-access-key`, then set and export only:

```bash
AWS_ACCESS_KEY_ID="$(< access-key-path)"
AWS_SECRET_ACCESS_KEY="$(< secret-key-path)"
AWS_DEFAULT_REGION="eu-north-1"
```

Run `${pkgs.bash}/bin/bash "$work/deploy/scripts/seed-aws-ci-identities.sh" "$@"`,
capture status, and return it after cleanup.

- [ ] **Step 4: Wire install and password gate**

Add both store and `/run/current-system/sw/bin/klaffat-iam-seed` spellings to
`sudoCommands`, add wrapper to `environment.systemPackages`, and update module
comments from three wrappers to four.

- [ ] **Step 5: Run cheap checks and verify GREEN**

Run:

```bash
git add modules/nixos/klaffat-infra.nix tests/klaffat-infra.nix
nix eval --no-warn-dirty .#checks.x86_64-linux.vm-klaffat-infra.drvPath
nix build --no-link --rebuild .#checks.x86_64-linux.vm-klaffat-infra -L
```

Expected: eval succeeds; VM lane passes with wrapper mode forwarding, secret
non-disclosure, provenance, cleanup, and sudo assertions green.

### Task 3: Interactive smoke and delivery

**Files:**
- Modify: `docs/superpowers/plans/2026-09-15-klaffat-iam-seed-wrapper.md`

- [ ] **Step 1: Boot feature VM and exercise user-facing command**

Run `nix run .#feature-vm`. Over SSH, invoke
`runuser -u jonathan -- /run/current-system/sw/bin/klaffat-iam-seed` and verify
root-only refusal, then invoke as root against the VM fixture origin and verify
dry-run output, credential presence markers, reviewed revision, and no fixture
credential value. Stop VM cleanly.

- [ ] **Step 2: Review and rebase**

Run security closeout via `advice-refine-test-loop`; fix findings test-first.
Then run:

```bash
git fetch origin main
git rebase origin/main
```

Re-run eval, `vm-klaffat-infra`, and interactive smoke after any changed
rebase result.

- [ ] **Step 3: Commit implementation with gate evidence**

Commit with risky pre-push checklist naming `vm-klaffat-infra`, interactive
smoke evidence, reviewer verdict, `writeShellApplication`/branching markers,
and `feature-vm.nix modified: no`.

- [ ] **Step 4: Push and open PR**

Push `feat/klaffat-iam-seed`, open PR against `main`, include exact RED/GREEN
and interactive-smoke evidence, then monitor required CI checks. Founder merges
through GitHub UI.
