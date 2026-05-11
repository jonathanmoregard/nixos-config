# home/claude-skills.nix
#
# Symlinks Claude Code skills from this repo into ~/.claude/skills/.
# Lets agent-facing skills go through the nixos-config CI/CD gate
# (PR → classifier → label-gate → auto-deploy) instead of being
# edited live in ~/.claude/.
#
# Adding a new skill:
#   1. Drop it under home/claude-skills/<name>/SKILL.md
#   2. Append the name to the `skills` list below
#   3. Open PR; classifier labels (likely LOW since HM-only); merge
#
# If ~/.claude/skills/<name>/ already exists as a real directory,
# remove it before the rebuild — home-manager refuses to clobber
# untracked content.
{ ... }:
let
  skills = [
    "nixos-config-dev"
    "nixos-automated-testing"
    "nixos-agent-testing"
  ];
in
{
  home.file = builtins.listToAttrs (map (name: {
    name = ".claude/skills/${name}";
    value = { source = ./claude-skills + "/${name}"; };
  }) skills);
}
