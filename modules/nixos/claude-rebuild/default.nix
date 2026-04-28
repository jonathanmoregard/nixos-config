{ config, pkgs, lib, ... }:
# claude-rebuild — blast-radius-gated nixos-rebuild for autonomous agents.
#
# Three console scripts on PATH:
#   claude-rebuild-classify   — JSON tier output, pure userland
#   claude-rebuild-apply LOW  — invoked via NOPASSWD sudo from MCP server
#   claude-rebuild-apply HIGH — invoked via pkexec (polkit desktop prompt) from MCP server
#   claude-rebuild-mcp        — MCP stdio server (registered with claude CLI)
#
# Register the MCP server once per user:
#   claude mcp add --scope user claude-rebuild claude-rebuild-mcp
let
  pkg = pkgs.python3.pkgs.buildPythonApplication {
    pname = "claude-rebuild";
    version = "0.1.0";
    pyproject = true;
    src = ./src;
    build-system = [ pkgs.python3.pkgs.setuptools ];
    dependencies = [ pkgs.python3.pkgs.mcp ];
    # The classifier and apply binaries shell out to git and nixos-rebuild;
    # both are on the system PATH at runtime, so no propagatedBuildInputs needed.
    doCheck = false;
  };
in {
  environment.systemPackages = [ pkg ];

  # State dir owned by jonathan (apply runs as root via sudo/pkexec, but the
  # MCP server reads last-applied-rev as user). Lock file + audit log written
  # by root; world-readable so user-side classifier can use last-applied-rev.
  systemd.tmpfiles.rules = [
    "d /var/lib/claude-rebuild 0755 root root -"
    # Audit log includes caller PIDs + parent-process cmdlines, which can
    # include credentials passed via argv by upstream wrappers. Restrict
    # to wheel so non-admin users can't trawl forensic identity data.
    "f /var/log/claude-rebuild.log 0640 root wheel -"
  ];

  # /etc/nixos is root-owned; classifier runs as jonathan via the MCP server.
  # Without this, git's safe-directory check refuses to operate on a repo
  # not owned by the current user. Pin to /etc/nixos exactly — don't open
  # the floodgates with `*`.
  programs.git.config = {
    safe.directory = "/etc/nixos";
  };

  # Sudoers — NOPASSWD only for the LOW tier. HIGH must go through pkexec.
  # The apply binary re-runs the classifier and rejects if its own classification
  # disagrees with the requested tier (defense in depth).
  #
  # IMPORTANT: sudo command-match is positional and matches as a PREFIX —
  # `claude-rebuild-apply low` allows any args after `low` (e.g. `--from`,
  # `--to`). Defense in depth (re-classification + tier check) is what keeps
  # this safe. If you ever add a new flag to apply that bypasses or weakens
  # classification (e.g. `--skip-classify`), you MUST also tighten this rule
  # or that flag becomes silently NOPASSWD-callable from any context that
  # can sudo. Audit `apply.py` flags before changing this.
  security.sudo.extraRules = [{
    users = [ "jonathan" ];
    commands = [{
      command = "${pkg}/bin/claude-rebuild-apply low";
      options = [ "NOPASSWD" ];
    }];
  }];

  # Polkit — pkexec on the apply binary triggers the default
  # `org.freedesktop.policykit.exec` action, which prompts the user's password
  # via the desktop polkit agent. No additional rule needed; default behavior
  # IS the HITL gate.
  #
  # The Cinnamon DE provides a polkit auth agent (polkit-gnome) by default.
}
