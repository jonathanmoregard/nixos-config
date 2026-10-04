# stt-corpus — keeps the operator's own dictations as a local test corpus.
#
# Voquill stores the audio of its newest 20 transcriptions and deletes the
# rest. Changes to the dictation path (modules/nixos/local-stt.nix) are tested
# end to end on real dictations, so each clip is copied, with the database
# row that describes it (the transcript it produced, its length, which engine
# answered), into `dir` before Voquill prunes it:
#
#   <dir>/voquill/<id>.wav
#   <dir>/voquill-manifest.jsonl   one JSON object per clip
#
# WHAT THIS STORES, AND WHERE. Recordings of the operator's voice and the
# text they were transcribed to. They stay on this machine, in a folder only
# its owner can read; nothing here opens a network connection, and nothing
# else in this repository reads the folder. At most `maxClips` are kept (the
# operator's number, 2026-10-04); beyond that the oldest go, file and manifest
# line both. Deleting the folder is always safe: the next run starts over with
# whatever Voquill still has.
#
# Voquill's database and audio folder are only ever read. A database that is
# locked, missing or being written is no failure: the run ends quietly and
# the next one picks the clips up.
#
# WHEN IT RUNS. Three units, the pattern of klaffat-dependabot-caretaker-ready:
#   - `stt-corpus-keep.path` watches Voquill's audio folder and starts the
#     service whenever a file appears or goes. After a transcription Voquill
#     writes the recording, then its row, then deletes the audio beyond its
#     newest 20; a run started by the new file can come before the row, but
#     then the next event (or dictation) brings the clip in, nineteen
#     dictations before Voquill would delete it.
#   - `stt-corpus-keep.timer` runs it every `sweepInterval` as well, which
#     picks up a clip whose row came after the last file event, and anything
#     an event missed (events that arrive while the service runs are not
#     replayed).
#   - `stt-corpus-keep.service` is the copy itself, a moment of work at idle
#     CPU and IO priority, so it takes nothing from a dictation that happens
#     to run. It is not on the dictation path; Voquill and the router neither
#     know of it nor wait for it.
{ config, lib, pkgs, ... }:
let
  cfg = config.services.sttCorpus;
in
{
  options.services.sttCorpus = {
    maxClips = lib.mkOption {
      type = lib.types.ints.positive;
      default = 400;
      description = "Most dictation clips kept; beyond it the oldest are dropped, file and manifest line.";
    };
    dir = lib.mkOption {
      type = lib.types.str;
      default = "%h/.local/share/stt-corpus";
      description = "The corpus folder (mode 0700). systemd specifiers apply (%h is the home directory).";
    };
    voquillDb = lib.mkOption {
      type = lib.types.str;
      default = "%h/.config/com.voquill.desktop.local/voquill.db";
      description = "Voquill's sqlite database, opened read-only. systemd specifiers apply.";
    };
    voquillAudioDir = lib.mkOption {
      type = lib.types.str;
      default = "%h/.local/share/com.voquill.desktop.local/transcription-audio";
      description = "The folder Voquill writes its recordings to; a change in it starts the keeper. systemd specifiers apply.";
    };
    sweepInterval = lib.mkOption {
      type = lib.types.str;
      default = "15min";
      description = "How long after one run the timer starts the next (a systemd time span).";
    };
  };

  config = {
    systemd.user.services.stt-corpus-keep = {
      description = "Keep Voquill's dictation clips in the local STT test corpus";
      # Every recording starts a run, and a few short dictations in a row
      # are more than systemd's default of 5 starts in 10 s. Hitting that
      # limit fails the service and the path unit with it
      # (unit-start-limit-hit), and then nothing is kept until the next
      # login. A run is a moment of idle-priority work; there is nothing to
      # limit.
      unitConfig.StartLimitIntervalSec = 0;
      environment = {
        STT_CORPUS_DIR = cfg.dir;
        STT_CORPUS_MAX_CLIPS = toString cfg.maxClips;
        STT_CORPUS_VOQUILL_DB = cfg.voquillDb;
      };
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.python3}/bin/python3 ${../../scripts/stt-corpus-keep.py}";
        # Out of a dictation's way: only CPU and IO nothing else wants.
        CPUSchedulingPolicy = "idle";
        IOSchedulingClass = "idle";
        Nice = 19;
        UMask = "0077";
      };
    };

    systemd.user.paths.stt-corpus-keep = {
      description = "A new Voquill recording: keep the clips before it";
      wantedBy = [ "paths.target" ];
      pathConfig.PathChanged = cfg.voquillAudioDir;
    };

    systemd.user.timers.stt-corpus-keep = {
      description = "Sweep Voquill's recordings into the STT test corpus";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # Relative to the user manager's start and to the last run: monotonic
        # timers, so no Persistent (see gh-token in home/claude-services.nix).
        OnStartupSec = "2min";
        OnUnitInactiveSec = cfg.sweepInterval;
      };
    };
  };
}
