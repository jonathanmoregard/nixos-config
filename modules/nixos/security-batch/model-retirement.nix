# Weekly check that no vendor model pinned by a consumer repo is about to be
# shut down: OpenAI's `shutdown_date`, Anthropic's `lifecycle`, or a 404.
# Added after gpt-4.1-nano shut down under the injection-scanner honeypot on
# 2026-10-23 with no warning that reached anyone. Logic and accepted.txt
# format: model-retirement.sh. A finding reaches Claude sessions through the
# security-batch failure record (modules/nixos/security-batch.nix).
#
# Adding a consumer: publish a model-pins.json in its repo (schema in
# model-retirement.sh; injection-scanner's tests/test_model_pins.py is the
# pattern for keeping it equal to the code) and add its raw URL below, from
# the branch the consumer's call sites actually run.
{ config, lib, pkgs, ... }:
let
  manifests = [
    # Call sites self-update the scanner to origin/main (home/research-agent-mcp.nix,
    # home/futuresearch-gate-mcp.nix), so main is what runs.
    "https://raw.githubusercontent.com/jonathanmoregard/injection-scanner/main/model-pins.json"
  ];
in
{
  imports = [ ../security-batch.nix ];

  services.securityBatch.model-retirement = {
    schedule = "Mon 05:00";
    # A handful of metadata GETs with 30 s caps each.
    timeout = "15min";
    acceptedFindings = ./model-retirement.accepted.txt;
    credentials = {
      openai-api-key = config.age.secrets.openai-api-key.path;
      anthropic-api-key = config.age.secrets.anthropic-api-key.path;
    };
    serviceConfig.Environment = [
      "MODEL_RETIREMENT_MANIFESTS=${lib.concatStringsSep " " manifests}"
      "MODEL_RETIREMENT_WARN_DAYS=90"
      # System units get no SSL_CERT_FILE; name the trust store rather than
      # rely on curl's OpenSSL-default fallback (the scanner's urllib broke
      # on exactly that, fb31c84).
      "CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt"
    ];
    script = pkgs.writeShellApplication {
      name = "security-batch-model-retirement";
      runtimeInputs = [ pkgs.curl pkgs.jq pkgs.gawk pkgs.gnugrep pkgs.gnused pkgs.coreutils ];
      text = builtins.readFile ./model-retirement.sh;
    };
  };
}
