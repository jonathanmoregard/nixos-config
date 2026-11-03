# Test-only HM entrypoint for vm-cache-publisher: jonathan.nix for
# core.hooksPath, the shared hook registry, and the enqueue body under test.
{ ... }:
{
  imports = [
    ./jonathan.nix
    ./git-hooks.nix
    ./cache-publisher-enqueue.nix
  ];
}
