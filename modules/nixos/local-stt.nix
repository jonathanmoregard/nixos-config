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
# Swedish audio is transcribed a second time by kb-whisper. Short English
# dictations come back in ~1.3 s, as fast as the cloud service they replace.
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
{ config, pkgs, ... }:
let
  models = "${config.users.users.jonathan.home}/.local/share/stt-models";
  generalModel = "${models}/whisper.cpp/ggml-large-v3-turbo-q8_0.bin";
  swedishModel = "${models}/kb-whisper-large/ggml-model-q5_0.bin";
  port = 8766; # 8765 is the aggregator MCP backend
  generalPort = 8763;
  swedishPort = 8764;

  # The iGPU does the work; the CPU threads only feed it.
  whisperServer = { model, port, language }:
    "${pkgs.whisper-cpp-vulkan}/bin/whisper-server -m ${model} --host 127.0.0.1"
    + " --port ${toString port} -l ${language} -t 4";

  backend = { description, model, port, language }: {
    inherit description;
    wantedBy = [ "default.target" ];
    unitConfig.ConditionPathExists = model;
    serviceConfig = {
      ExecStart = whisperServer { inherit model port language; };
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
  };

  systemd.user.services.local-stt-swedish = backend {
    description = "local-stt: kb-whisper-large (Swedish)";
    model = swedishModel;
    port = swedishPort;
    language = "sv";
  };

  systemd.user.services.local-stt = {
    description = "local-stt: OpenAI-compatible transcription endpoint";
    wantedBy = [ "default.target" ];
    wants = [ "local-stt-general.service" "local-stt-swedish.service" ];
    after = [ "local-stt-general.service" "local-stt-swedish.service" ];
    environment = {
      LOCAL_STT_PORT = toString port;
      LOCAL_STT_GENERAL = "http://127.0.0.1:${toString generalPort}";
      LOCAL_STT_SWEDISH = "http://127.0.0.1:${toString swedishPort}";
    };
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/local-stt-router.py}";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };
}
