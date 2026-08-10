---
name: nixos-agenix-secret
description: Use when creating or editing an agenix-managed NixOS secret. Triggers on "create a secret", "add API key", "agenix -e", "encrypt with agenix", "nixos secret", "store credential", "setup agenix", "add agenix secrets", "add secrets", "add environment variable to nixos", and key-assignment shapes ("FOO_CLIENT_ID=...", "FOO_API_KEY=...").
---

# NixOS Agenix Secret

This repo uses **agenix-rekey** (oddlama/agenix-rekey), migrated from legacy `agenix` (ryantm/agenix) in commit `e451e78`. `secrets/secrets.nix` was **deleted**; recipients are derived from the flake's `nixosConfigurations` + `age.rekey.masterIdentities` (see `modules/nixos/agenix-rekey-common.nix`).

**Legacy `agenix -e <name>.age` on PATH does NOT work post-migration** — it fails with `path 'secrets/secrets.nix' does not exist` and must not be used. Ignore older tutorials and the comments still in `flake.nix` / `hosts/dellan/default.nix` that reference it; they're stale.

Layout:
- **Source `.age`** in `secrets/` — encrypted to the master pubkey only.
- **Per-host rekeyed copies** in `secrets/rekeyed/<host>/<hash>-<name>.age` — regenerated from source by `rekey`. Tracked in git (`storageMode = "local"`).
- **Host configs** declare each secret with `age.secrets.<name>.rekeyFile = ../../secrets/<name>.age` (NOT `.file`).

## Add a new secret (fast path)

`add-secret <name>` is the canonical way to add a secret. It's on dellan's PATH (via `hosts/dellan/default.nix` → `environment.systemPackages`) and collapses the whole flow — encrypt, insert into the host file, rekey, commit on the current feature branch, push, open PR — into one step. The human still has to click **Merge** in the GitHub UI (deliberate gesture per `nixos-deploy.service`).

**Must run from a worktree root** (`~/Repos/nixos-config-worktrees/<slug>`). Refuses otherwise — see the footgun list.

```bash
# 1. Get onto a feature branch (the tool refuses on main).
cd ~/Repos/nixos-config
git worktree add ~/Repos/nixos-config-worktrees/<slug> -b feat/<slug> main
cd ~/Repos/nixos-config-worktrees/<slug>

# 2a. Preferred: pipe the value in — no flag needed. The tool
#     auto-detects piped stdin and reads it directly.
pass show anthropic-api-key | add-secret anthropic-api-key
wl-paste                    | add-secret openai-api-key
echo -n "$API_KEY"          | add-secret gemini-api-key
add-secret my-key <<< "$val"

# 2b. Interactive: no pipe → prompts for the value, then a re-entry
#     confirm.
add-secret my-new-key

# 2c. Explicit source flags (override auto-detect):
add-secret my-new-key --from-clipboard    # wl-paste on Wayland
add-secret my-new-key --from-stdin        # even if stdin is a TTY
add-secret my-new-key --prompt            # even if stdin is piped
```

Auto-detect logs `add-secret: reading value from stdin (piped)` to stderr when it fires, so it's not silent magic. If your pipe source produces nothing (empty), the tool refuses with `value is empty; aborting` rather than encrypting a hollow secret.

Flags: `--host <host>` (default `dellan`), `--owner <user>` (`jonathan`), `--group <group>` (`users`), `--mode <mode>` (`0400`).

What happens:
1. Refuses if `age.secrets.<name>` already exists in `hosts/<host>/default.nix` (points you at the manual edit-view command for editing existing secrets).
2. Reads the value; if it's a single-line `KEY=VALUE`, strips the `KEY=` prefix (agenix consumers read raw via `$(< file)` and export the env var themselves — storing `KEY=` would double-wrap). Logs when it strips.
3. Encrypts to `secrets/<name>.age` with `age -r <master-pubkey>` (pubkey pulled from `modules/nixos/agenix-rekey-common.nix`).
4. Inserts the `age.secrets.<name> = { … };` block above the `# add-secret:insert-here` marker in `hosts/<host>/default.nix`.
5. Runs `nix eval .#nixosConfigurations.<host>.config.age.secrets.<name>.rekeyFile` as a sanity check; reverts everything on failure.
6. Runs `nix run .#agenix-rekey.x86_64-linux.rekey`.
7. `git add -A && git commit -m "secret: add <name>"` with the `Pre-push checklist:` trailer.
8. `git push -u origin HEAD` and `gh pr create`; prints the PR URL.

