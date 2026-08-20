# Test-only HM entrypoint for vm-claude-egress.
#
# Imports home/jonathan.nix ON PURPOSE, unlike its sibling _test-*
# entrypoints. The property under test is an ORDERING one: the
# claude()/claudee() functions contributed by claude-egress-slice.nix
# through `programs.zsh.initContent = lib.mkAfter` must land after — and
# therefore win over — the definitions in jonathan.nix:237. An entrypoint
# that imported only claude-egress-slice.nix would assert nothing about
# that, and would go green even if the merge order inverted.
#
# jonathan.nix:247 (`export PATH="$HOME/.local/bin:$PATH"`) is the other
# half of what makes this lane meaningful: it is what lets the test plant
# a fake native-installer `claude` ahead of the home-manager profile,
# which is the F2 case a wrapper package would have lost.
#
# Everything else jonathan-linux.nix pulls in (cinnamon, desktop-apps,
# autodoro, router-services, the MCP wrappers, the crontab) is excluded,
# so this lane's drvPath is invariant to edits in those files.
{ ... }:
{
  imports = [
    ./jonathan.nix
    ./claude-egress-slice.nix
  ];
}
