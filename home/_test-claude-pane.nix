# Test-only HM entrypoint for vm-claude-pane.
#
# vm-claude-pane exercises the Claude Code SessionStart hook
# (claude-kitty-pane-record) + enricher (kitty-session-enrich), both
# defined in home/kitty.nix. No display manager / X needed — the
# assertions are pure script + TSV behavior on a fake `kitty @ ls`
# JSON payload.
#
# Excludes everything else (cinnamon, desktop-apps, ghostty, autodoro,
# drift-analyzer, router-services, claude-services, claude-skills,
# research-agent-mcp, jonathan.nix's shell/git/p10k/nodejs/rust toolchain)
# so vm-claude-pane's drvPath is invariant to edits in those files.
{ ... }:
{
  imports = [
    ./_test-base.nix
    ./kitty.nix
  ];
}
