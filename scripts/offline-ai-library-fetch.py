#!/usr/bin/env python3
"""offline-ai-library-fetch: download the Kiwix archives listed in the survival corpus.

Reads the corpus source list (sources.yaml), takes every entry of
`type: kiwix` that has a `url`, and downloads it into the archive folder
the library server reads. Downloads resume, and every file is checked
against the SHA-256 the mirror publishes beside it before it is put in
place, so a partial or corrupted archive never reaches the library.

  offline-ai-library-fetch --list     what would be fetched, with sizes
  offline-ai-library-fetch            the entries marked `fetch: core`
  offline-ai-library-fetch --all      core and optional entries
  offline-ai-library-fetch ID [ID..]  only these entries
"""

import argparse
import hashlib
import http.client
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import yaml

SOURCES = Path(os.environ.get("OFFLINE_AI_SOURCES", "sources.yaml"))
ZIM_DIR = Path(os.environ.get("OFFLINE_AI_ZIM_DIR", "."))
CHUNK = 1024 * 1024


def entries():
    with open(SOURCES, encoding="utf-8") as fh:
        sources = yaml.safe_load(fh) or []
    return [s for s in sources if s.get("type") == "kiwix" and s.get("status", "include") != "skip"]


def filename(entry):
    return entry["url"].rsplit("/", 1)[-1]


def published_digest(url):
    """The mirror's `<file>.sha256` sibling: `<hex>  <name>`."""
    with urllib.request.urlopen(url + ".sha256", timeout=60) as response:
        digest = response.read(4096).decode("ascii", errors="replace").split()[0].lower()
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise ValueError("the published checksum is not a SHA-256")
    return digest


def file_digest(path):
    sha = hashlib.sha256()
    with open(path, "rb") as fh:
        while block := fh.read(CHUNK):
            sha.update(block)
    return sha.hexdigest()


class Incomplete(Exception):
    """The server stopped sending before the whole file arrived."""


def download(url, part):
    """Fetch url into part, continuing from whatever part already holds."""
    have = part.stat().st_size if part.exists() else 0
    request = urllib.request.Request(url, headers={"Range": f"bytes={have}-"} if have else {})
    try:
        response = urllib.request.urlopen(request, timeout=120)
    except urllib.error.HTTPError as exc:
        if exc.code == 416 and have:  # nothing left to send: the part is already complete
            return
        raise
    with response:
        resumed = response.status == 206
        total = (have if resumed else 0) + int(response.headers.get("Content-Length") or 0)
        done, shown = (have if resumed else 0), time.time()
        with open(part, "ab" if resumed else "wb") as out:
            while block := response.read(CHUNK):
                out.write(block)
                done += len(block)
                if time.time() - shown > 5:
                    shown = time.time()
                    print(f"    {done / 2**20:,.0f} / {total / 2**20:,.0f} MiB", file=sys.stderr)
    if total and done < total:
        raise Incomplete(f"connection ended at {done:,} of {total:,} bytes")


def fetch(entry):
    """True when the archive is in place and verified."""
    url = entry["url"]
    dest = ZIM_DIR / filename(entry)
    part = dest.with_name(dest.name + ".part")
    if dest.exists():
        print(f"  have {dest.name}")
        return True
    try:
        expected = published_digest(url)
        download(url, part)
        actual = file_digest(part)
    except (urllib.error.URLError, OSError, ValueError, IndexError, http.client.HTTPException, Incomplete) as exc:
        # The partial file stays: the next run continues from where this one stopped.
        print(f"  FAILED {dest.name}: {exc} (run again to continue)")
        return False
    if actual != expected:
        part.unlink()
        print(f"  FAILED {dest.name}: checksum mismatch, download discarded")
        return False
    part.replace(dest)
    print(f"  fetched {dest.name}")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("ids", nargs="*", help="only these source ids")
    parser.add_argument("--all", action="store_true", help="include entries marked optional")
    parser.add_argument("--list", action="store_true", help="show what would be fetched")
    args = parser.parse_args()

    known = entries()
    unknown = set(args.ids) - {e["id"] for e in known}
    if unknown:
        sys.exit(f"no kiwix source with id: {', '.join(sorted(unknown))}")
    chosen = []
    for entry in known:
        if args.ids:
            wanted = entry["id"] in args.ids
        else:
            wanted = args.all or entry.get("fetch") == "core"
        if not entry.get("url"):
            if args.list or entry["id"] in args.ids:
                print(f"  no url  {entry['id']}: {entry['title']} (fetch by hand, see its notes)")
            continue
        if args.list:
            state = "have" if (ZIM_DIR / filename(entry)).exists() else entry.get("fetch", "optional")
            print(f"  {state:8}  {entry.get('size', '?'):>6}  {entry['id']}: {entry['title']}")
        elif wanted:
            chosen.append(entry)
    if args.list:
        return
    if not chosen:
        sys.exit("nothing to fetch")
    ZIM_DIR.mkdir(parents=True, exist_ok=True)
    failed = 0
    for entry in chosen:
        print(f"{entry['id']}: {entry['title']} ({entry.get('size', '?')})")
        failed += not fetch(entry)
    if failed:
        sys.exit(f"{failed} of {len(chosen)} archives failed")


if __name__ == "__main__":
    main()
