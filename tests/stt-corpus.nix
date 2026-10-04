# stt-corpus: runtime harness for the dictation corpus keeper tuxedo deploys
# (modules/nixos/stt-corpus.nix, scripts/stt-corpus-keep.py), run with the
# exact command the unit starts against a stand-in for Voquill's side: a
# sqlite database with its transcriptions table and a folder of small
# synthetic clips. No VM, no recording of anyone: every clip and every text
# here is made up by the fixture.
#
# Voquill keeps the audio of its newest 20 transcriptions and deletes the
# rest. The keeper copies each clip, with the row that describes it, into a
# local corpus before that happens, so changes to the dictation path can be
# tested end to end on real dictations. What must hold:
#
#   - every transcription whose audio is on disk arrives in the corpus as
#     <corpus>/voquill/<id>.wav plus one line in voquill-manifest.jsonl (the
#     row's fields, `wav`, `bytes`: the format the test harness reads); rows
#     without audio and rows whose file is gone are skipped;
#   - Voquill's database and audio folder are only read;
#   - a run with nothing new changes nothing, byte for byte;
#   - a clip stays in the corpus after Voquill has pruned it;
#   - a corpus written by the earlier one-off script is taken over as it is;
#   - beyond STT_CORPUS_MAX_CLIPS the oldest clips go, the file and the
#     manifest line, and nothing half-written is left behind;
#   - a database that is missing, locked or not a database does not fail the
#     run or touch the corpus; the next run picks the clips up;
#   - the corpus is readable by its owner only;
#   - a row whose id is not a plain name cannot make it write elsewhere.
#
# (That a new recording starts the keeper, and that a timer catches what the
# file event missed: tests/local-stt-switch.nix, under a real user manager.)
#
# Run: nix build .#checks.x86_64-linux.stt-corpus -L
{ pkgs, keeperCommand }:
let
  inherit (import ./lib/stt-corpus-fixtures.nix { inherit pkgs; }) voquill;
