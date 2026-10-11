# Weekly security sweep of the research-agent and scraper microVMs: new
# high-CVSS CVEs in their closures, and regressions in the systemd sandbox
# scores of the units that confine them. Logic and accepted.txt format:
# research-agent.sh. Proposed in the 2026-10-03 research-agent security
# review (§7 steps 1-2); the network oracles (step 3) and the monthly canary
# (step 4) are not here yet.
{ config, pkgs, ... }:
{
  imports = [ ../security-batch.nix ];

  services.securityBatch.research-agent = {
    schedule = "Sun 03:00";
    # The first run downloads the NVD feeds (~200 MB parsed); later runs
    # take seconds. Generous, but bounded.
    timeout = "2h";
    acceptedFindings = ./research-agent.accepted.txt;
    script = pkgs.writeShellApplication {
      name = "security-batch-research-agent";
      runtimeInputs = [
        pkgs.vulnix config.nix.package config.systemd.package
        pkgs.jq pkgs.gawk pkgs.gnugrep pkgs.gnused pkgs.coreutils
      ];
      text = builtins.readFile ./research-agent.sh;
    };
  };
}
