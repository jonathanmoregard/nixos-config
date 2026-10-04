#!/usr/bin/env python3
"""stt-corpus-keep: copy Voquill's dictation clips into a local test corpus.

Voquill keeps the audio of its newest 20 transcriptions and deletes the rest.
Each run copies every clip Voquill still has, with the database row that
describes it, into the corpus:

  <corpus>/voquill/<id>.wav
  <corpus>/voquill-manifest.jsonl    one JSON object per clip: the row's
                                     fields, then `wav` and `bytes`

and keeps at most STT_CORPUS_MAX_CLIPS clips, the newest by Voquill's
timestamp. Beyond the cap the oldest go, the file and the manifest line both.
The keeper remembers nothing else: a clip the cap dropped stays out for as
long as newer clips fill the cap, because it is older than all of them.

What it never does:
  - write to anything Voquill owns: the database is opened read-only and the
    audio files are only read;
  - fail because Voquill's database is missing, locked, half-written or not
    a database: the run ends quietly with the corpus untouched, and the next
    run (a new recording, or the timer) picks the clips up;
  - touch the corpus when there is nothing to do: no rewrite, no temp file;
  - open a network connection.

The corpus holds recordings of a person's voice, so the folder is made
readable by its owner only, and new files are created that way.

A manifest line that is not valid JSON is kept as it is and never dropped;
it does not count towards the cap. A database row whose id is not a plain
file name is skipped, so a row cannot make the keeper write outside the clip
folder.

Settings come from the environment (the systemd unit sets them):
  STT_CORPUS_DIR         the corpus folder (default ~/.local/share/stt-corpus)
  STT_CORPUS_MAX_CLIPS   most clips kept (default 400)
  STT_CORPUS_VOQUILL_DB  Voquill's sqlite database
                         (default ~/.config/com.voquill.desktop.local/voquill.db)

Prints one line of counts. Never prints transcript text.
"""
import json
import os
import pathlib
import re
import shutil
import sqlite3
import stat
import sys

CORPUS = os.path.expanduser(os.environ.get("STT_CORPUS_DIR", "~/.local/share/stt-corpus"))
MAX_CLIPS = int(os.environ.get("STT_CORPUS_MAX_CLIPS", "400"))
DB = os.path.expanduser(
    os.environ.get("STT_CORPUS_VOQUILL_DB", "~/.config/com.voquill.desktop.local/voquill.db"))

CLIPS = os.path.join(CORPUS, "voquill")
MANIFEST = os.path.join(CORPUS, "voquill-manifest.jsonl")

# The row fields kept in the manifest, in this order. `audio_path` is read to
# find the file and left out: the manifest names the corpus copy as `wav`.
FIELDS = (
    "id", "timestamp", "audio_duration_ms", "transcript", "raw_transcript",
    "sanitized_transcript", "model_size", "inference_device", "transcription_mode",
    "transcription_api_key_id", "transcription_duration_ms", "post_process_mode",
)
PLAIN_NAME = re.compile(r"[A-Za-z0-9_-][A-Za-z0-9._-]*")
# How long to wait for a writer to let go of the database before leaving it
# for the next run.
DB_BUSY_SECONDS = 1.0


def read_rows():
    """Voquill's rows that still have audio on disk, or None if the database
    cannot be read right now."""
    if not os.path.isfile(DB):
        return None
    try:
        con = sqlite3.connect(f"file:{DB}?mode=ro", uri=True, timeout=DB_BUSY_SECONDS)
        try:
            con.row_factory = sqlite3.Row
            rows = con.execute(
                f"select {', '.join(FIELDS)}, audio_path from transcriptions "
                "where audio_path is not null and audio_path != ''"
            ).fetchall()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    usable = []
    for row in rows:
        clip_id = row["id"]
        if not isinstance(clip_id, str) or not PLAIN_NAME.fullmatch(clip_id):
            continue
        if not os.path.isfile(row["audio_path"]):
            continue
        usable.append(row)
    return usable


def read_manifest():
    """The manifest as (raw line, id or None, timestamp) in file order."""
    entries = []
    if not os.path.exists(MANIFEST):
        return entries
    with open(MANIFEST, encoding="utf-8") as handle:
        for raw in handle:
            if not raw.strip():
                continue
            if not raw.endswith("\n"):
                raw += "\n"
            try:
                record = json.loads(raw)
                entries.append((raw, record["id"], age(record.get("timestamp"))))
            except (ValueError, KeyError, TypeError):
                entries.append((raw, None, 0))
    return entries


def age(timestamp):
    return timestamp if isinstance(timestamp, (int, float)) else 0


def close_to_others(path):
    """Make an existing folder its owner's alone, if it is not already."""
    if stat.S_IMODE(os.stat(path).st_mode) != 0o700:
        os.chmod(path, 0o700)


def main():
    os.umask(0o077)
    rows = read_rows()
    if rows is None:
        print("stt-corpus-keep: Voquill's database is not readable right now; nothing done")
        return 0

    entries = read_manifest()
    known = {clip_id for _, clip_id, _ in entries if clip_id is not None}
    candidates = sorted(
        (row for row in rows if row["id"] not in known),
        key=lambda row: (age(row["timestamp"]), row["id"]),
    )

    # Newest MAX_CLIPS of what is kept plus what could be added. Ties go to
    # the clip already kept.
    ranked = sorted(
        [(stamp, 1, clip_id) for _, clip_id, stamp in entries if clip_id is not None]
        + [(age(row["timestamp"]), 0, row["id"]) for row in candidates],
        reverse=True,
    )
    keep = {clip_id for _, _, clip_id in ranked[:MAX_CLIPS]}
    dropped = [clip_id for _, clip_id, _ in entries if clip_id is not None and clip_id not in keep]
    added = [row for row in candidates if row["id"] in keep]

    if os.path.isdir(CORPUS):
        close_to_others(CORPUS)
    if not added and not dropped:
        print(f"stt-corpus-keep: nothing new, {len(known)} clips kept")
        return 0

    os.makedirs(CLIPS, exist_ok=True)
    close_to_others(CORPUS)

    new_lines = []
    for row in added:
        destination = os.path.join(CLIPS, row["id"] + ".wav")
        partial = destination + ".part"
        try:
            shutil.copyfile(row["audio_path"], partial)
        except OSError:
            # Voquill pruned the file between the query and the copy.
            if os.path.exists(partial):
                os.unlink(partial)
            continue
        os.replace(partial, destination)
        record = {field: row[field] for field in FIELDS}
        record["wav"] = destination
        record["bytes"] = os.path.getsize(destination)
        new_lines.append(json.dumps(record, ensure_ascii=False) + "\n")

    if dropped:
        # Rewrite without the dropped lines; the survivors' text is untouched.
        gone = set(dropped)
        partial = MANIFEST + ".part"
        with open(partial, "w", encoding="utf-8") as handle:
            for raw, clip_id, _ in entries:
                if clip_id is None or clip_id not in gone:
                    handle.write(raw)
            handle.writelines(new_lines)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(partial, MANIFEST)
        for clip_id in dropped:
            if PLAIN_NAME.fullmatch(clip_id):
                # A clip file that is already gone is what the drop wants.
                pathlib.Path(CLIPS, clip_id + ".wav").unlink(missing_ok=True)
    elif new_lines:
        with open(MANIFEST, "a", encoding="utf-8") as handle:
            handle.writelines(new_lines)

    total = len(known) - len(dropped) + len(new_lines)
    print(f"stt-corpus-keep: {len(new_lines)} new, {len(dropped)} dropped, {total} clips kept (cap {MAX_CLIPS})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
