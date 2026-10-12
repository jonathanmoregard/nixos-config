#!@python@ -IS
"""secret-redact: replace every secret in a list of texts, using a pinned gitleaks 8.30.

    stdin   {"texts": ["...", ...], "timeout": <seconds>}
    stdout  {"texts": ["...", ...], "counts": [{"<rule id>": <markers>, ...}, ...]}  (one per text)

A secret becomes ``[REDACTED:<rule id>:<n>chars]``. ``--gitleaks`` and ``--rules``
exist for tests; callers never pass them.

Invariants:
- Exit 0 means every byte of every text was scanned and every finding redacted. Any
  fault (bad input, gitleaks missing, failing, timing out, reading less than it was
  given or writing an unreadable report, more than MAX_TARGETS distinct secrets, the
  timeout passing while findings are applied) exits 1 with one line on stderr that
  never quotes the input. Callers fail closed on any non-zero exit.
- Each text is scanned and redacted alone: a rule's keywords never cross texts, and
  batching never changes a text's result.
- gitleaks reads everything: a header defeats its binary-type sniffing, every piece fits
  one gitleaks read, and its own read count is checked. Nothing in or around the input
  can silence a finding (no ignore files; gitleaks:allow is ignored).
- An armored private key is found on the whole text: BEGIN to the END after it, or to
  the end of the text when none follows.
- Overlapping findings become one marker, and a marker is never redacted again.
Stdlib only.
"""
from __future__ import annotations

import getopt
import json
import os
import re
import subprocess
import sys
import tempfile
import time

GITLEAKS = "@gitleaks@"
RULES = "@rules@"

# BMP magic: gitleaks sniffs each file and silently skips application/* types (%PDF, MZ, ...).
HEADER = b"BM secret-redact\n\n"
# HEADER + piece stays under gitleaks' 100,000-byte read, so gitleaks never cuts a file itself.
PIECE_BYTES = 96_000
# Neighbouring pieces share this many bytes, so a secret cut by one piece's edge is whole in
# the other. Armored keys, which can be longer, are found on the whole text instead.
OVERLAP_BYTES = 16_000
# A Secret capture shorter than this is too generic to redact everywhere; use the full Match.
MIN_SECRET_CHARS = 8
# Each distinct secret costs one pass over the texts; 1,000 passes over 8 MB take ~1 s.
MAX_TARGETS = 1000
# Decoded findings report the DECODED secret; the encoded runs on that line are what to redact.
ENCODED_RUN = re.compile(r"[A-Za-z0-9+/=_%\-]{16,}")
# A target containing a marker is a match on an earlier redaction: dropping it keeps reruns stable.
MARKER = "[REDACTED:"
# An existing marker on a decoded line is not an encoded run (its rule id could look like one).
MARKER_SPAN = re.compile(r"\[REDACTED:[^\]\n]*\]")
# Armor lines of a private key (PEM, OpenSSH, PGP); bounded, so finding them is linear.
ARMOR = re.compile(r"-----(BEGIN|END)[ A-Z0-9_-]{0,100}PRIVATE KEY(?: BLOCK)?-----")
# gitleaks' log line with its own read count.
SCANNED = re.compile(r"scanned ~(\d+) bytes")
# gitleaks colours its fatal log lines even under --no-color.
ANSI = re.compile(r"\x1b\[[0-9;]*m")
# tmpfs where available, so unredacted text is not written to disk.
RAM_DIR = "/dev/shm" if os.access("/dev/shm", os.W_OK) else None


class Failure(Exception):
    """The texts are NOT known to be clean. The message never carries input text."""


def main(argv: list[str]) -> int:
    # getopt, not argparse: argparse pulls in ~15 ms of colour support on every call.
    opts = {"--gitleaks": GITLEAKS, "--rules": RULES}
    try:
        opts.update(getopt.getopt(argv, "", ["gitleaks=", "rules="])[0])
        texts, timeout = _read_request(sys.stdin.buffer.read())
        deadline = time.monotonic() + timeout
        targets = find_secrets(texts, gitleaks=opts["--gitleaks"], rules=opts["--rules"], deadline=deadline)
        distinct = len(set().union(*targets))
        if distinct > MAX_TARGETS:
            raise Failure(f"{distinct} distinct secrets, more than the {MAX_TARGETS} redacted in time")
        counts: list[dict[str, int]] = [{} for _ in texts]
        out = [redact(t, found, c, deadline) for t, found, c in zip(texts, targets, counts)]
    except (Failure, getopt.GetoptError) as e:
        sys.stderr.write(f"secret-redact: {e}\n")
        return 1
    sys.stdout.write(json.dumps({"texts": out, "counts": counts}))
    return 0


def _read_request(raw: bytes) -> tuple[list[str], float]:
    try:
        request = json.loads(raw)
        texts, timeout = request["texts"], float(request["timeout"])
    except (ValueError, KeyError, TypeError) as e:
        raise Failure(f"stdin is not a request ({type(e).__name__})") from None
    if not isinstance(texts, list) or not all(isinstance(t, str) for t in texts):
        raise Failure("texts is not a list of strings")
    return texts, timeout


def pieces(data: bytes) -> list[bytes]:
    """``data`` as PIECE_BYTES windows, each overlapping the next by OVERLAP_BYTES."""
    step = PIECE_BYTES - OVERLAP_BYTES
    return [data[i : i + PIECE_BYTES] for i in range(0, max(len(data) - OVERLAP_BYTES, 1), step)]


