---
status: proposed
category: feature
subcategory: secrets
date: 2026-05-05
source: advice-refine-loop
---

## ANTHROPIC_API_KEY missing on dellan — wire via agenix

`home/claude-services.nix` declares `claude-cl-sync.service` (every 6h, vets container-captured CL-v2 observations). The wrapper at `~/.claude/dev-container/bin/claude-cl-sync` reads `ANTHROPIC_API_KEY` from env. Today's runs fail with:

```
2026-04-28 09:15:53,394 claude-cl-sync ERROR scanner self-test FAILED:
honeypot probe returned ok=False (honeypot:honeypot_unavailable:
conversation_history_leak:unavailable:no-anthropic-api-key)
```

The MCP wrapper at `modules/nixos/research-agent.nix` *also* reads the key (line 15: `ANTHROPIC_API_KEY=$(cat ${secretPath})`), referencing `config.age.secrets.anthropic-api-key.path` — but the `.age` file isn't encrypted yet, so dellan rebuild fails with `error: Path 'secrets/anthropic-api-key.age' does not exist in Git repository "/etc/nixos"`.

### Status of agenix wiring

Already in place:
- `flake.nix` imports `agenix.nixosModules.default` for both vm + dellan.
- `secrets/secrets.nix` lists `jonathan`, `vm`, `dellan` host pubkeys (dellan added 2026-04-28).

NOT in place:
- `secrets/anthropic-api-key.age` doesn't exist.
- `secrets/secrets.nix` doesn't list `anthropic-api-key.age` in its publicKeys mapping.
- No `age.secrets.anthropic-api-key` declaration in any host config (the reference in `modules/nixos/research-agent.nix` is a forward reference that will fail until declared).
- `home/claude-services.nix` has `Environment=PYTHONDONTWRITEBYTECODE=1` but no `EnvironmentFile=` for the API key.

### Fix (one-time bootstrap, must be run interactively for the editor)

```bash
cd /home/jonathan/Repos/nixos-config/secrets

# 1. Edit secrets.nix to register the new file.
$EDITOR secrets.nix
# Add inside the existing `let ... in { ... }` block:
#   "anthropic-api-key.age".publicKeys = allKeys;

# 2. Encrypt the key. agenix opens $EDITOR with a tmpfile; paste the
#    contents (env-format because consumed via systemd EnvironmentFile)
#    and save:
#      ANTHROPIC_API_KEY=sk-ant-...
agenix -e anthropic-api-key.age

# 3. Commit + push the encrypted file. The .age file is safe to commit
#    (only allKeys can decrypt).
git add secrets/anthropic-api-key.age secrets/secrets.nix
git commit -m "secrets: add anthropic-api-key.age (cl-sync + research-agent)"
git push
```

### Wire into NixOS config (`hosts/dellan/default.nix`)

```nix
age.secrets.anthropic-api-key = {
  file = ../../secrets/anthropic-api-key.age;
  owner = "jonathan";
  group = "users";
  mode = "0400";
};
```

### Wire into systemd service (`home/claude-services.nix`, claude-cl-sync block)

```nix
systemd.user.services.claude-cl-sync = {
  ...
  Service = {
    ...
    EnvironmentFile = "/run/agenix/anthropic-api-key";
    Environment = "PYTHONDONTWRITEBYTECODE=1";
    ...
  };
};
```

(home-manager systemd user units need the agenix path readable by the
user — `mode = "0400"` + `owner = "jonathan"` covers that. agenix on
NixOS exposes secrets at `/run/agenix/<name>`; verify the exact path
on dellan post-rebuild via `ls -la /run/agenix/`.)

### Verify

```bash
sudo nixos-rebuild switch --flake /etc/nixos#dellan
ls -la /run/agenix/anthropic-api-key  # 0400 jonathan:users
systemctl --user start claude-cl-sync.service
sleep 8
systemctl --user is-active claude-cl-sync.service
journalctl --user -u claude-cl-sync.service -n 5 --no-pager
# expect: scanner self-test PASS (no honeypot:no-anthropic-api-key error)
```

### Notes
- Same `.age` file works for `research-agent.nix` (already references
  `config.age.secrets.anthropic-api-key.path`).
- API key currently NOT in any captured rsync from Mint — must be
  obtained fresh from https://console.anthropic.com/settings/keys.
- Once added, `claude-sandbox-proxy.service` is unaffected (doesn't
  need the key); `gh-token.service` already works.
