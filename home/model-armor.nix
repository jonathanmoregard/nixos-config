# Google Cloud Model Armor endpoint ids — single source of truth.
#
# The injection-scanner's L2 panel (injection_scanner/modelarmor.py) builds
# its sanitizeUserPrompt URL from MODEL_ARMOR_PROJECT / _LOCATION /
# _TEMPLATE and authenticates with the service-account key at
# MODEL_ARMOR_CREDENTIALS_FILE (agenix secret `model-armor-sa-key`; SA
# `pi-scanner`, roles/modelarmor.user only).
#
# These ids are POINTERS, not secrets — they name the project, region and
# template but grant no access by themselves (the agenix key does that), so
# they live here as plain nix strings.
#
# Imported by every wrapper that spawns the scanner:
#   - home/research-agent-mcp.nix   (research-agent-mcp)
#   - home/futuresearch-gate-mcp.nix (futuresearch-gate-mcp)
# Change an id HERE and both call sites follow.
{
  project = "jm-pi-scanner";
  location = "europe-west4";
  template = "pi-scanner";
}
