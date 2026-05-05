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

On Mint, `~/.nvm/nvm.sh` was installed via `curl ... | bash`. On dellan, it doesn't exist; the `[ -s ... ]` guard silently no-ops, and husky pre-commit hooks fall through to whatever `node` is on PATH (currently `nodejs_22` from `home.packages`).

CLAUDE.md line 96 documents the gap and recommends `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash`. **That recommendation conflicts with the project's own security policy** in CLAUDE.md "Web access" section (no curl/wget outside the research-agent). Pulling installers via curl-pipe-bash inside a `home.activation` block also breaks flake hygiene — every other web fetch in this flake (`cloneRepos`) uses `${pkgs.git}/bin/git clone`, never raw curl.

### Recommendation: drop nvm entirely

The .huskyrc fallback exists so husky can find a node version pinned in a repo's `.nvmrc`. But:
- `nodejs_22` is in `home.packages` — `node` and `npm` are on PATH.
- No repo claude-code regularly opens has a `.nvmrc` pinning a non-22 version (verified: `find ~/Repos -maxdepth 2 -name '.nvmrc' 2>/dev/null` returns 0 hits on Mint).
- husky just needs **some** node binary; the version pinning was a Mint-era artifact.

### Fix — Option A (recommended): delete the husky/nvm shim

Edit `home/jonathan.nix`:

```nix
# Delete this entire block:
home.file.".huskyrc".text = ''
  # Load nvm for husky hooks
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
'';
```

Edit `CLAUDE.md` "Known gaps" section: remove the `~/.huskyrc` bullet pointing at the nvm install command.

### Fix — Option B (fallback if some repo *does* need a non-22 node)

If a future repo pins a different node version, package nvm via `pkgs.fetchFromGitHub` instead of curl-pipe-bash:

```nix
# home/jonathan-linux.nix
let
  nvm = pkgs.fetchFromGitHub {
    owner = "nvm-sh";
    repo = "nvm";
    rev = "v0.40.1";
    hash = "sha256-...";  # nix-prefetch-url it once
  };
in
home.activation.installNvm = lib.hm.dag.entryAfter ["writeBoundary"] ''
  if [ ! -d "$HOME/.nvm" ]; then
    mkdir -p "$HOME/.nvm"
    cp -r ${nvm}/. "$HOME/.nvm/"
    chmod -R u+w "$HOME/.nvm"
  fi
'';
```

No network during activation. Pinned hash. Reproducible.

### Verify (Option A)

```bash
sudo nixos-rebuild switch --flake /etc/nixos#dellan
ls ~/.huskyrc
# expect: ENOENT (HM removed it)
cd ~/Repos/voquill   # or any JS repo
git commit --allow-empty -m "test husky" 2>&1 | head
# expect: husky hooks run with nodejs_22 successfully, no errors
```

### Notes
- If Option B is chosen, run `nix-prefetch-github nvm-sh nvm v0.40.1`
  on dellan to get the SHA256 hash before committing.
