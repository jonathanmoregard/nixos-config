# Nightly dependency health of the repos below: open Dependabot alerts,
# Dependabot PRs that are stale (> 7 days) or red, and scheduled workflows
# whose latest run on the default branch failed. Logic: dependency-health.sh.
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
# No webhook, no user authorization. Installed on jonathanmoregard (only the
# repos below) and on the klaffat org (klaffat/klaffat).
#
# Provisioning, then fill in `app` below in the same PR:
#   - the private key, as agenix secret `github-dependency-health-app-key`,
#     owner root 0400 — systemd hands it to the runner (LoadCredential); no
#     user, agent or other service can read it:
#       add-secret github-dependency-health-app-key --host tuxedo --owner root --group root --from-stdin < app.private-key.pem
#   - app.id: the App ID on the App's settings page;
#   - app.installations: per owner, the number at the end of
#     https://github.com/settings/installations/<id> (personal) and
#     https://github.com/organizations/klaffat/settings/installations/<id>.
# The App id and installation ids are identifiers, not secrets.
#
# Installation tokens are minted per run by gh-token (nixpkgs; Link-/gh-token)
# from that key: one per owner, held in the process, expiring within the hour.
#
# Until the key is declared and `app` filled in, the runner still runs and
# fails loudly ("GitHub App not provisioned") every night, so the missing
# check is visible rather than silent; the build does not depend on the
# secret.
{ config, lib, pkgs, ... }:
let
  # owner/name; the summary names repos by `name`, so keep names unique.
  repos = [
    "klaffat/klaffat"
    "jonathanmoregard/.claude"
    "jonathanmoregard/nixos-config"
    "jonathanmoregard/injection-scanner"
    "jonathanmoregard/research-agent"
    "jonathanmoregard/aggregator"
    "jonathanmoregard/ai-client-config"
    "jonathanmoregard/smarthome"
  ];
  app = {
    id = null;
    installations = {
      # jonathanmoregard = 12345678;
      # klaffat = 12345678;
    };
  };
  keySecret = "github-dependency-health-app-key";
  runnerConfig = pkgs.writeText "dependency-health.json" (builtins.toJSON {
    inherit repos;
    app_id = app.id;
    inherit (app) installations;
  });
in
{
  imports = [ ../security-batch.nix ];

  services.securityBatch.dependency-health = {
    schedule = "*-*-* 04:30";
    # Eight installation-token mints and a few dozen REST GETs.
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