def find_secrets(texts: list[str], *, gitleaks: str, rules: str, deadline: float) -> list[dict[str, str]]:
    """Per text, ``{target string: rule id}``. A target several rules hit gets the
    alphabetically first id, so the same input always gives the same markers."""
    files = [(i, HEADER + p) for i, t in enumerate(texts) if t for p in pieces(t.encode("utf-8", "replace"))]
    targets: list[dict[str, str]] = [{} for _ in texts]

    def add(i: int, target: str, rule: str) -> None:
        targets[i][target] = min(rule, targets[i].get(target, rule))

    if files:
        for finding, n in _run(gitleaks, rules, [data for _, data in files], deadline - time.monotonic()):
            owner, data = files[n]
            for target in _targets(finding, data):
                if MARKER not in target:
                    add(owner, target, finding["RuleID"])
    for i, text in enumerate(texts):
        for block in _armored_blocks(text):
            add(i, block, "private-key")
    return targets


def _run(gitleaks: str, rules: str, files: list[bytes], timeout: float) -> list[tuple[dict, int]]:
    """Each gitleaks finding over ``files`` with the index of its file, checked to be complete."""
    cmd = [gitleaks, "dir", "in", "--config", os.path.abspath(rules),
           "--report-format", "json", "--report-path", "-", "--exit-code", "0",
           "--no-banner", "--no-color", "--log-level", "info",
           "--ignore-gitleaks-allow", "--gitleaks-ignore-path", os.devnull]
    try:
        # A fresh 0700 dir as cwd AND scan root: no .gitleaksignore can be found in either.
        with tempfile.TemporaryDirectory(prefix="secret-redact-", dir=RAM_DIR) as work:
            os.mkdir(os.path.join(work, "in"), 0o700)
            for n, data in enumerate(files):
                with open(os.path.join(work, "in", f"{n}.txt"), "wb") as fh:
                    fh.write(data)
            proc = subprocess.run(cmd, cwd=work, capture_output=True, timeout=timeout,
                                  check=False, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise Failure(f"gitleaks timed out after {timeout:.1f}s") from None
    except OSError as e:
        raise Failure(f"gitleaks could not run: {e.strerror or type(e).__name__} ({gitleaks})") from None
    stderr = ANSI.sub("", proc.stderr.decode("utf-8", "replace"))
    if proc.returncode != 0:
        fatal = next((ln for ln in stderr.splitlines() if "FTL" in ln), "")
        raise Failure(f"gitleaks exited {proc.returncode} {fatal[:200]}".rstrip())
    scanned = SCANNED.search(stderr)
    written = sum(map(len, files))
    if scanned is None or int(scanned[1]) < written:
        raise Failure(f"gitleaks read {scanned[1] if scanned else '?'} of {written} bytes")
    try:
        report = [(f, int(os.path.basename(f["File"]).removesuffix(".txt"))) for f in json.loads(proc.stdout)]
        if any(not 0 <= n < len(files) for _, n in report):
            raise IndexError
        return report
    except (ValueError, KeyError, TypeError, IndexError):
        raise Failure("gitleaks report was unreadable") from None


def _targets(finding: dict, data: bytes) -> list[str]:
    """The strings in the scanned file ``data`` that redact this finding."""
    try:
        if any(str(tag).startswith("decoded:") for tag in finding.get("Tags") or ()):
            lines = data.decode("utf-8", "replace").split("\n")
            n = finding["StartLine"] - 1
            if not 0 <= n < len(lines):
                raise Failure("gitleaks placed a decoded finding outside its file")
            return ENCODED_RUN.findall(MARKER_SPAN.sub(" ", lines[n]))
        secret = finding.get("Secret") or ""
        target = secret if len(secret) >= MIN_SECRET_CHARS else finding.get("Match") or secret
    except (KeyError, TypeError, AttributeError):
        raise Failure("gitleaks report was unreadable") from None
    return [target] if isinstance(target, str) and target else []


def _armored_blocks(text: str) -> list[str]:
    """Each armored private key in ``text``: BEGIN to the END after it, or to the end of
    the text when none follows (output cut by truncation)."""
    blocks, start = [], None
    for armor in ARMOR.finditer(text):
        if armor[1] == "BEGIN" and start is None:
            start = armor.start()
        elif armor[1] == "END" and start is not None:
            blocks.append(text[start : armor.end()])
            start = None
    if start is not None:
        blocks.append(text[start:])
    return blocks


def redact(text: str, targets: dict[str, str], counts: dict[str, int], deadline: float) -> str:
    """``text`` with each occurrence of each target replaced by a marker, counted per rule.
    Occurrences that share characters become one marker, named by the longest target at
    its start, so no fragment of either survives between them."""
    # Hand-rolled on purpose: stdlib only (pyahocorasick is not in this interpreter), and an
    # `re` alternation took 19 s for 1,000 targets over 8 MB; str.find per target took 0.7 s.
    spans = sorted(((start, end, rule) for t, rule in targets.items() if t
                    for start, end in _spans(text, t, deadline)),
                   key=lambda span: (span[0], -span[1]))
    merged: list[list] = []
    for start, end, rule in spans:
        if merged and start < merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end, rule])
    out, pos = [], 0
    for start, end, rule in merged:
        out += [text[pos:start], f"[REDACTED:{rule}:{end - start}chars]"]
        counts[rule] = counts.get(rule, 0) + 1
        pos = end
    return "".join(out) + text[pos:]


def _spans(text: str, target: str, deadline: float):
    """(start, end) of each run of overlapping occurrences of ``target``, one per run."""
    start = text.find(target)
    while start != -1:
        end = start + len(target)
        nxt = text.find(target, start + 1)
        while nxt != -1 and nxt < end:
            if time.monotonic() > deadline:
                raise Failure("the timeout passed while findings were applied")
            end = nxt + len(target)
            nxt = text.find(target, nxt + 1)
        if time.monotonic() > deadline:
            raise Failure("the timeout passed while findings were applied")
        yield start, end
        start = nxt


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
