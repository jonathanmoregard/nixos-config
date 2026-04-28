{ pkgs, ... }:
# Cross-repo bridge — see /etc/nixos/CLAUDE.md "Cross-repo bridge" section.
#
# Builds ~/.claude/symlinks/ as a Nix-store-backed read-only directory.
# Each entry is a symlink pointing at a path inside nixos-config. All
# `.claude` references to nixos-config code go through this dir, never an
# absolute /etc/nixos/... path. If nixos-config relocates, only this file
# changes.
#
# Read-only at the dir level; targets (the /etc/nixos/... paths) remain
# writable. Editing through a symlink writes to nixos-config (intended).
# Adding a new link = edit this file + nixos-rebuild switch.
{
  home.file.".claude/symlinks".source = pkgs.runCommand "claude-symlinks" { } ''
    mkdir -p $out
    ln -s /etc/nixos/modules/nixos/claude-rebuild $out/claude-rebuild-nix
    ln -s /etc/nixos/modules/nixos/claude-rebuild/src $out/claude-rebuild-mcp
  '';
}
