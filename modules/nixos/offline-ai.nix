# offline-ai — a local assistant for when the internet is down.
#
# Three pieces:
#   - one user unit per model running llama.cpp's server (the table in
#     `models` below): `offline-ai-llm.service` for the small model, the
#     default, and `offline-ai-llm-coder.service` for the coder. Installed
#     but never started automatically: a model holds 24-48 GiB of RAM, so
#     one runs only while it is wanted, and never both (each unit names the
#     other in Conflicts=, so systemd stops one when the other starts).
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
# running units listed in evictSystem/evictUser below, then loads a model
# and the library; leaving it (end of the conversation, or `offline-ai down`)
# stops them and starts exactly the units it stopped. A run started while
# the mode is on only makes sure its model is the one loaded.
#
#   offline-ai            # offline-AI mode for one conversation
#   offline-ai "how do I stop tailscale until next boot"
#   offline-ai --model coder "the same, when the small model stumbled"
#   offline-ai models     # which model is loaded, which is on disk, the default
#   offline-ai library    # start the library and print where to open it
#   offline-ai library fetch --list   # archives the corpus lists; fetch them
#   offline-ai down       # stop the model and the library, free the RAM
#   offline-ai help       # the whole reference
#
# THE MODELS. Two, both on disk; the CLI loads the small one unless --model
# says otherwise ("why not have offline-ai support both coder and the
# smaller model? With the smaller one being default, and the coder one
# possible in case the smaller one stumbles", 2026-10-03).
#
#   name   unit                          model                       holds   where     context
#   small  offline-ai-llm.service        Qwen3.6-35B-A3B UD-Q4_K_M   24 GiB  iGPU      64k
#   coder  offline-ai-llm-coder.service  Qwen3-Coder-Next Q4_K_M     48 GiB  CPU only  32k
#
# The small one, Qwen3.6-35B-A3B (Unsloth UD-Q4_K_M, 22.7 GB, with its
# multi-token-prediction head), runs the whole of it on the Radeon 890M
# iGPU. Chosen 2026-10-02 as the default over Qwen3-Coder-Next (80B-A3B,
# 46 GB, CPU-only) on measurements from this machine:
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
# The coder stays as the fallback for when the small one stumbles: the
# 80B-A3B model knows more, at 12-13 tok/s on the CPU (46 GB cannot be
# offloaded into the iGPU's 33 GB window) and with half the context, and
# while it is loaded builds run at the minimum budget (memory-pressure.nix:
# 62 GiB of RAM less its 48 GiB reservation and the desktop's share), as
# they did before 2026-10-02. Loading it is the operator's call:
# `offline-ai --model coder up`, or `--model coder` on a question.
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
# THE MODELS ARE NOT IN THE NIX STORE. They are 23 and 46 GB of weights
# fetched once into the home directory; putting them in the store would copy
# them into every closure and every VM test. ConditionPathExists keeps a unit
# inert on a machine that has not fetched its model, and the CLI says how to
# fetch (the `fetch` hints in the table; the small model's:)
#
#   nix shell nixpkgs#python3Packages.huggingface-hub -c hf download \
#     unsloth/Qwen3.6-35B-A3B-GGUF --include 'Qwen3.6-35B-A3B-UD-Q4_K_M.gguf' \
#     --local-dir ~/.local/share/llm-models/qwen3.6-35b-a3b-mtp
{ config, lib, pkgs, ... }:
let
  home = config.users.users.jonathan.home;
  modelsDir = "${home}/.local/share/llm-models";
  gib = 1024 * 1024 * 1024;
  port = 8717;
  # The model table: name -> its unit, its weights, its memory reservation
  # (memory-pressure.nix names the unit memory-reserve-<reservation>.service
  # and keeps /run/memory-reserve/<reservation> while it is active), what the
  # reservation holds, llama-server's flags, one line for `offline-ai help`,
  # and how to fetch the weights. Adding a model is adding a row.
  models = {
    small = {
      unit = "offline-ai-llm.service";
      model = "${modelsDir}/qwen3.6-35b-a3b-mtp/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf";
      reservation = "offline-ai";
      # The weights (22.7 GB, pinned in GTT while on the iGPU), the 64k
      # context and the compute buffers.
      bytes = 24 * gib;
      # -np 1: one conversation at a time, so the whole 64k context belongs
      # to it instead of being divided between server slots. -ngl 99 and
      # --spec-type draft-mtp: see the header; both need this model.
      # --reasoning-budget 8192: this is a thinking model, and left alone it
      # once thought through the last 16k tokens of its context on a
      # first-aid question and had nothing left for the answer (bench
      # 2026-10-02-small-v3, q10). 8k of thought is plenty for a step-by-step
      # answer; the CLI reports a cut-off answer if it still happens.
      flags = "-ngl 99 -t 8 -c 65536 -np 1 --jinja -fa on --spec-type draft-mtp --reasoning-budget 8192";
      about = "Qwen3.6-35B-A3B, 23 GB, on the iGPU, 64k context: the one to use";
      fetch = "nix shell nixpkgs#python3Packages.huggingface-hub -c hf download unsloth/Qwen3.6-35B-A3B-GGUF --include 'Qwen3.6-35B-A3B-UD-Q4_K_M.gguf' --local-dir ~/.local/share/llm-models/qwen3.6-35b-a3b-mtp (23 GB)";
    };
    coder = {
      unit = "offline-ai-llm-coder.service";
      # Four parts; llama-server takes the first and finds the rest.
      model = "${modelsDir}/qwen3-coder-next/Qwen3-Coder-Next-Q4_K_M/Qwen3-Coder-Next-Q4_K_M-00001-of-00004.gguf";
      reservation = "offline-ai-coder";
      # 46 GB of weights in RAM (-ngl 0: it does not fit the iGPU), the 32k
      # context and the compute buffers.
      bytes = 48 * gib;
      flags = "-ngl 0 -t 8 -c 32768 -np 1 --jinja -fa on";
      about = "Qwen3-Coder-Next, 46 GB, CPU-only (about 12 tok/s), 32k context: the fallback when the small one stumbles";
      fetch = "nix shell nixpkgs#python3Packages.huggingface-hub -c hf download Qwen/Qwen3-Coder-Next-GGUF --include 'Qwen3-Coder-Next-Q4_K_M/*' --local-dir ~/.local/share/llm-models/qwen3-coder-next (46 GB)";
    };
  };
  defaultModel = "small";
  default = models.${defaultModel};
  reservationUnit = m: "memory-reserve-${m.reservation}.service";
  # While a model is loaded its marker exists (memory-pressure.nix creates it
  # for the reservation); the services that gave way to the model refuse to
  # start while any marker does, so a deploy or a timer cannot bring them
  # back into the memory a model is holding. restore() runs after the
  # reservation ends, so it still starts them.
  markerOf = m: "/run/memory-reserve/${m.reservation}";
  markers = map markerOf (lib.attrValues models);
  # The table as the CLI reads it, with the derived names filled in. A file,
  # read at startup: JSON inlined in the wrapper would be a quoted string
  # shellcheck refuses (SC2089).
  modelsFile = pkgs.writeText "offline-ai-models.json" (builtins.toJSON (lib.mapAttrs (_: m: {
    inherit (m) unit model about fetch;
    reservation = reservationUnit m;
    marker = markerOf m;
  }) models));
  libraryPort = 8718;
  libraryUnit = "offline-ai-library.service";
  corpus = "${home}/Repos/survival-corpus/corpus";

  # What gives way while the model is loaded (offline-AI mode). All of it
  # needs the network or only matters online; the microVMs alone can take
  # 7 GiB. Timers come before the services they start, so nothing restarts
  # a service while it is stopped. The CLI stops only those that are running
  # and starts exactly those again when the mode ends. The services also
  # carry ConditionPathExists=!<marker>, one line per model (below), because a
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
    "aggregator-ingest.service"
    "aggregator-embed.service"
    "aggregator-embed-server.service"
    "router-ingestor.service"
    "router-ingestor-scan.service"
    "voquill.service"
    "local-stt.service"
    "local-stt-general.service"
    "local-stt-swedish.service"
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
      # The default model alone, as the smoke test and a run without the
      # table read it; the table itself follows.
      export OFFLINE_AI_UNIT="''${OFFLINE_AI_UNIT:-${default.unit}}"
      export OFFLINE_AI_MODEL="''${OFFLINE_AI_MODEL:-${default.model}}"
      export OFFLINE_AI_CONFIG_ROOT="''${OFFLINE_AI_CONFIG_ROOT:-/etc/nixos}"
      export OFFLINE_AI_FLAKE_HOST="''${OFFLINE_AI_FLAKE_HOST:-${config.networking.hostName}}"
      export OFFLINE_AI_NIXOS_OPTIONS="''${OFFLINE_AI_NIXOS_OPTIONS:-${config.system.build.manual.optionsJSON}/share/doc/nixos/options.json}"
      export OFFLINE_AI_HM_OPTIONS="''${OFFLINE_AI_HM_OPTIONS:-/etc/profiles/per-user/jonathan/share/doc/home-manager/options.json}"
      export OFFLINE_AI_DOC_DIRS="''${OFFLINE_AI_DOC_DIRS:-${collections}}"
      export OFFLINE_AI_LIBRARY_URL="''${OFFLINE_AI_LIBRARY_URL:-http://127.0.0.1:${toString libraryPort}}"
      export OFFLINE_AI_LIBRARY_UNIT="''${OFFLINE_AI_LIBRARY_UNIT:-${libraryUnit}}"
      export OFFLINE_AI_MODE_MARKER="''${OFFLINE_AI_MODE_MARKER:-${markerOf default}}"
      export OFFLINE_AI_RESERVATION="''${OFFLINE_AI_RESERVATION:-${reservationUnit default}}"
      export OFFLINE_AI_MODELS="''${OFFLINE_AI_MODELS:-$(cat ${modelsFile})}"
      export OFFLINE_AI_DEFAULT_MODEL="''${OFFLINE_AI_DEFAULT_MODEL:-${defaultModel}}"
      export OFFLINE_AI_EVICT_SYSTEM="''${OFFLINE_AI_EVICT_SYSTEM-${lib.concatStringsSep " " evictSystem}}"
      export OFFLINE_AI_EVICT_USER="''${OFFLINE_AI_EVICT_USER-${lib.concatStringsSep " " evictUser}}"
      exec python3 ${../../scripts/offline-ai.py} "$@"
    '';
  };

  # Weekly smoke test: loads the model through the CLI above, asks one question,
  # records the verdict, shouts only on failure. Runs from a user timer; see
  # docs/superpowers/specs/2026-10-03-offline-ai-smoke-design.md. Everything it
  # calls is found on PATH so tests/offline-ai-smoke.nix can stand in fakes.
  smoke = pkgs.writeShellApplication {
    name = "offline-ai-smoke";
    runtimeInputs = [
      pkgs.python3
      pkgs.coreutils
      pkgs.systemd
      pkgs.xprintidle
      pkgs.libnotify
      offlineAi
      config.services.buildCoordination.runnerPackage
    ];
    text = ''
      export OFFLINE_AI_UNIT="''${OFFLINE_AI_UNIT:-${default.unit}}"
      exec python3 ${../../scripts/offline-ai-smoke.py} "$@"
    '';
  };
