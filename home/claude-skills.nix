# home/claude-skills.nix
#
# Symlinks Claude Code skills from this repo into ~/.claude/.
# Lets agent-facing skills go through the nixos-config CI/CD gate
# (PR → CI → auto-deploy) instead of being edited live in
# ~/.claude/.
#
# Adding a new skill:
#   1. Drop it under home/claude-skills/<name>/SKILL.md
#   2. Append the name to the `skills` list below
#   3. Open PR; merge once green
#
# If ~/.claude/skills/<name>/ already exists as a real directory,
# remove it before the rebuild — home-manager refuses to clobber
# untracked content.
#
# Two targets per skill, on purpose:
#
#   .claude/skills-hm/<name>   the owning location, permanent.
#   .claude/skills/<name>      transitional; see below.
#
# claude-config (jonathanmoregard/claude-config) is moving its runtime
# tree to ~/Repos/claude-config/runtime and projecting the runtime
# subset back into ~/.claude through read-only bind mounts, so that dev
# and test code in that repo is never reachable as live agent code. Once
# that lands, ~/.claude/skills is a read-only projection and home-manager
# can no longer write inside it — a `home.file` target there would fail
# the next `nixos-rebuild switch`, at rebuild time rather than at cutover.
# So these four skills keep being owned by home-manager (they exist to go
# through *this* repo's gate) and are written somewhere unprojected and
# writable; claude-config carries an absolute symlink
# runtime/skills/<name> -> /home/jonathan/.claude/skills-hm/<name>.
# Absolute is the only spelling that is correct both on disk and under
# the mounts.
#
# The .claude/skills/<name> copies stay until that cutover, because the
# mounts do not exist yet and nothing else puts these skills on the path
# agents actually read. Removing them before the projection is live would
# make nixos-config-dev and friends undiscoverable in the meantime.
#
# At cutover: delete `compatTargets` below and keep `skills-hm` only.
{ ... }:
let
  skills = [
    "nixos-config-dev"
    "nixos-automated-testing"
    "nixos-agent-testing"
    "nixos-agenix-secret"
  ];

  entry = prefix: name: {
    name = "${prefix}/${name}";
    value = { source = ./claude-skills + "/${name}"; };
  };

  # Permanent home. Outside the claude-config runtime projection, so it
  # stays writable by home-manager after cutover.
  hmTargets = map (entry ".claude/skills-hm") skills;

  # Transitional: delete at claude-config L2 cutover (see header).
  #
  # These MUST survive until the cutover deploy itself, and dropping them in
  # the same change that adds the projection was a mistake caught in review.
  # Removing them makes home-manager's orphan cleanup delete the live
  # ~/.claude/skills/nixos-* links on the next activation, and the replacement
  # read path — runtime/skills/<name>, via the projection — is not reachable
  # until ~/.claude/skills is itself a symlink into the mount, which only
  # happens at cutover. In between, these four skills silently disappear.
  compatTargets = map (entry ".claude/skills") skills;
in
{
  home.file = builtins.listToAttrs (hmTargets ++ compatTargets);
}
