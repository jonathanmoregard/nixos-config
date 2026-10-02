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
# THE MODEL AND WHERE IT RUNS. Qwen3.6-35B-A3B (Unsloth UD-Q4_K_M, 22.7 GB,
# with its multi-token-prediction head), the whole of it on the Radeon 890M
# iGPU. Chosen 2026-10-02 over Qwen3-Coder-Next (80B-A3B, 46 GB, CPU-only)
# on measurements from this machine:
#   - it fits the iGPU's 33 GB GTT window, so every layer goes there
#     (-ngl 99) and the MTP head drafts tokens (--spec-type draft-mtp,
#     60-80% of drafts accepted). Served that way under the desktop's normal
#     load: prompt 236-281 tok/s and generation 18-23 tok/s, against 148-153
#     and 12-13 for the same model CPU-only — 1.5-1.8x end to end. The 46 GB
#     model cannot be offloaded and measured 12-13 tok/s on CPU (2026-09-30).
#   - half the memory: 23 GB resident instead of 46, so less of the desktop
#     has to give way for it (make_room in scripts/offline-ai.py).
#   - it answered the same 13-ask test set as well: 10 good, 2 partial,
#     every medical answer cited its stored pages (bench 2026-10-02-small-v3).
#   - 64k of context instead of 32k. The model is hybrid attention (10 of 40
#     layers keep a KV cache), so the extra context costs ~0.7 GB; the
#     CLI's tool-output budget is what keeps conversations inside it.
#
# WHAT MAKES IT SLOW IS THE REST OF THE MACHINE. Measured 2026-10-02
# (llama-bench tg64): 13-14 tok/s CPU-only with the box quiet, 6-7 tok/s
# with a cargo build or a busy Chrome tab running, 2-4 tok/s while memory
# was short and the weights were being re-read from disk. Two things in
# the unit below follow from that:
#   - CPUWeight=1000. The server's threads spin while they wait for each
#     other, so one stolen core stalls every token; at the default weight
#     of 100 the model shares the CPU equally with every tab and build.
#     With weight 1000, two busy threads and another session's build
#     alongside: 12.9 tok/s against 5.8 at the default weight (iGPU path),
#     6.8 against 3.5 (CPU path). nice does not help: it only ranks
#     processes inside one cgroup, and every app scope is its own.
#   - -t 8, not 12. The chip has 4 Zen 5 and 8 Zen 5c cores; 12 threads
#     leave nothing for the rest of the desktop and are no faster when it
#     is idle (13.2 tok/s at 12 threads, 14.4 at 8, 14.1 at 4). On the iGPU
#     path the threads only feed the GPU, and 8 still leaves the desktop
#     responsive.
#
# THE MODEL IS NOT IN THE NIX STORE. It is 23 GB of weights fetched once
# into the home directory; putting it in the store would copy it into every
# closure and every VM test. ConditionPathExists keeps the unit inert on a
# machine that has not fetched it, and the CLI says how to fetch:
#
#   nix shell nixpkgs#python3Packages.huggingface-hub -c hf download \
#     unsloth/Qwen3.6-35B-A3B-GGUF --include 'Qwen3.6-35B-A3B-UD-Q4_K_M.gguf' \
#     --local-dir ~/.local/share/llm-models/qwen3.6-35b-a3b-mtp
{ config, lib, pkgs, ... }:
let
  home = config.users.users.jonathan.home;
  model = "${home}/.local/share/llm-models/qwen3.6-35b-a3b-mtp/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf";
  # While the model is loaded this path exists (memory-pressure.nix creates
  # it for the reservation below); the services that gave way to the model
  # refuse to start while it does, so a deploy or a timer cannot bring them
  # back into the memory the model is holding. restore() runs after the
  # reservation ends, so it still starts them.
  modeMarker = "/run/memory-reserve/offline-ai";
  port = 8717;
  unit = "offline-ai-llm.service";
  libraryPort = 8718;
  libraryUnit = "offline-ai-library.service";
  corpus = "${home}/Repos/survival-corpus/corpus";

  # What gives way while the model is loaded (offline-AI mode). All of it
  # needs the network or only matters online; the microVMs alone can take
  # 7 GiB. Timers come before the services they start, so nothing restarts
  # a service while it is stopped. The CLI stops only those that are running
  # and starts exactly those again when the mode ends. The services also
  # carry ConditionPathExists=!${modeMarker} (below), because a
  # `nixos-rebuild switch` restarts every enabled unit it finds stopped and
  # a timer tick starts its service: measured 2026-10-02, a deploy brought
  # the embed server back into the model's memory three minutes after it
  # had given way.
  evictSystem = [
    "research-agent-healthcheck.timer"
    "scraper-healthcheck.timer"
    "microvm@research-agent.service"
    "microvm@scraper.service"
  ];
  evictUser = [
    "aggregator-ingest.timer"
    # The embed timer first: its worker Wants= the embed server and would
    # start it again on the next tick.
    "aggregator-embed.timer"
    "router-ingestor-scan.timer"
    "router-ingestor.service"
    "voquill.service"
    # The embed worker, then the llama-server it talks to (iGPU; it has held
    # 15 GB of GTT after a big batch, which is what thrashed the model).
    "aggregator-embed.service"
    "aggregator-embed-server.service"
    # local-stt.nix: the router first, then the two models behind it (~2 GB).
    "local-stt.service"
    "local-stt-general.service"
    "local-stt-swedish.service"
  ];
  # The services above (not the timers: their services carry the condition)
  # plus the scan the router timer fires. All home-manager units, so the
  # condition goes in as a drop-in beside each unit file; a drop-in appends
  # to any ConditionPathExists= the unit already has.
  gatedUserServices = [
    "aggregator-embed.service"
    "aggregator-embed-server.service"
    "router-ingestor.service"
    "router-ingestor-scan.service"
    "voquill.service"
  ];
  gatedSystemServices = [ "microvm@research-agent" "microvm@scraper" ];

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

  # The model's weights (22.7 GB, pinned in GTT while on the iGPU), its 64k
  # context and compute buffers, held while the server runs. Builds shrink
  # to what is left (memory-pressure.nix) so they cannot evict it.
  services.memoryPressure.reservations.offline-ai = 24 * 1024 * 1024 * 1024;

  systemd.user.services.offline-ai-llm = {
    description = "offline-ai local model server (llama.cpp)";
    unitConfig.ConditionPathExists = model;
    serviceConfig = {
      # "-": failing to shrink the build cap should not keep the assistant
      # from answering during an outage. ExecStopPost also runs after a
      # crash or a failed start, so the reservation never outlives the model.
      ExecStartPre = "-${pkgs.systemd}/bin/systemctl start memory-reserve-offline-ai.service";
      ExecStopPost = "-${pkgs.systemd}/bin/systemctl stop memory-reserve-offline-ai.service";
      # -np 1: one conversation at a time, so the whole 64k context belongs
      # to it instead of being divided between server slots. -ngl 99 and
      # --spec-type draft-mtp: see the header; both need this model.
      # --reasoning-budget 8192: this is a thinking model, and left alone it
      # once thought through the last 16k tokens of its context on a
      # first-aid question and had nothing left for the answer (bench
      # 2026-10-02-small-v3, q10). 8k of thought is plenty for a step-by-step
      # answer; the CLI reports a cut-off answer if it still happens.
      ExecStart = "${pkgs.llama-cpp-vulkan}/bin/llama-server -m ${model} -ngl 99 -t 8 -c 65536 -np 1 --jinja -fa on --spec-type draft-mtp --reasoning-budget 8192 --host 127.0.0.1 --port ${toString port}";
      # Wins the CPU against the rest of the desktop while it answers; see
      # the header. The cpu controller is delegated to the user manager, so
      # the weight applies between this unit and every app scope beside it.
      CPUWeight = 1000;
      Restart = "no";
    };
  };

  # While the model holds its memory, what gave way for it stays down even
  # if a deploy or a timer tries to start it; see evictSystem/evictUser.
  home-manager.users.jonathan.xdg.configFile = lib.listToAttrs (map (unit:
    lib.nameValuePair "systemd/user/${unit}.d/offline-ai.conf" {
      text = ''
        [Unit]
        ConditionPathExists=!${modeMarker}
      '';
    }) gatedUserServices);
  systemd.services = lib.genAttrs gatedSystemServices (_: {
    # A list, so it joins the template's own ConditionPathExists instead of
    # replacing it (the instance units are drop-ins over microvm@.service).
    unitConfig.ConditionPathExists = [ "!${modeMarker}" ];
  });

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
