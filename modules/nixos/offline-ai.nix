# offline-ai — a local assistant for when the internet is down.
#
# Three pieces:
#   - `offline-ai-llm.service`, a user unit running llama.cpp's server with
#     one large local model. Installed but never started automatically: the
#     model takes ~45 GiB of RAM, so it runs only while it is wanted.
#   - `offline-ai-library.service`, a user unit running kiwix-serve over the
#     ZIM archives in the survival corpus (offline wikis and Q&A sites). It
#     is both the browsable library for a human (http://127.0.0.1:8718) and
#     the full-text search the assistant queries. Also on demand only.
#   - `offline-ai`, a small CLI (scripts/offline-ai.py) that starts those
#     units on demand and lets the model look things up with read-only
#     tools: the NixOS and home-manager option reference, this flake as
#     deployed in /etc/nixos, systemd unit state and logs, disk, processes
#     and network state, installed manual pages, the manuals and handbooks
#     stored on the machine, the library, and the operator's notes. It
#     proposes commands; it never runs any that change state.
#
# Two modes. Default mode is the machine as usual. Offline-AI mode (entered by
# `offline-ai`, `offline-ai "question"` or `offline-ai up`) first stops the
# running units listed in evictSystem/evictUser below, then loads the model
# and the library; leaving it (end of the conversation, or `offline-ai down`)
# stops them and starts exactly the units it stopped.
#
#   offline-ai            # offline-AI mode for one conversation
#   offline-ai "how do I stop tailscale until next boot"
#   offline-ai library    # start the library and print where to open it
#   offline-ai library fetch --list   # archives the corpus lists; fetch them
#   offline-ai down       # stop both servers and free the RAM
#   offline-ai help
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
{ config, lib, pkgs, ... }:
let
  home = config.users.users.jonathan.home;
  model = "${home}/.local/share/llm-models/qwen3-coder-next/Qwen3-Coder-Next-Q4_K_M/Qwen3-Coder-Next-Q4_K_M-00001-of-00004.gguf";
  port = 8717;
  unit = "offline-ai-llm.service";
  libraryPort = 8718;
  libraryUnit = "offline-ai-library.service";
  corpus = "${home}/Repos/survival-corpus/corpus";

  # What gives way while the big model is loaded (offline-AI mode). All of it
  # needs the network or only matters online; the microVMs alone can take
  # 7 GiB. Timers come before the services they start, so nothing restarts
  # a service while it is stopped. The CLI stops only those that are running
  # and starts exactly those again when the mode ends.
  evictSystem = [
    "research-agent-healthcheck.timer"
    "scraper-healthcheck.timer"
    "microvm@research-agent.service"
    "microvm@scraper.service"
  ];
  evictUser = [
    "aggregator-ingest.timer"
    "router-ingestor-scan.timer"
    "router-ingestor.service"
    "voquill.service"
    # local-stt.nix: the router first, then the two models behind it (~2 GB).
    "local-stt.service"
    "local-stt-general.service"
    "local-stt-swedish.service"
  ];

  # Document collections the assistant can search, as label=directory. The
  # manuals come from this system's own closure, so they always describe
  # the versions that are installed.
  collections = lib.concatStringsSep ":" [
    "survival=${corpus}/jonathan"
    "survival-more=${corpus}/supplementary"
    "nixos-manual=${config.system.build.manual.manualHTML}/share/doc/nixos"
    "nix-manual=${config.nix.package.doc}/share/doc/nix/manual"
    "nixpkgs-manual=${pkgs.nixpkgs-manual}/share/doc/nixpkgs"
    "home-manager-manual=/etc/profiles/per-user/jonathan/share/doc/home-manager"
  ];

  # kiwix-serve takes the archives as arguments and exits on the first one
  # it cannot open, so a half-downloaded file would take the library down.
  # Each archive is checked first and a bad one is skipped with a message.
  libraryServe = pkgs.writeShellApplication {
    name = "offline-ai-library-serve";
    runtimeInputs = [ pkgs.kiwix-tools pkgs.zim-tools pkgs.coreutils ];
    text = ''
      dir="''${OFFLINE_AI_ZIM_DIR:-${corpus}/kiwix}"
      port="''${OFFLINE_AI_LIBRARY_PORT:-${toString libraryPort}}"
      shopt -s nullglob
      good=()
      for zim in "$dir"/*.zim; do
        if zimdump info -- "$zim" > /dev/null 2>&1; then
          good+=("$zim")
        else
          echo "skipping unreadable archive: $zim" >&2
        fi
      done
      if [ "''${#good[@]}" -eq 0 ]; then
        echo "no readable .zim archive in $dir; fetch some with: offline-ai library fetch" >&2
        exit 1
      fi
      exec kiwix-serve --address 127.0.0.1 --port "$port" "''${good[@]}"
    '';
  };

  # Downloads the archives the survival corpus lists (type: kiwix) into the
  # folder the library serves, verifying each against the mirror's SHA-256.
  libraryFetch = pkgs.writeShellApplication {
    name = "offline-ai-library-fetch";
    runtimeInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ];
    text = ''
      export OFFLINE_AI_SOURCES="''${OFFLINE_AI_SOURCES:-${home}/Repos/survival-corpus/sources.yaml}"
      export OFFLINE_AI_ZIM_DIR="''${OFFLINE_AI_ZIM_DIR:-${corpus}/kiwix}"
      exec python3 ${../../scripts/offline-ai-library-fetch.py} "$@"
    '';
  };

  # Every setting is a default the environment may override; the check in
  # tests/offline-ai.nix points the same wrapper at a stub server.
  offlineAi = pkgs.writeShellApplication {
    name = "offline-ai";
    runtimeInputs = [
      pkgs.python3
      pkgs.poppler-utils
      pkgs.systemd
      pkgs.coreutils
      pkgs.findutils
      pkgs.procps
      pkgs.iproute2
      pkgs.man-db
      libraryFetch
    ];
    text = ''
      export OFFLINE_AI_URL="''${OFFLINE_AI_URL:-http://127.0.0.1:${toString port}}"
      export OFFLINE_AI_UNIT="''${OFFLINE_AI_UNIT:-${unit}}"
      export OFFLINE_AI_MODEL="''${OFFLINE_AI_MODEL:-${model}}"
      export OFFLINE_AI_CONFIG_ROOT="''${OFFLINE_AI_CONFIG_ROOT:-/etc/nixos}"
      export OFFLINE_AI_FLAKE_HOST="''${OFFLINE_AI_FLAKE_HOST:-${config.networking.hostName}}"
      export OFFLINE_AI_NIXOS_OPTIONS="''${OFFLINE_AI_NIXOS_OPTIONS:-${config.system.build.manual.optionsJSON}/share/doc/nixos/options.json}"
      export OFFLINE_AI_HM_OPTIONS="''${OFFLINE_AI_HM_OPTIONS:-/etc/profiles/per-user/jonathan/share/doc/home-manager/options.json}"
      export OFFLINE_AI_DOC_DIRS="''${OFFLINE_AI_DOC_DIRS:-${collections}}"
      export OFFLINE_AI_LIBRARY_URL="''${OFFLINE_AI_LIBRARY_URL:-http://127.0.0.1:${toString libraryPort}}"
      export OFFLINE_AI_LIBRARY_UNIT="''${OFFLINE_AI_LIBRARY_UNIT:-${libraryUnit}}"
      export OFFLINE_AI_EVICT_SYSTEM="''${OFFLINE_AI_EVICT_SYSTEM-${lib.concatStringsSep " " evictSystem}}"
      export OFFLINE_AI_EVICT_USER="''${OFFLINE_AI_EVICT_USER-${lib.concatStringsSep " " evictUser}}"
      exec python3 ${../../scripts/offline-ai.py} "$@"
    '';
  };
in
{
  environment.systemPackages = [ offlineAi libraryFetch ];
  system.build.offline-ai = offlineAi;
  system.build.offline-ai-library-serve = libraryServe;
  system.build.offline-ai-library-fetch = libraryFetch;

  # Installs the home-manager option reference as JSON, and its manual as
  # HTML, into the user profile, which is where the CLI reads them from.
  home-manager.users.jonathan.manual.json.enable = true;
  home-manager.users.jonathan.manual.html.enable = true;

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

  # The CLI runs as jonathan and must stop and start the system units that give
  # way to the model, and nothing else: only these units, only start/stop.
  security.polkit.extraConfig = ''
    polkit.addRule(function (action, subject) {
      if (action.id == "org.freedesktop.systemd1.manage-units" &&
          subject.user == "jonathan" &&
          ${builtins.toJSON evictSystem}.indexOf(action.lookup("unit")) >= 0 &&
          ["start", "stop"].indexOf(action.lookup("verb")) >= 0) {
        return polkit.Result.YES;
      }
    });
  '';

  systemd.user.services.offline-ai-library = {
    description = "offline-ai reference library (kiwix-serve)";
    serviceConfig = {
      ExecStart = "${libraryServe}/bin/offline-ai-library-serve";
      Restart = "no";
    };
  };
}
