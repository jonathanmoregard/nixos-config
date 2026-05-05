---
status: proposed
category: drift
subcategory: tooling
date: 2026-05-05
source: advice-refine-loop
---

## ~/.huskyrc loads `nvm.sh` but nvm not packaged in flake

`home/jonathan.nix:48-54` declares the husky pre-commit helper:

```nix
home.file.".huskyrc".text = ''
  # Load nvm for husky hooks
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
'';
```

On Mint, `~/.nvm/nvm.sh` exists (installed via `curl ... | bash`). On dellan, it doesn't — the `[ -s ... ]` guard silently no-ops, and husky pre-commit hooks across every JS repo fall through to whatever `node` is on PATH (currently `nodejs_22` from `home.packages`).

`CLAUDE.md` line 96 already documents this gap:

> **`~/.huskyrc`**: declared in `home/jonathan.nix` (loads nvm for husky pre-commit hooks). NVM itself is not declared in this flake — install via `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash` if needed.

**The risk:** dellan currently silently runs husky hooks against `nodejs_22` even when a repo's `package.json#engines.node` (or `.nvmrc`) demands a different version. If any repo claude-code regularly opens has a strict node-version pin, hooks break in subtle ways.

### Three approaches

**A. Imperative install (CLAUDE.md status quo).** Run the curl install once on dellan post-bootstrap. Drift detector won't flag missing nvm because it's user-installed under `~/.nvm`. Pro: zero flake change. Con: imperative, lost on `rm -rf ~/.nvm`.

**B. Declarative via `home.activation.installNvm`.** Add to `home/jonathan-linux.nix`:

```nix
home.activation.installNvm = lib.hm.dag.entryAfter ["writeBoundary"] ''
  if [ ! -s "$HOME/.nvm/nvm.sh" ]; then
    PROFILE=/dev/null ${pkgs.bash}/bin/bash -c 'curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash' || true
  fi
'';
```

Idempotent. Captures the install in the flake. Soft-fails offline. Caveat: each `home-manager switch` re-checks; an outdated `~/.nvm` won't auto-upgrade.

**C. Drop nvm, package node versions via flake overlays.** Replace nvm with a per-repo `direnv` + `flake.nix` declaring the node version. Pro: fully declarative, no nvm runtime. Con: requires per-repo flake.nix, breaks compatibility with non-nix users of those repos.

### Recommendation

**B.** Activation script is the smallest declarative win. C is overkill while you also use these repos from non-nix machines (Mac mini incoming).

### Fix (Option B)

```nix
# home/jonathan-linux.nix — add to existing activation block, OR new entry:

home.activation.installNvm = lib.hm.dag.entryAfter ["writeBoundary"] ''
  # nvm is referenced by ~/.huskyrc for husky pre-commit hooks. Idempotent
  # install — only runs the network-fetching shell when ~/.nvm/nvm.sh
  # is missing. Soft-fails (|| true) so no network = no rebuild break.
  if [ ! -s "$HOME/.nvm/nvm.sh" ]; then
    PROFILE=/dev/null ${pkgs.bash}/bin/bash -c '${pkgs.curl}/bin/curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash' 2>/dev/null || true
  fi
'';
```

### Verify

```bash
sudo nixos-rebuild switch --flake /etc/nixos#dellan
ls -la ~/.nvm/nvm.sh
# Expect: a regular file ~150KB
# Test husky hook indirectly:
cd ~/Repos/voquill   # or any JS repo with husky
git commit --allow-empty -m "test husky" 2>&1 | head
# Expect: no "nvm: command not found", no missing-node errors
```

### Notes
- nvm version pin `v0.40.1` matches what's on Mint and what CLAUDE.md
  already documents. Bump together if upgrading.
- `PROFILE=/dev/null` prevents the installer from appending to
  `~/.bashrc` / `~/.zshrc` (those are HM-managed; appending breaks
  reproducibility).