in
{
  environment.systemPackages = [ offlineAi libraryFetch ];
  system.build.offline-ai = offlineAi;
  system.build.offline-ai-smoke = smoke;
  system.build.offline-ai-library-serve = libraryServe;
  system.build.offline-ai-library-fetch = libraryFetch;

  # Installs the home-manager option reference as JSON, and its manual as
  # HTML, into the user profile, which is where the CLI reads them from.
  home-manager.users.jonathan.manual.json.enable = true;
  home-manager.users.jonathan.manual.html.enable = true;

  # What a model holds while its server runs (the table). Builds shrink to
  # what is left (memory-pressure.nix) so they cannot evict it. One
  # reservation per model; the units never run together, so at most one is
  # active.
  services.memoryPressure.reservations =
    lib.mapAttrs' (_: m: lib.nameValuePair m.reservation m.bytes) models;

  systemd.user.services = lib.mapAttrs' (name: m: lib.nameValuePair (lib.removeSuffix ".service" m.unit) {
    description = "offline-ai local model server (llama.cpp, the ${name} model)";
    unitConfig.ConditionPathExists = m.model;
    # Starting this model stops any other: never two loaded, enforced by
    # systemd below the CLI (which stops the other first anyway, so its
    # memory arithmetic sees that memory free).
    conflicts = map (o: o.unit) (lib.attrValues (lib.filterAttrs (other: _: other != name) models));
    serviceConfig = {
      # "-": failing to shrink the build cap should not keep the assistant
      # from answering during an outage. ExecStopPost also runs after a
      # crash or a failed start, so the reservation never outlives the model.
      ExecStartPre = "-${pkgs.systemd}/bin/systemctl start ${reservationUnit m}";
      ExecStopPost = "-${pkgs.systemd}/bin/systemctl stop ${reservationUnit m}";
      ExecStart = "${pkgs.llama-cpp-vulkan}/bin/llama-server -m ${m.model} ${m.flags} --host 127.0.0.1 --port ${toString port}";
      # Wins the CPU against the rest of the desktop while it answers; see
      # the header. The cpu controller is delegated to the user manager, so
      # the weight applies between this unit and every app scope beside it.
      CPUWeight = 1000;
      Restart = "no";
    };
  }) models // {
    offline-ai-library = {
      description = "offline-ai reference library (kiwix-serve)";
      serviceConfig = {
        ExecStart = "${libraryServe}/bin/offline-ai-library-serve";
        Restart = "no";
      };
    };

    # Weekly smoke: a nightly opportunity. The script skips while the last pass is
    # younger than six days, outside 01-07 local time (a timer that elapsed during
    # suspend fires at resume, which would otherwise mean mid-day), on battery, while
    # the user is active, or while a build holds nix-memory-run; Persistent catches
    # up after a night powered off. DISPLAY/DBUS as autodoro does: xprintidle needs
    # the X server and notify-send the session bus. It takes the default model.
    offline-ai-smoke = {
      description = "offline-ai weekly smoke test (loads the model, asks one question)";
      unitConfig.ConditionPathExists = default.model;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${smoke}/bin/offline-ai-smoke";
        # 2 h idle wait + 1 h lock wait + 10 min run + 15 min down, with margin. The
        # script records an abort if this still runs out.
        TimeoutStartSec = "4h";
        # On stop the CLI leaves offline mode (restarting what it evicted); let it.
        TimeoutStopSec = "15min";
        Environment = [
          "DISPLAY=:0"
          "DBUS_SESSION_BUS_ADDRESS=unix:path=%t/bus"
        ];
      };
    };
  };

  # While a model holds its memory, what gave way for it stays down even if
  # a deploy or a timer tries to start it; see evictSystem/evictUser. One
  # condition per model's marker: a unit refuses while any of them stands.
  home-manager.users.jonathan.xdg.configFile = lib.listToAttrs (map (unit:
    lib.nameValuePair "systemd/user/${unit}.d/offline-ai.conf" {
      text = "[Unit]\n" + lib.concatMapStrings (marker: "ConditionPathExists=!${marker}\n") markers;
    }) gatedUserServices);
  systemd.services = lib.genAttrs gatedSystemServices (_: {
    # A list, so it joins the template's own ConditionPathExists instead of
    # replacing it (the instance units are drop-ins over microvm@.service).
    unitConfig.ConditionPathExists = map (marker: "!${marker}") markers;
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

  systemd.user.timers.offline-ai-smoke = {
    description = "offline-ai weekly smoke test, nightly opportunity";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:33:00";
      RandomizedDelaySec = "20min";
      Persistent = true;
    };
  };
}
