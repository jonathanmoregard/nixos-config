# modules/nixos/ci-state.nix
#
# Round 7 (post AI-reviewer removal) leaves this module with no state to
# persist. The label-gate's `gh api .../timeline` walk is the live
# source of truth for label-add audit; we don't need a separate
# append-only log file.
#
# Kept as a stub so existing references in spec/impl ordering still
# resolve, and future state needs (e.g. circuit-breaker if AI reviewer
# is re-introduced) have a place to land. Currently a no-op.
{ ... }:
{
  # Intentionally empty — the dir is no longer needed. Re-introduce
  # systemd.tmpfiles.rules here if a future change adds state.
}
