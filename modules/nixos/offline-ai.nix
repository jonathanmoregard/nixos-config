# offline-ai — a local assistant for when the internet is down.
#
# Two pieces:
#   - `offline-ai-llm.service`, a user unit running llama.cpp's server with
#     one large local model. Installed but never started automatically: the
#     model takes ~45 GiB of RAM, so it runs only while it is wanted.
#   - `offline-ai`, a small CLI (scripts/offline-ai.py) that starts that
#     unit on demand and lets the model look things up with read-only
#     tools: the NixOS and home-manager option reference, this flake as
#     deployed in /etc/nixos, systemd unit state and logs, and the local
#     reference library. It proposes commands; it never runs any that
#     change state.
#
#   offline-ai "how do I stop tailscale until next boot"
#   offline-ai            # conversation
#   offline-ai down       # stop the model server and free the RAM
#
# WHY CPU AND NOT THE iGPU OR NPU. Measured on this machine 2026-09-30 with
# this exact model (Qwen3-Coder-Next 80B-A3B, Q4_K_M): 12-13 tok/s on CPU
# alone, 12.9 tok/s with as many layers as fit on the Radeon 890M. The
# model is a sparse mixture-of-experts, so generation is bound by memory
# bandwidth, which CPU and iGPU share. CPU-only needs no GTT kernel
# parameter and leaves the iGPU free. A 27B dense model managed 1-4 tok/s
# and answered worse. The NPU cannot run a model this size.
#
# THE MODEL IS NOT IN THE NIX STORE. It is 46 GB of weights fetched once
# into the home directory; putting it in the store would copy it into every
# closure and every VM test. ConditionPathExists keeps the unit inert on a
# machine that has not fetched it, and the CLI says how to fetch:
#
#   nix shell nixpkgs#python3Packages.huggingface-hub -c hf download \
#     Qwen/Qwen3-Coder-Next-GGUF --include 'Qwen3-Coder-Next-Q4_K_M/*' \
#     --local-dir ~/.local/share/llm-models/qwen3-coder-next
{ config, pkgs, ... }:
let
  home = config.users.users.jonathan.home;
  model = "${home}/.local/share/llm-models/qwen3-coder-next/Qwen3-Coder-Next-Q4_K_M/Qwen3-Coder-Next-Q4_K_M-00001-of-00004.gguf";
  port = 8717;
  unit = "offline-ai-llm.service";

  # Every setting is a default the environment may override; the check in
  # tests/offline-ai.nix points the same wrapper at a stub server.
  offlineAi = pkgs.writeShellApplication {
    name = "offline-ai";
    runtimeInputs = [ pkgs.python3 pkgs.poppler-utils pkgs.systemd ];
    text = ''
      export OFFLINE_AI_URL="''${OFFLINE_AI_URL:-http://127.0.0.1:${toString port}}"
      export OFFLINE_AI_UNIT="''${OFFLINE_AI_UNIT:-${unit}}"
      export OFFLINE_AI_MODEL="''${OFFLINE_AI_MODEL:-${model}}"
      export OFFLINE_AI_CONFIG_ROOT="''${OFFLINE_AI_CONFIG_ROOT:-/etc/nixos}"
      export OFFLINE_AI_FLAKE_HOST="''${OFFLINE_AI_FLAKE_HOST:-${config.networking.hostName}}"
      export OFFLINE_AI_NIXOS_OPTIONS="''${OFFLINE_AI_NIXOS_OPTIONS:-${config.system.build.manual.optionsJSON}/share/doc/nixos/options.json}"
      export OFFLINE_AI_HM_OPTIONS="''${OFFLINE_AI_HM_OPTIONS:-/etc/profiles/per-user/jonathan/share/doc/home-manager/options.json}"
      export OFFLINE_AI_DOC_DIRS="''${OFFLINE_AI_DOC_DIRS:-${home}/Repos/survival-corpus/corpus}"
      exec python3 ${../../scripts/offline-ai.py} "$@"
    '';
  };
in
{
  environment.systemPackages = [ offlineAi ];
  system.build.offline-ai = offlineAi;

  # Installs the home-manager option reference as JSON into the user
  # profile, which is where the CLI reads it from.
  home-manager.users.jonathan.manual.json.enable = true;

  systemd.user.services.offline-ai-llm = {
    description = "offline-ai local model server (llama.cpp)";
    unitConfig.ConditionPathExists = model;
    serviceConfig = {
      # -np 1: one conversation at a time, so the whole 32k context belongs
      # to it instead of being divided between server slots.
      ExecStart = "${pkgs.llama-cpp-vulkan}/bin/llama-server -m ${model} -ngl 0 -t 12 -c 32768 -np 1 --jinja -fa on --host 127.0.0.1 --port ${toString port}";
      Restart = "no";
    };
  };
}
