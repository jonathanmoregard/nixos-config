# modules/nixos/ci-state.nix
#
# /var/lib/ci-state — owned by root:actions-runner mode 0775. Stores:
#
#   - label-events.jsonl    audit trail of label-add events
#
# AI reviewer removed in spec round 7 (research-recommended): no
# ai-approved-merges.jsonl, no circuit-breaker state, no snapshot timer.
# Closure-diff classifier is the only automated decision; humans gate
# all CRITICAL/HIGH/MEDIUM via Rulesets.
{ ... }:
{
  systemd.tmpfiles.rules = [
    "d /var/lib/ci-state 0775 root actions-runner - -"
    # Append-only audit log for label-add events. Workflows append via
    # runner identity; useful for post-incident review.
    "f /var/lib/ci-state/label-events.jsonl 0664 root actions-runner - -"
  ];
}
