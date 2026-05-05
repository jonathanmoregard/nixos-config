---
status: proposed
category: drift
subcategory: docs
date: 2026-05-05
source: advice-refine-loop
---

## CLAUDE.md documents `home/claude-symlinks.nix` that doesn't exist

CLAUDE.md describes a "cross-repo bridge" mechanism where `~/.claude/symlinks/` is a Nix-store derivation linking nixos-config paths into `~/.claude/` for hooks and scripts that reference them by relative path:

> `~/.claude/symlinks/` bridges the two. All `.claude` references to
> nixos-config code go through it, never absolute `/etc/nixos/...`.
> Built as a Nix-store derivation → read-only dir, contents = exactly
> what's declared:
>
> ```nix
> # home/claude-symlinks.nix
> home.file."claude/symlinks".source = pkgs.runCommand "claude-symlinks" {} ''
>   mkdir -p $out && ln -s /etc/nixos/<path> $out/<name>
> '';
> ```

Reality on dellan (2026-05-05):

```
$ ls -la ~/.claude/symlinks
ls: cannot access '/home/jonathan/.claude/symlinks': No such file or directory

$ find /home/jonathan/Repos/nixos-config/home -name 'claude-symlinks*'
(no results)
```

The module doesn't exist. Nothing under `~/.claude/` currently references `~/.claude/symlinks/...` (`grep -r 'symlinks/' ~/.claude --include='*.py' --include='*.sh' --include='*.json' --include='*.md'` returns 0 hits). The doc is aspirational — describes a plan never implemented.

### Two options

**Option A — Build the module as documented.** Useful if MCP servers / hooks / classifiers in nixos-config need stable user-readable paths from `~/.claude`. Concrete shape:

```nix
# home/claude-symlinks.nix
{ pkgs, ... }:
{
  home.file."claude/symlinks".source = pkgs.runCommand "claude-symlinks" {} ''
    mkdir -p $out
    # Add one ln -s per nixos-config path that ~/.claude wants to reach.
    # Examples (replace with actual targets):
    # ln -s /etc/nixos/scripts/mint-drift-agent.sh $out/mint-drift-agent
    # ln -s /etc/nixos/modules/nixos/research-agent.nix $out/research-agent.nix
  '';
}
```

Then import in `home/jonathan-linux.nix` `imports = [ ... ./claude-symlinks.nix ];` and add `/symlinks/` to `~/.claude/.gitignore`.

**Option B — Drop the doc.** No consumer exists. Aspirational features that never materialize confuse future-you. Edit `CLAUDE.md`: remove the "Cross-repo bridge: `~/.claude/symlinks/`" section, or replace with "(deferred — no consumer yet, revisit when one appears)".

### Recommendation

Option B. The infra cost (write module, declare each link, rebuild for every new bridge) is high relative to the benefit (slight ergonomic win for hooks). If a consumer appears, switch to Option A then.

### Verify (Option B)

```bash
# After CLAUDE.md edit:
grep -i 'claude/symlinks' /home/jonathan/Repos/nixos-config/CLAUDE.md   # expect: 0 hits
grep -r 'claude/symlinks' /home/jonathan/.claude --include='*.py' --include='*.sh' 2>/dev/null   # expect: 0 hits
```

### Verify (Option A)

```bash
sudo nixos-rebuild switch --flake /etc/nixos#dellan
ls -la /home/jonathan/.claude/symlinks/
# Expect: each declared link present, points into /nix/store/.../, ultimately resolves to /etc/nixos/<path>.
```