in
pkgs.runCommand "stt-corpus-check" { nativeBuildInputs = [ pkgs.python3 pkgs.jq ]; } ''
  set -euo pipefail
  # Nothing here may fall back to a real home.
  export HOME=$PWD/home
  export FAKE_VOQUILL_DB=$PWD/voquill/voquill.db
  export FAKE_VOQUILL_AUDIO=$PWD/voquill/transcription-audio
  export STT_CORPUS_VOQUILL_DB=$FAKE_VOQUILL_DB
  export STT_CORPUS_DIR=$PWD/corpus
  export STT_CORPUS_MAX_CLIPS=5
  mkdir -p $HOME $PWD/voquill
  manifest=$STT_CORPUS_DIR/voquill-manifest.jsonl
  fail() { echo "FAIL: $*" >&2; exit 1; }
  voquill() { python3 ${voquill} "$@"; }
  keep() { ${keeperCommand} > $PWD/keep.log 2>&1 || fail "the keeper exited $?: $(cat $PWD/keep.log)"; }
  ids() { jq -r .id "$manifest" | tr '\n' ' ' | sed 's/ $//'; }
  wavs() { (cd $STT_CORPUS_DIR/voquill && ls | tr '\n' ' ' | sed 's/ $//'); }
  # Everything in a tree: path, size, mtime, mode, and each file's content.
  state() { (cd "$1" && find . -printf '%p %s %T@ %m\n' | sort && find . -type f -exec sha256sum {} + | sort); }

  voquill init
  voquill add clip-a 1000
  voquill add clip-b 2000
  voquill add clip-c 3000
  voquill add no-audio 3500 noaudio
  voquill add file-gone 3600 nofile
  theirs=$(state $PWD/voquill)

  # The clips arrive, in the format the harness reads.
  keep
  [ "$(ids)" = "clip-a clip-b clip-c" ] || fail "manifest after the first run: $(ids)"
  [ "$(wavs)" = "clip-a.wav clip-b.wav clip-c.wav" ] || fail "clips after the first run: $(wavs)"
  cmp -s $FAKE_VOQUILL_AUDIO/clip-b.wav $STT_CORPUS_DIR/voquill/clip-b.wav || fail "a copied clip differs from Voquill's file"
  line=$(sed -n 2p "$manifest")
  [ "$(jq -c 'keys_unsorted' <<< "$line")" = '["id","timestamp","audio_duration_ms","transcript","raw_transcript","sanitized_transcript","model_size","inference_device","transcription_mode","transcription_api_key_id","transcription_duration_ms","post_process_mode","wav","bytes"]' ] \
    || fail "manifest fields: $(jq -c 'keys_unsorted' <<< "$line")"
  [ "$(jq -r '.transcript' <<< "$line")" = "synthetic text clip-b" ] || fail "reference text: $line"
  [ "$(jq -r '.timestamp' <<< "$line")" = 2000 ] || fail "timestamp: $line"
  [ "$(jq -r '.wav' <<< "$line")" = "$STT_CORPUS_DIR/voquill/clip-b.wav" ] || fail "wav path: $line"
  [ "$(jq -r '.bytes' <<< "$line")" = "$(stat -c %s $STT_CORPUS_DIR/voquill/clip-b.wav)" ] || fail "bytes: $line"
  # Voquill's side was only read.
  [ "$(state $PWD/voquill)" = "$theirs" ] || fail "the keeper changed something Voquill owns: $(diff <(echo "$theirs") <(state $PWD/voquill))"
  # Dictations are private: the corpus is its owner's alone.
  [ "$(stat -c %a $STT_CORPUS_DIR)" = 700 ] || fail "corpus mode $(stat -c %a $STT_CORPUS_DIR)"
  [ "$(stat -c %a $STT_CORPUS_DIR/voquill/clip-a.wav)" = 600 ] || fail "clip mode $(stat -c %a $STT_CORPUS_DIR/voquill/clip-a.wav)"
  [ "$(stat -c %a "$manifest")" = 600 ] || fail "manifest mode $(stat -c %a "$manifest")"

  # Nothing new: nothing changes.
  ours=$(state $STT_CORPUS_DIR)
  sleep 1.1
  keep
  [ "$(state $STT_CORPUS_DIR)" = "$ours" ] || fail "a run with nothing new changed the corpus: $(diff <(echo "$ours") <(state $STT_CORPUS_DIR))"

  # Voquill prunes its oldest audio: the corpus still has it. This is what
  # the keeper is for.
  voquill prune clip-a
  keep
  [ "$(state $STT_CORPUS_DIR)" = "$ours" ] || fail "pruning on Voquill's side changed the corpus: $(diff <(echo "$ours") <(state $STT_CORPUS_DIR))"

  # A database that cannot be read right now is no failure and no change:
  # missing, held by a writer, or not a database (a copy in progress).
  mv $FAKE_VOQUILL_DB $FAKE_VOQUILL_DB.away
  keep
  [ "$(state $STT_CORPUS_DIR)" = "$ours" ] || fail "a missing database changed the corpus"
  [ ! -e $FAKE_VOQUILL_DB ] || fail "the keeper created Voquill's database"
  head -c 300 /dev/urandom > $FAKE_VOQUILL_DB
  keep
  [ "$(state $STT_CORPUS_DIR)" = "$ours" ] || fail "an unreadable database changed the corpus"
  mv -f $FAKE_VOQUILL_DB.away $FAKE_VOQUILL_DB
  voquill add clip-d 4000
  voquill lock $PWD/locked $PWD/unlock &
  locker=$!
  for _ in $(seq 100); do [ -e $PWD/locked ] && break; sleep 0.05; done
  [ -e $PWD/locked ] || fail "the fixture did not lock the database"
  keep
  [ "$(state $STT_CORPUS_DIR)" = "$ours" ] || fail "a locked database changed the corpus"
  touch $PWD/unlock; wait "$locker"
  # ...and the next run has the clip that was waiting.
  keep
  [ "$(ids)" = "clip-a clip-b clip-c clip-d" ] || fail "after the lock was released: $(ids)"

  # The cap: beyond STT_CORPUS_MAX_CLIPS (5 here) the oldest clips go, file
  # and manifest line both; the survivors' lines are not rewritten.
  survivor=$(grep '"id": "clip-d"' "$manifest")
  voquill add clip-e 5000
  voquill add clip-f 6000
  voquill add clip-g 7000
  keep
  [ "$(ids)" = "clip-c clip-d clip-e clip-f clip-g" ] || fail "manifest beyond the cap: $(ids)"
  [ "$(wavs)" = "clip-c.wav clip-d.wav clip-e.wav clip-f.wav clip-g.wav" ] || fail "clips beyond the cap: $(wavs)"
  [ "$(grep '"id": "clip-d"' "$manifest")" = "$survivor" ] || fail "a surviving manifest line was rewritten"
  [ "$(ls -A $STT_CORPUS_DIR | tr '\n' ' ')" = "voquill voquill-manifest.jsonl " ] || fail "left behind in the corpus: $(ls -A $STT_CORPUS_DIR)"
  # A dropped clip does not come back while Voquill still has its audio.
  ours=$(state $STT_CORPUS_DIR)
  sleep 1.1
  keep
  [ "$(state $STT_CORPUS_DIR)" = "$ours" ] || fail "a clip dropped by the cap was copied again: $(ids)"

  # A row whose id is not a plain name cannot make the keeper write elsewhere.
  voquill add ../../escape 8000
  keep
  [ ! -e $PWD/escape.wav ] && [ ! -e $STT_CORPUS_DIR/escape.wav ] || fail "an id with path separators wrote outside the clip folder"
  [ "$(state $STT_CORPUS_DIR)" = "$ours" ] || fail "a row with a hostile id changed the corpus: $(ids)"

  # A corpus the earlier one-off script wrote (same layout, default modes) is
  # taken over as it is: its lines stay byte for byte, its clips count
  # towards the cap by their age, and the folder is closed to others.
  export STT_CORPUS_DIR=$PWD/earlier
  manifest=$STT_CORPUS_DIR/voquill-manifest.jsonl
  mkdir -p $STT_CORPUS_DIR/voquill
  chmod 755 $STT_CORPUS_DIR
  for old in old-1 old-2; do
    printf 'RIFF earlier %s' "$old" > $STT_CORPUS_DIR/voquill/$old.wav
    printf '{"id": "%s", "timestamp": %s, "audio_duration_ms": 900, "transcript": "earlier %s", "raw_transcript": "r", "sanitized_transcript": "s", "model_size": "m", "inference_device": "d", "transcription_mode": "api", "transcription_api_key_id": "k", "transcription_duration_ms": 200, "post_process_mode": "none", "wav": "%s/voquill/%s.wav", "bytes": 18}\n' \
      "$old" "''${old#old-}00" "$old" "$STT_CORPUS_DIR" "$old" >> "$manifest"
  done
  earlier=$(cat "$manifest"; cd $STT_CORPUS_DIR/voquill && sha256sum old-1.wav old-2.wav)
  # (clip-b is back in this fresh corpus: Voquill still has its audio and
  # there is room. The keeper holds no memory of what a cap once dropped;
  # a clip stays out only while newer ones fill the cap.)
  STT_CORPUS_MAX_CLIPS=400 keep
  [ "$(ids)" = "old-1 old-2 clip-b clip-c clip-d clip-e clip-f clip-g" ] || fail "taking over an earlier corpus: $(ids)"
  [ "$(head -2 "$manifest"; cd $STT_CORPUS_DIR/voquill && sha256sum old-1.wav old-2.wav)" = "$earlier" ] || fail "the earlier corpus was altered"
  [ "$(stat -c %a $STT_CORPUS_DIR)" = 700 ] || fail "an earlier corpus was left open to others: $(stat -c %a $STT_CORPUS_DIR)"
  STT_CORPUS_MAX_CLIPS=7 keep
  [ "$(ids)" = "old-2 clip-b clip-c clip-d clip-e clip-f clip-g" ] || fail "the oldest of an earlier corpus was not the one dropped: $(ids)"
  [ ! -e $STT_CORPUS_DIR/voquill/old-1.wav ] || fail "a dropped clip's file is still there"
  [ "$(head -1 "$manifest"; cd $STT_CORPUS_DIR/voquill && sha256sum old-2.wav)" = "$(sed -n 2p <<< "$earlier"; sed -n 4p <<< "$earlier")" ] || fail "the surviving earlier clip was altered"

  echo "stt-corpus: all assertions passed"
  touch $out
''
