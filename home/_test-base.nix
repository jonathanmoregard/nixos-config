# Minimum HM scaffolding for test-only entrypoints.
#
# Tests that pull in only a subset of HM modules need the HM-required
# globals (username/homeDirectory/stateVersion) without dragging in
# home/jonathan.nix's shell + git + p10k + nodejs/rust/python toolchain
# closure. Per-test entrypoints (home/_test-<lane>.nix) import this +
# the specific feature modules they exercise.
#
# Underscore prefix marks these as test-only — the production HM
# entrypoint is home/jonathan-linux.nix.
{ ... }:
{
  home.username = "jonathan";
  home.homeDirectory = "/home/jonathan";
  home.stateVersion = "25.11";
  programs.home-manager.enable = true;
}
