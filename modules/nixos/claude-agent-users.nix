# modules/nixos/claude-agent-users.nix
#
# Dedicated unprivileged users for AI agents working in worktrees.
# Threat-model rationale (spec section "Threat model assumptions"):
#
#   - The current `gh` wrapper authenticates as jonathan (admin). An AI
#     agent with shell access in a worktree could otherwise call
#     `gh pr review --approve <its-own-PR>` and bypass the human-review
#     gate (admin is in the bypass list for status checks).
#
#   - This module creates dedicated `claude-agent-{1,2,3}` users that:
#       1. Are NOT in `wheel` (no sudo)
#       2. Have NO `gh` token in their HOME
#       3. Have NO membership in any privileged group
#
#   - The bare repo and worktree directories are group-readable by
#     `claude-agents` so agents can read/clone/edit their own worktree
#     but cannot push as jonathan. Each agent uses its own SSH key with
#     `repo:write` scope only (no admin, no PR-merge approval).
#
#   - The `gh` shell wrapper at home/jonathan.nix lives in jonathan's
#     PATH only, never on a claude-agent's PATH.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.claudeAgentUsers;

  agentUser = name: {
    isNormalUser = true;
    description = "AI agent ${name} — unprivileged worker";
    group = "claude-agents";
    extraGroups = [ ];   # explicitly no wheel, no docker, no anything
    home = "/home/${name}";
    createHome = true;
    shell = pkgs.bashInteractive;
    # Optional: pin to a known UID range to make audit easier.
  };
in
{
  options.services.claudeAgentUsers = {
    enable = lib.mkEnableOption "dedicated unprivileged users for AI agents";

    count = lib.mkOption {
      type = lib.types.ints.between 1 9;
      default = 3;
      description = "Number of claude-agent-N users (matches concurrent VM lanes).";
    };

    sharedWorktreeRoot = lib.mkOption {
      type = lib.types.str;
      default = "/home/jonathan/Repos/nixos-config-worktrees";
      description = "Worktree root, group-readable to claude-agents.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.groups.claude-agents = { };

    users.users = (lib.listToAttrs (map (n: {
      name = "claude-agent-${toString n}";
      value = agentUser "claude-agent-${toString n}";
    }) (lib.range 1 cfg.count))) // {
      # jonathan is in claude-agents so they share the worktree-readable
      # group. (Group, not setuid.)
      jonathan.extraGroups = [ "claude-agents" ];
    };

    # Loosen worktree-root permissions so agents can create/edit their
    # subdirectories. The bare repo at ~/Repos/nixos-config (NOT under
    # this dir) stays jonathan-owned: agents read it via group, can't
    # push origin without their own SSH key.
    systemd.tmpfiles.rules = [
      "d ${cfg.sharedWorktreeRoot} 0775 jonathan claude-agents - -"
    ];
  };
}
