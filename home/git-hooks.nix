{ lib, pkgs, config, ... }:
# Global git-hook registry.
#
# The user's core.hooksPath (set in home/jonathan.nix) is
# ~/.config/git/hooks, meaning every git repo shares one hook file per
# event. Multiple consumers therefore cannot each own their own
# .config/git/hooks/pre-push via home.file — the second module would
# clobber the first.
#
# This module owns the file and exposes homeGitHooks.prePush as a
# list of { name; repoPath; body; } entries. Consumer modules register
# a dispatch by adding to the list; this module renders one bash
# script that runs each entry's body when `git rev-parse
# --show-toplevel` matches its repoPath. Every entry's body runs
# under `|| true` and the hook exits 0 unconditionally, so a
# consumer's failure never blocks the push itself.
let
  cfg = config.homeGitHooks;

  entryBlock = e: ''
    # ${e.name}
    if [ "$toplevel" = "${e.repoPath}" ]; then
      ${e.body}
    fi
  '';

  hookText = ''
    #!/usr/bin/env bash
    # Global pre-push hook. Dispatches on repo toplevel. Never blocks
    # the push — every body runs || true and the hook exits 0.
    toplevel="$(${pkgs.git}/bin/git rev-parse --show-toplevel 2>/dev/null)"
    ${lib.concatMapStringsSep "\n" entryBlock cfg.prePush}
    exit 0
  '';
in
{
  options.homeGitHooks.prePush = lib.mkOption {
    description = ''
      Dispatch entries for the shared global pre-push hook.
      Each entry runs when a push originates from repoPath.
    '';
    default = [ ];
    type = lib.types.listOf (lib.types.submodule {
      options = {
        name = lib.mkOption {
          type = lib.types.str;
          description = "Short identifier used in the hook comment.";
        };
        repoPath = lib.mkOption {
          type = lib.types.str;
          description = ''
            Absolute path (may contain $HOME) matched against
            `git rev-parse --show-toplevel`.
          '';
        };
        body = lib.mkOption {
          type = lib.types.lines;
          description = ''
            Bash body executed when repoPath matches. Should end each
            command with `|| true` — the outer hook exits 0 regardless,
            but non-zero mid-body without `|| true` still short-circuits
            later lines under `set -e` (not set here, but keep the
            convention).
          '';
        };
      };
    });
  };

  config = lib.mkIf (cfg.prePush != [ ]) {
    home.file.".config/git/hooks/pre-push" = {
      executable = true;
      text = hookText;
    };
  };
}
