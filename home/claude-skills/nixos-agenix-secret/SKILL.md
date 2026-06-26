---
name: nixos-agenix-secret
description: Use when creating or editing an agenix-managed NixOS secret. Triggers on "create a secret", "add API key", "agenix -e", "encrypt with agenix", "nixos secret", "store credential".
---

# NixOS Agenix Secret

This repo uses **agenix-rekey** (oddlama/agenix-rekey), migrated from legacy `agenix` (ryantm/agenix) in commit `e451e78`. `secrets/secrets.nix` was **deleted**; recipients are derived from the flake's `nixosConfigurations` + `age.rekey.masterIdentities` (see `modules/nixos/agenix-rekey-common.nix`).

**Legacy `agenix -e <name>.age` on PATH does NOT work post-migration** — it fails with `path 'secrets/secrets.nix' does not exist` and must not be used. Ignore older tutorials and the comments still in `flake.nix` / `hosts/dellan/default.nix` that reference it; they're stale.

Layout:
- **Source `.age`** in `secrets/` — encrypted to the master pubkey only.
- **Per-host rekeyed copies** in `secrets/rekeyed/<host>/<hash>-<name>.age` — regenerated from source by `rekey`. Tracked in git (`storageMode = "local"`).
- **Host configs** declare each secret with `age.secrets.<name>.rekeyFile = ../../secrets/<name>.age` (NOT `.file`).

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

## Add a new secret

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

- Without `edit`/`view` subcommand → silent view mode, no editor opens.
- From `secrets/` dir → "execute from flake root" error.
- `$EDITOR` unset → falls back unhelpfully; set it explicitly.
- Secret not declared in any host's `age.secrets` → `edit-view` doesn't see it.
- `agenix -e <file>.age` from PATH → broken (legacy CLI; `secrets.nix` missing).
