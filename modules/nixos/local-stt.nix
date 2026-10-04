# local-stt — speech-to-text on this machine's iGPU, for Voquill.
#
# Three user units:
#   - `local-stt-general.service`: whisper.cpp's server with
#     whisper-large-v3-turbo, used for English (and anything not Swedish) and
#     to detect the language of every request.
#   - `local-stt-swedish.service`: the same server with KBLab's
#     kb-whisper-large, used for Swedish.
#   - `local-stt.service`: a small router (scripts/local-stt-router.py) that
#     speaks the OpenAI transcription API on http://127.0.0.1:8766/v1 and sends
#     each request to the right model. Point Voquill's "OpenAI Compatible"
#     transcription provider at that URL.
#
# WHY TWO MODELS. Measured on this machine 2026-10-01 (whisper.cpp 1.9.2,
# Vulkan on the Radeon 890M) against 20 real Voquill dictations, 10 Swedish
# sentences with exact reference text, and five minutes of real Swedish speech:
#   - turbo: 5.0% word error on English (against the cloud transcripts), 5.7%
#     on the Swedish sentences, but on real Swedish speech it repeated one
#     phrase nine times and invented sentences that were never said;
#   - kb-whisper: 5.3% on the Swedish sentences and clearly the best on real
#     Swedish, but it answers English speech in Swedish, even when told the
#     audio is English, so it cannot be the only model;
#   - Parakeet TDT v3: fastest, but 7.2% on English and 12.3% on Swedish.
# Turbo detects the language with ~0.998 confidence, so it answers first and
# Swedish audio is transcribed a second time by kb-whisper.
#
# Whisper encodes a padded 30-second window whatever the clip length, so a
# 3-second dictation costs as much as a 30-second one. A second turbo server
# keeps a 15-second window (-ac 768) and answers clips of up to 14 s: on 12
# real clips the words were the same (punctuation varied on four, a 1-second
# "test" came back as "testing") and the round trip fell from ~1.9 s to
# ~0.9 s (2026-10-03, with the cloud service at ~0.9 s). One server cannot do
# both, since changing its window between requests costs seconds. Longer
# clips, and every Swedish re-transcription, keep the full window.
#
# THE MODELS ARE NOT IN THE NIX STORE (2 GB; same reasoning as offline-ai.nix).
# ConditionPathExists keeps a unit inert until its file is fetched, pinned to
# the revisions measured above:
#
#   nix shell nixpkgs#python3Packages.huggingface-hub -c sh -c '
#     mkdir -p ~/.local/share/stt-models && cd ~/.local/share/stt-models &&
#     hf download ggerganov/whisper.cpp ggml-large-v3-turbo-q8_0.bin \
#       --revision 5359861c739e955e79d9a303bcbc70fb988958b1 --local-dir whisper.cpp &&
#     hf download KBLab/kb-whisper-large ggml-model-q5_0.bin \
#       --revision d5d5984b4d8f7c4847a8ea203f1976285fb28300 --local-dir kb-whisper-large'
#
# Offline-AI mode (offline-ai.nix) stops these units while the big model is
# loaded and starts them again afterwards.
#
# PRIORITY. A dictation is a one-second burst that competes with whatever
# else runs in this user's session (nix evaluations, builds, the embedding
# backfill). The four units carry CPUWeight=1000 against the default 100, so
# under contention the scheduler gives them ten shares to every other
# sibling's one; ram-heavy.slice (memory-pressure.nix) sits at 50 and
# nix-daemon runs batch/idle (build-coordination.nix). IOWeight=1000 states
# the same intent for IO; the user manager is delegated cpu, memory and pids
# only, so it takes effect once io is delegated too. Measured 2026-10-03
# with a 24-process CPU hog in a default-weight scope: the weight alone buys
# nothing against a saturating hog (the loss is wake-up latency, not share),
# the hog's own policy does — SCHED_BATCH or SCHED_IDLE on the hog leaves the
# dictation at its unloaded latency. Hence nix-daemon's batch policy.
#
# RECORD-START BOOST. The router answers GET|POST /v1/prepare with 204 and
# holds the `performance` power profile for 30 s through powerprofilesctl
# (one hold at a time) while touching ai-throttle's foreground hint, so the
# background units pause at once; every transcription takes the same boost
# inline. Voquill pings /v1/prepare when a recording starts.
#
# DEPLOYS. A NixOS switch that changes these unit files restarts them, and a
# dictation may be in flight: 2026-10-04 switch-to-configuration's user-unit
# pass stopped all four and started them again half a second later, the
# router died with a request in hand and the dictation was lost. (Voquill
# itself is a home-manager unit and is kept across switches there, see
# home/router-services.nix.) Three things make a restart invisible to the
# caller, each exercised by tests/local-stt-switch.nix under a real switch:
#   - `local-stt.socket` owns the listening socket and hands it to each
#     router process, so the port stays open between two processes and a
#     request that arrives then waits in the socket's queue;
#   - the router, told to stop, takes nothing new and finishes the requests
#     it holds before it exits (bounded by TimeoutStopSec = drainSeconds);
#   - a request that finds a whisper server gone waits for it to come back
#     (backendWaitSeconds) and sends the audio again.
# All four units are restarted (stopIfChanged = false), not stopped and
# started: switch-to-configuration stops stop-and-start units before it
# restarts the others and starts them only after those restarts have
# finished, so a router finishing a request would wait on whisper servers
# that cannot come back until it is done. For the same reason the router is
# not ordered After= the whisper servers: systemd would hold their start
# until the router had stopped. The router needs no such order; it waits for
# a server that is not listening yet.
{ config, lib, pkgs, ... }:
let
  models = "${config.users.users.jonathan.home}/.local/share/stt-models";
  generalModel = "${models}/whisper.cpp/ggml-large-v3-turbo-q8_0.bin";
  swedishModel = "${models}/kb-whisper-large/ggml-model-q5_0.bin";
  port = 8766; # 8765 is the aggregator MCP backend
  generalPort = 8763;
  swedishPort = 8764;
  generalShortPort = 8762;
  # Encoder frames of the short server's window: 768 of the full 1500 = 15.36 s.
  # The router sends it clips of at most shortSeconds, one second under the
  # window so nothing is chunked; the two numbers stay tied here.
  shortAudioCtx = 768;
  shortSeconds = builtins.floor (shortAudioCtx * 30.0 / 1500) - 1;
  # A short server that accepts but does not answer within this many seconds
  # is given up on and the clip goes to the full-window one (a short clip
  # takes ~1 s; Voquill waits far less than whisper-server's 600 s).
  shortTimeoutSeconds = 20;
  # A request waits this long for a whisper server that is not there to come
  # back before the router falls back or answers 502 (a restart takes the
  # second or two the model needs to load; a server that stays away for the
  # whole wait is then asked once per request until it answers again).
  backendWaitSeconds = 30;
  # How long a stopping router may take to finish the requests in flight
  # before systemd kills it. A switch waits for it, so this is also the most
  # a deploy can be held up. It has to cover a request that waits for two
  # servers in turn (Swedish audio: detection, then kb-whisper) and is then
  # transcribed, hence the assertion below.
  drainSeconds = 90;
  # A client that connects and then says nothing is dropped after this long,
  # so it cannot hold a stopping router (and the requests queued behind the
  # restart) for the whole drain.
  clientIdleSeconds = 5;

  # Ten shares to every default sibling's one, for the burst a dictation is.
  priority = {
    CPUWeight = 1000;
    IOWeight = 1000;
  };

  # The iGPU does the work; the CPU threads only feed it. -nf on the turbo
  # servers: no temperature fallback, so an uncertain decode is not re-run at
  # rising temperatures; 2026-10-03 that changed no text on 20 real clips and
  # removes the slow outliers. kb-whisper keeps the fallback: it is whisper's
  # guard against looping on real Swedish speech, which no bench here could
  # judge (no real Swedish audio), and it bought Swedish no measured speed.
  whisperServer = { model, port, language, audioCtx ? null, noFallback ? false }:
    "${pkgs.whisper-cpp-vulkan}/bin/whisper-server -m ${model} --host 127.0.0.1"
    + " --port ${toString port} -l ${language} -t 4"
    + lib.optionalString noFallback " -nf"
    + lib.optionalString (audioCtx != null) " -ac ${toString audioCtx}";

  backend = { description, model, port, language, audioCtx ? null, noFallback ? false }: {
    inherit description;
    wantedBy = [ "default.target" ];
    # Restarted in the same pass as the router, see DEPLOYS above. A request
    # the server had in hand and did not answer before it stopped is sent
    # again by the router.
    stopIfChanged = false;
    unitConfig.ConditionPathExists = model;
    serviceConfig = priority // {
      ExecStart = whisperServer { inherit model port language audioCtx noFallback; };
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
in
{
  systemd.user.services.local-stt-general = backend {
    description = "local-stt: whisper-large-v3-turbo (English, language detection)";
    model = generalModel;
    port = generalPort;
    language = "auto";
    noFallback = true;
  };

  systemd.user.services.local-stt-general-short = backend {
    description = "local-stt: whisper-large-v3-turbo, 15-second window (clips up to ${toString shortSeconds} s)";
    model = generalModel;
    port = generalShortPort;
    language = "auto";
    audioCtx = shortAudioCtx;
    noFallback = true;
  };

  systemd.user.services.local-stt-swedish = backend {
    description = "local-stt: kb-whisper-large (Swedish)";
    model = swedishModel;
    port = swedishPort;
    language = "sv";
  };

  assertions = [{
    assertion = drainSeconds > 2 * backendWaitSeconds;
    message = "local-stt: drainSeconds (${toString drainSeconds}) must exceed twice backendWaitSeconds "
      + "(${toString backendWaitSeconds}), or a request waiting for a restarting whisper server is "
      + "killed with the router before it can be answered.";
  }];

  # The endpoint's listening socket, held by systemd and handed to whichever
  # router process runs: the port stays open across the router's restarts.
  # A switch does not touch a changed .socket unit, so a new port takes
  # effect at the next login.
  systemd.user.sockets.local-stt = {
    description = "local-stt: listening socket of the transcription endpoint";
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "127.0.0.1:${toString port}" ];
  };

  systemd.user.services.local-stt = {
    description = "local-stt: OpenAI-compatible transcription endpoint";
    # Started at login rather than on the first connection, so the first
    # dictation does not pay for the router's start.
    wantedBy = [ "default.target" ];
    requires = [ "local-stt.socket" ];
    after = [ "local-stt.socket" ];
    wants = [ "local-stt-general.service" "local-stt-general-short.service" "local-stt-swedish.service" ];
    # Restarted, never stopped and started: the socket stays, the old process
    # finishes what it holds. See DEPLOYS above.
    stopIfChanged = false;
    environment = {
      LOCAL_STT_PORT = toString port;
      LOCAL_STT_GENERAL = "http://127.0.0.1:${toString generalPort}";
      LOCAL_STT_GENERAL_SHORT = "http://127.0.0.1:${toString generalShortPort}";
      LOCAL_STT_SHORT_SECONDS = toString shortSeconds;
      LOCAL_STT_SHORT_TIMEOUT = toString shortTimeoutSeconds;
      LOCAL_STT_SWEDISH = "http://127.0.0.1:${toString swedishPort}";
      # The record-start boost's two side channels: power-profiles-daemon's
      # client (the daemon itself is the desktop's), and the hint file the
      # governor reads, the one path for both so they cannot drift.
      LOCAL_STT_POWERPROFILESCTL = "${pkgs.power-profiles-daemon}/bin/powerprofilesctl";
      LOCAL_STT_NICE = "${pkgs.coreutils}/bin/nice";
      LOCAL_STT_THROTTLE_HINT = config.services.aiThrottle.foregroundHint;
      LOCAL_STT_BACKEND_WAIT = toString backendWaitSeconds;
      LOCAL_STT_CLIENT_IDLE = toString clientIdleSeconds;
    };
    serviceConfig = priority // {
      ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/local-stt-router.py}";
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStopSec = drainSeconds;
    };
  };
}
