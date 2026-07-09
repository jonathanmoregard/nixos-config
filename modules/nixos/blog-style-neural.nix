# Neural detector channel for the blog style-detector ensemble.
#
# Two API-based authorship/AI-text detector channels that complement the local
# stdlib stylometric detector (~/.claude/skills/brand-copy/style-detector.py):
#   - StyleDistance embedding cosine-to-corpus (HF)      -> HF_TOKEN
#   - Fast-DetectGPT-lite perplexity/curvature (DeepInfra) -> DEEPINFRA_API_KEY
#
# Both keys are user-owned agenix secrets decrypted to /run/agenix/<name>
# (owner jonathan, 0400) — same shape as the other api-key secrets in
# hosts/dellan/default.nix. The consumer is a user-launched script, not a
# systemd service, so we follow the listen-tools.nix pattern: a
# writeShellApplication that reads the secret at exec time and exports it into
# only this process's env (never the user's shell rc).
{ config, pkgs, lib, ... }:
{
  age.secrets.deepinfra-api-key = {
    rekeyFile = ../../secrets/deepinfra-api-key.age;
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
      # The detector script lives in ~/.claude (outside nix); the wrapper only
      # provisions the keys + interpreter and forwards args. HF_ENDPOINT_URL is
      # optional (set it in the user's env if a dedicated StyleDistance endpoint
      # is created; otherwise the script uses HF serverless). Each channel SKIPs
      # cleanly if its key file is unreadable, so partial provisioning is safe.
      text = ''
        if [ -r "${config.age.secrets.deepinfra-api-key.path}" ]; then
          DEEPINFRA_API_KEY="$(< "${config.age.secrets.deepinfra-api-key.path}")"
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
