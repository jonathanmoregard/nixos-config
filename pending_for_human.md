## 2026-08-09: Google Forms scopes need a browser OAuth re-consent

**Why blocked**: Granting a Google API scope requires an interactive consent
screen in a browser. The stored token at
`/home/jonathan/.google_workspace_mcp/credentials/jonathan@klaffat.com.json`
was minted with docs + drive scopes only, so every Forms tool will fail with
an insufficient-scope error until you re-consent. Everything the machine can
do declaratively is done; this is the one click-through left.

**Steps for human**:
1. Wait for the PR adding `home/gdocs-review-mcp.nix` to merge and auto-deploy,
   then confirm the wrapper is on PATH:
   `command -v gdocs-review-mcp`  → expect `/etc/profiles/per-user/jonathan/bin/gdocs-review-mcp`
2. Make sure the Google Cloud project behind the OAuth client has the Forms API
   enabled, otherwise consent succeeds but calls 403:
   https://console.cloud.google.com/apis/library/forms.googleapis.com
3. Force a fresh consent by removing the stale token (back it up first, so a
   failed consent is recoverable):
   ```
   cp /home/jonathan/.google_workspace_mcp/credentials/jonathan@klaffat.com.json \
      /home/jonathan/.google_workspace_mcp/credentials/jonathan@klaffat.com.json.bak
   rm /home/jonathan/.google_workspace_mcp/credentials/jonathan@klaffat.com.json
   ```
4. Restart Claude Code so it respawns the `gdocs-review` MCP through the new
   wrapper, then call the `start_google_auth` tool (or any Forms tool — the
   server returns an auth URL when it has no valid token). Open the URL it
   prints, sign in as `jonathan@klaffat.com`, and approve the consent screen.
   Google will warn the app is unverified — that is expected for a personal
   OAuth client; choose "Advanced" → "Go to … (unsafe)".

**Verify it worked**:
```
python3 -c "import json;print(*json.load(open('/home/jonathan/.google_workspace_mcp/credentials/jonathan@klaffat.com.json'))['scopes'],sep='\n')" | grep forms
```
Expect at least `https://www.googleapis.com/auth/forms.body`. Then ask Claude
Code to list the tools on the `gdocs-review` server — the six `gforms` tools
should be present and a Forms read call should return data rather than a
403/insufficient-scope error. If it still 403s, redo step 3; a partially
approved consent screen leaves the old scope set in place.

**Everything else done**: agenix secrets `google-oauth-client-id` /
`google-oauth-client-secret` created and rekeyed for dellan; wrapper
`home/gdocs-review-mcp.nix` exports both plus `USER_GOOGLE_EMAIL`,
`WORKSPACE_MCP_CREDENTIALS_DIR` and `SSL_CERT_FILE` and runs the fork with
`--tools docs docs_preview forms drive`; module imported from
`home/jonathan-linux.nix`; secrets declared in `hosts/dellan/default.nix`;
`tests/base.nix` asserts the wrapper's exports, argv, no-secret-in-store
property, and that both secrets reach system activation.

---

# Install — minimal version

One command + a handful of paste-and-clicks. ~15 minutes start to finish.

## Pre-reqs (one-time, you must already have)

- `dellan` is the host being deployed to (current machine)
- `gh` CLI installed and authed as `jonathan` (`gh auth status` should show success)
- `feat/cicd-workflow` branch checked out somewhere — typically a worktree at `$HOME/Repos/nixos-config-worktrees/cicd-workflow/`

## Run the installer

```bash
cd $HOME/Repos/nixos-config-worktrees/cicd-workflow
./scripts/install.sh
```

The script walks 9 phases. Each pause is one of: paste a token, click in GitHub UI, press ENTER. Concrete URLs printed at every step. Idempotent — re-runnable on partial failure.

What you'll do during the run:

| Phase | Your action | Time |
|---|---|---|
| 1 | Paste runner SSH pub-key into `<repo>/settings/keys/new` (Allow write) | ~30s |
| 2 | Paste runner registration token from `<repo>/settings/actions/runners/new` | ~30s |
| 3 | Paste a fine-grained PAT from `https://github.com/settings/tokens/new` (scope: `repo`) | ~1min |
| 4 | (script encrypts everything via agenix; no input) | — |
| 5 | (script runs VM gate + `nixos-rebuild switch`; ~3min) | wait |
| 6 | (script runs bare-repo + deploy-target bootstrap; pre-flights yell if dirty) | ~30s |
| 7 | Paste Tailscale Funnel URL into `<repo>/settings/hooks/new`; webhook secret pre-printed | ~1min |
| 8 | Eyeball the dry-run rulesets at `<repo>/rulesets`; press ENTER to activate | ~1min |
| 9 | (optional) open a no-op test PR; verify CI runs end-to-end | ~2min |

## After the install

Once `install.sh` finishes, the system is:

- Self-hosted GHA runner registered + active
- Attic cache on `localhost:8080`
- `nixos-deploy.service` watching for webhook → push:main → `nixos-rebuild switch`
- Tailscale Funnel exposing `:9091/webhook` to GitHub
- GitHub Rulesets active: PR required, label-gate enforced, no force-push, no admin direct-push
- 4 secrets encrypted in `secrets/`

## Try-out + merge

Branch `feat/cicd-workflow` is what's installed. Try it for a day or two by opening real PRs. When happy:

```bash
cd /etc/nixos
git fetch origin
git checkout main
git merge origin/main
git merge feat/cicd-workflow --no-ff
nix build .#checks.x86_64-linux.dellan-vm -L
git push origin main
```

`feat/cicd-workflow` is 17 commits ahead, 7 commits behind on `tests/dellan-vm.nix` (autodoro/keyring/kitty test work). Different files; no conflicts expected. Use `--no-ff` to preserve the round-by-round refinement history.

## Recovery

| Scenario | Recovery |
|---|---|
| Install fails partway | Re-run `./scripts/install.sh` — it skips phases that already succeeded |
| Bad deploy reached dellan | `sudo nixos-rebuild switch --rollback` |
| Bad merge reached main | Disable Rulesets via UI temporarily, `git revert <bad>; git push origin main` |
| Bare-repo bootstrap went wrong | `mv /etc/nixos.bak.<timestamp> /etc/nixos` (snapshot taken pre-conversion) |
| Deploy poison-latch | `sudo rm /var/lib/nixos-deploy/current-poison && sudo systemctl reset-failed nixos-deploy` |

## Known gaps still TODO (low priority)

- VM-graphical tier (E.1) — placeholder in `ci.yml`
- VM-realapp tier (E.2) — out of scope
- comin alternative to webhook→deploy (research recommendation; not adopted)
- microvm.nix runner isolation (research recommendation; not implemented)
- Two-App split (label-bot vs merge-bot) — single App used currently
- Janitor cron for stale GHA jobs — `gh-janitor-token.age` declared but no cron yet

None block the core "PR → classifier → label → merge → auto-deploy" flow.
