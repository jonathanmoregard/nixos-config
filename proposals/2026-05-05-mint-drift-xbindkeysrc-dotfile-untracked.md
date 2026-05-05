---
status: proposed
category: drift
subcategory: dotfile
date: 2026-05-05
source: mint-drift-agent
---

## ~/.xbindkeysrc key bindings untracked — xbindkeys starts but has no rules

`home/cinnamon.nix` declares the `xbindkeys` autostart entry so the daemon launches on login, but `~/.xbindkeysrc` — the file containing the actual key-binding rules — has no `home.file` declaration on either host. On a fresh install xbindkeys runs with an empty config and all bindings are silently lost.

Captured live `~/.xbindkeysrc` (Mint host, 2026-05-05):

```text
"~/.claude/tools/ghostty-mcp/ghostty-cycle.sh next"
  Control+Next

"~/.claude/tools/ghostty-mcp/ghostty-cycle.sh prev"
  Control+Prior
```

**STALENESS WARNING.** Both bindings invoke a Ghostty-specific cycle helper. Dellan has migrated from Ghostty to Kitty (see `home/kitty.nix`). Restoring these bindings verbatim leaves them targeting tooling under `~/.claude/tools/ghostty-mcp/` that will not exist on dellan. Two paths:

### Option A — port to kitty equivalent (recommended)

Kitty has built-in window cycling. Replace the bindings to call kitty's remote-control protocol (already enabled — see `home/kitty.nix` `listen_on unix:/tmp/kitty.sock`).

```nix
# home/cinnamon.nix
home.file.".xbindkeysrc".text = ''
  "kitty @ --to unix:/tmp/kitty.sock focus-window --match recent:0"
    Control+Next

  "kitty @ --to unix:/tmp/kitty.sock focus-window --match recent:1"
    Control+Prior
'';
```

### Option B — keep verbatim with note (preserves intent for review)

```nix
# home/cinnamon.nix
home.file.".xbindkeysrc".text = ''
  # TODO(2026-05-05): targets ghostty-mcp tooling that's been removed
  # post Ghostty→Kitty migration. Repoint or delete bindings.
  "~/.claude/tools/ghostty-mcp/ghostty-cycle.sh next"
    Control+Next

  "~/.claude/tools/ghostty-mcp/ghostty-cycle.sh prev"
    Control+Prior
'';
```

### Verify

After rebuild + login: `pgrep xbindkeys` returns a PID, and `xbindkeys -k` echoes the configured rules. Test by pressing `Control+Page Down` / `Control+Page Up`.