Then click **Merge** in the GitHub UI — the `nixos-deploy.service` webhook picks up the merge and rolls the secret onto dellan automatically.

**What it does NOT do:** create the worktree (do that yourself first); wire the secret into any consumer (that's a follow-up commit, deliberately kept separate); bypass the merge gate.

Automated coverage: `nix build .#checks.x86_64-linux.add-secret-smoke -L` exercises name validation, worktree preflight, dup-refuse, happy-path insertion, custom owner/group/mode, and KEY=VALUE stripping. Runtime paths that need real network / nix eval / gh (nix eval sanity check, rekey, gh pr create) are covered by the manual test that runs before the PR merges — not the smoke check.

## Edit an existing secret (interactive)

From the worktree **root** (NOT from `secrets/` — the script refuses with "Please execute this script from your flake's root directory."):

```bash
EDITOR=nano nix run .#agenix-rekey.x86_64-linux.edit-view -- edit secrets/<name>.age
```

**The literal `edit` subcommand after `--` is required.** Without it, the script silently defaults to `view` (read-only) and the editor never opens. Source: `apps/edit-view.nix` in oddlama/agenix-rekey dispatches on the first positional arg (`edit` | `view`); the `--help` output even self-describes as "View age secret files…" because view is the fallback.

After editing, regenerate per-host ciphertext (non-interactive, no editor):

```bash
nix run .#agenix-rekey.x86_64-linux.rekey
```

Skipping this does not corrupt anything — agenix-rekey runs an eval-time check (in `nix/output-derivation.nix`) and the next `nixos-rebuild` will refuse to proceed with a message pointing you back to `rekey`. But for `storageMode = "local"`, the regenerated per-host ciphertext under `secrets/rekeyed/<host>/` must be committed for the deploy to find it.

Stage:
```bash
git add -A
```

## Add a new secret (manual fallback)

Use only if `add-secret` is unavailable or the invariants it enforces don't apply (e.g. non-`dellan` host that hasn't wired the wrapper in; deliberately declaring a secret without a value; special file mode / owner combinations the wrapper's flags don't cover).

1. Declare it in the consuming host file (e.g. `hosts/dellan/default.nix`) — agenix-rekey discovers secrets via `nixosConfigurations.<host>.config.age.secrets`, so `edit-view` won't recognise an undeclared name:
   ```nix
   age.secrets.<name> = {
     rekeyFile = ../../secrets/<name>.age;
     owner = "jonathan"; group = "users"; mode = "0400";
   };
   ```

2. Create the source `.age` with the same interactive command as for editing (it creates the file if absent):
   ```bash
   EDITOR=nano nix run .#agenix-rekey.x86_64-linux.edit-view -- edit secrets/<name>.age
   ```

3. `rekey` + `git add -A` as above.

## File content

Raw value only — no `KEY=VALUE` wrapping. Consumers read via `$(< /run/agenix/<name>)` and export themselves. `EnvironmentFile=` and `source` don't work against raw files; wrap with `pkgs.writeShellApplication` instead.

## Other agenix-rekey commands

All at `nix run .#agenix-rekey.x86_64-linux.<cmd>`:

| Command | Interactive? | Use |
|---------|--------------|-----|
| `edit-view -- edit <file>` | yes (opens `$EDITOR`) | Create/edit a source `.age` |
| `edit-view -- view <file>` | yes (opens pager) | Read-only view of a source `.age` |
| `rekey` | no | Regenerate per-host copies after edit/add |
| `generate` | no | Bootstrap missing per-host copies |
| `update-masterkeys` | no | Bulk re-encrypt sources to a new master identity |

## Footgun summary

- Running `add-secret` from anywhere but a worktree root refuses — this is intentional (untracked host-file edits + `.age` writes into `/etc/nixos` would be overwritten on next auto-deploy).
- `add-secret` also refuses on `main` — always be on a feature branch.
- The `# add-secret:insert-here` marker in `hosts/<host>/default.nix` is load-bearing — do not delete it; the wrapper refuses to insert without it.
- Without `edit`/`view` subcommand → silent view mode, no editor opens.
- From `secrets/` dir → "execute from flake root" error.
- `$EDITOR` unset → falls back unhelpfully; set it explicitly.
- Secret not declared in any host's `age.secrets` → `edit-view` doesn't see it.
- `agenix -e <file>.age` from PATH → broken (legacy CLI; `secrets.nix` missing).
