# A stand-in for Voquill's side of the corpus keeper, shared by
# tests/stt-corpus.nix and tests/local-stt-switch.nix: the transcriptions
# table of its sqlite database (the columns the keeper reads, plus one it
# does not) and its audio folder. Every clip and every text is synthetic.
{ pkgs }:
{
  voquill = pkgs.writeText "voquill-fixture.py" ''
    import os, sqlite3, sys, time

    db, audio = os.environ["FAKE_VOQUILL_DB"], os.environ["FAKE_VOQUILL_AUDIO"]
    what = sys.argv[1]
    os.makedirs(os.path.dirname(db), exist_ok=True)
    con = sqlite3.connect(db)

    def wav(clip):
        return os.path.join(audio, clip.replace("/", "_") + ".wav")

    def write_audio(clip):
        with open(wav(clip), "wb") as f:
            f.write(b"RIFF" + ("synthetic clip " + clip + " ").encode() * 40)

    def insert(clip, stamp, path):
        con.execute("insert into transcriptions values (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (clip, stamp, path, 1200, "synthetic text " + clip, "raw " + clip, "clean " + clip,
                     "stub", "none", "api", "key-1", 300, "none", "not for the corpus"))
        con.commit()

    if what == "init":
        os.makedirs(audio, exist_ok=True)
        con.execute("create table transcriptions (id text primary key, timestamp integer, audio_path text, "
                    "audio_duration_ms integer, transcript text, raw_transcript text, sanitized_transcript text, "
                    "model_size text, inference_device text, transcription_mode text, "
                    "transcription_api_key_id text, transcription_duration_ms integer, post_process_mode text, "
                    "unrelated text)")
        con.commit()
    elif what == "add":
        # add <id> <timestamp> [noaudio|nofile|rowfirst|rowlate]
        #   (default)  the row and its audio file, both there at once
        #   noaudio    a transcription Voquill kept no audio for
        #   nofile     the row names a file that is gone
        #   rowfirst   the row, then the file: the file event finds the row
        #   rowlate    the file, then (a moment later) the row: the file
        #              event comes too early, as it does with the real app
        clip, stamp, kind = sys.argv[2], int(sys.argv[3]), (sys.argv[4:] + ["both"])[0]
        if kind == "noaudio":
            insert(clip, stamp, "")
        elif kind == "nofile":
            insert(clip, stamp, wav(clip))
        elif kind == "rowlate":
            write_audio(clip)
            time.sleep(3)
            insert(clip, stamp, wav(clip))
        else:
            insert(clip, stamp, wav(clip))
            write_audio(clip)
    elif what == "prune":
        # Voquill drops the audio of an old transcription: file gone, path cleared.
        clip = sys.argv[2]
        os.unlink(wav(clip))
        con.execute("update transcriptions set audio_path = ? where id = ?", ("", clip))
        con.commit()
    elif what == "lock":
        # lock <ready-file> <release-file>: hold the database the way a writer
        # in the middle of a transaction does, until told to let go.
        ready, release = sys.argv[2], sys.argv[3]
        con.isolation_level = None
        con.execute("begin exclusive")
        open(ready, "w").close()
        while not os.path.exists(release):
            time.sleep(0.05)
        con.execute("rollback")
    elif what == "wal":
        # The journal mode of the real app's database. Once the last
        # connection closes, sqlite removes the -wal and -shm files again.
        con.execute("pragma journal_mode=wal").fetchall()
    elif what == "drift":
        # An app update that drops a column the keeper reads.
        con.execute("alter table transcriptions drop column post_process_mode")
        con.commit()
    else:
        sys.exit("unknown fixture command " + what)
    con.close()
  '';
}
