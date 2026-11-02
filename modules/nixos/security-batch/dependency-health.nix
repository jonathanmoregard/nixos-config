# Nightly dependency health of every active repo visible to the configured
# GitHub App installations: open Dependabot alerts, Dependabot PRs that are
# stale (> 7 days) or red, and scheduled workflows whose latest run on the
# default branch failed. Logic: dependency-health.sh.
# A finding reaches Claude sessions through the security-batch failure record
# (modules/nixos/security-batch.nix) and stays there until it is handled.
#
# Acceptance lives in GitHub, not here: dismiss the alert, or comment
# `@dependabot ignore …` / close the PR. Dismissed alerts and closed PRs are
# not open, so the next run is clean. No accepted.txt.
#
# ── Credential: a dedicated, read-only GitHub App ──
#
# Its own App, not the agents' claude-code-dev-box App and not a PAT, so the
# only thing this key can ever do is read. Repository permissions, exactly:
#   Dependabot alerts: Read-only
#   Pull requests:     Read-only
#   Actions:           Read-only
#   Metadata:          Read-only (mandatory)
# Everything else (contents, checks, workflows, administration, …): No access.
# No webhook, no user authorization. Installable on "Any account" (one App,
# two owners), installed on "All repositories" for both jonathanmoregard and
# the klaffat org.
#
# Provisioned: the private key is the agenix secret
# `github-dependency-health-app-key`, declared in
# profiles/workstation/default.nix with owner root and mode 0400. systemd
# hands it to the runner (LoadCredential); no user, agent or other service can
# read it. The App id and installation ids below are identifiers, not secrets.
#
# Installation tokens are minted per run by gh-token (nixpkgs; Link-/gh-token)
# from that key: one per owner, held in the process, expiring within the hour.
#
{ config, lib, pkgs, ... }:
let
  app = {
    id = 5578924;
    installations = {
      jonathanmoregard = 177815240;
      klaffat = 177815386;
    };
  };
  keySecret = "github-dependency-health-app-key";
  runnerConfig = pkgs.writeText "dependency-health.json" (builtins.toJSON {
    app_id = app.id;
    inherit (app) installations;
  });
in
{
  imports = [ ../security-batch.nix ];

  services.securityBatch.dependency-health = {
    schedule = "*-*-* 04:30";
    # One installation-token mint and repository listing per owner, then a
    # few REST GETs per active repo.
    timeout = "15min";
    acceptHint = "accept in GitHub: dismiss alert or @dependabot ignore";
    credentials = lib.optionalAttrs (config.age.secrets ? ${keySecret}) {
      github-app-key = config.age.secrets.${keySecret}.path;
    };
    # System units get no SSL_CERT_FILE; name the trust store rather than
    # rely on the clients' built-in search path (the scanner's urllib broke
    # on exactly that, fb31c84).
    serviceConfig.Environment = [ "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt" ];
    script = pkgs.writeShellApplication {
      name = "security-batch-dependency-health";
      runtimeInputs = [ pkgs.gh pkgs.gh-token pkgs.jq pkgs.gnugrep pkgs.coreutils ];
      text = ''
        set -- ${runnerConfig}
      '' + builtins.readFile ./dependency-health.sh;
    };
  };
}
