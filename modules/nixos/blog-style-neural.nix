# Neural detector channel for the blog style-detector ensemble.
#
# Two API-based authorship/AI-text detector channels that complement the local
# stdlib stylometric detector (~/.claude/skills/brand-copy/style-detector.py):
#   - StyleDistance embedding cosine-to-corpus (HF)          -> hf-token
#   - Fast-DetectGPT-lite perplexity/curvature (Fireworks)   -> fireworks-api-key
#
# Provider = Fireworks serverless, model gpt-oss-20b via the OpenAI-compatible
# /completions endpoint (echo+logprobs, validated 2026-07-10). Fireworks retired
# the small Llamas from serverless; gpt-oss-20b is the smallest LLM there and is
# a fine reference LM for perplexity scoring (~$0.07/M input). To switch provider
# later (e.g. Together), change FASTDETECT_COMPLETIONS_URL/FASTDETECT_MODEL below
# and the key in the fireworks-api-key secret.
#
# Both keys are user-owned agenix secrets decrypted to /run/agenix/<name>
# (owner jonathan, 0400) — same shape as the other api-key secrets in
# hosts/dellan/default.nix. The consumer is a user-launched script, not a
# systemd service, so we follow the listen-tools.nix pattern: a
# writeShellApplication that reads the secret at exec time and exports it into
# only this process's env (never the user's shell rc).
{ config, pkgs, lib, ... }:
{
  age.secrets.fireworks-api-key = {
    rekeyFile = ../../secrets/fireworks-api-key.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };
  age.secrets.hf-token = {
    rekeyFile = ../../secrets/hf-token.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "blog-style-neural";
      runtimeInputs = [ pkgs.python3 ];
      # The detector script lives in ~/.claude (outside nix); the wrapper
      # provisions the keys + provider config + interpreter and forwards args.
      # The script reads the perplexity key from DEEPINFRA_API_KEY (its
      # provider-agnostic key var — holds the Fireworks key here). HF_ENDPOINT_URL
      # is optional (set in the user's env if a dedicated StyleDistance endpoint is
      # created; otherwise HF serverless). Each channel SKIPs cleanly if its key
      # file is unreadable, so partial provisioning is safe.
      text = ''
        export FASTDETECT_COMPLETIONS_URL="https://api.fireworks.ai/inference/v1/completions"
        export FASTDETECT_MODEL="accounts/fireworks/models/gpt-oss-20b"
        if [ -r "${config.age.secrets.fireworks-api-key.path}" ]; then
          DEEPINFRA_API_KEY="$(< "${config.age.secrets.fireworks-api-key.path}")"
          export DEEPINFRA_API_KEY
        fi
        if [ -r "${config.age.secrets.hf-token.path}" ]; then
          HF_TOKEN="$(< "${config.age.secrets.hf-token.path}")"
          export HF_TOKEN
        fi
        exec python3 "$HOME/.claude/skills/brand-copy/neural_channel.py" "$@"
      '';
    })
  ];
}
