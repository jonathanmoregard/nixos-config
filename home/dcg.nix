# home/dcg.nix — dcg on PATH, and its config wired to the tracked copy.
#
# `dcg` (overlays/dcg.nix) is the first and richest deny layer the Claude
# Code guard stack consults before running a shell command. It was
# previously `cargo install`ed into ~/.local/bin on the old Linux Mint
# box, with ~/.config/dcg/config.toml hand-symlinked to ~/.claude/dcg.toml.
# The Mint → NixOS migration dropped both. Nothing failed loudly, because
# the consumer treats "dcg missing" as "nothing to block" — so the guard
# was inert for months and the loss surfaced only when someone went
# looking. Declaring the package here makes the binary part of the system
# closure: it can no longer disappear without a diff.
#
# WHY mkOutOfStoreSymlink RATHER THAN `home.file.…text` OR `.source`
#
# The pattern list in ~/.claude/dcg.toml is edited by hand, often, while
# reasoning about a command that just got blocked. A store copy would
# freeze it: every edit would need a rebuild before it took effect, and
# an edit made without one would appear to do nothing. mkOutOfStoreSymlink
# points ~/.config/dcg/config.toml at the live file in the ~/.claude repo,
# so edits take effect on the next dcg invocation while the LINK itself
# stays declarative — the thing the migration lost was the link, not the
# file.
#
# dcg's own config-trust policy permits this: only automatically
# discovered project configs (`.dcg.toml`) and the system layer
# (/etc/dcg/config.toml) are opened O_NOFOLLOW. The user layer
# ($XDG_CONFIG_HOME/dcg/config.toml) is `ConfigSource::Untrusted`, which
# follows symlinks by design — "selecting an explicit path is itself the
# trust decision" (upstream src/config.rs).
#
# ~/.claude is a git repo that home-manager does not own, so the target
# is referenced by absolute path rather than imported into the store;
# a dangling link (fresh host, repo not yet cloned) is not an activation
# error — dcg simply falls back to its built-in packs.
{ config, pkgs, ... }:

{
  home.packages = [ pkgs.dcg ];

  home.file.".config/dcg/config.toml".source =
    config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/.claude/dcg.toml";
}
