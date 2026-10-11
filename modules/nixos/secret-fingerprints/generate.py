"""Write salted SHA-256 fingerprints of agenix secret values.

Usage: generate.py MANIFEST USER GROUP OUT_PATH RECORD
  MANIFEST  JSON list of secret paths
  USER      the reader: "root-only" means not readable by this user
  GROUP     group of OUT_PATH (root:GROUP 0440)
  OUT_PATH  fingerprint file, replaced atomically
  RECORD    unit-failures record: written when the run is degraded,
            removed when it is clean

Invariants:
  * No secret value or secret name is ever printed; logs carry counts.
  * Every run draws a fresh salt.
  * The process exits 0 unless RECORD itself cannot be written.
"""

import datetime
import grp
import hashlib
import json
import os
import pwd
import re
import secrets
import subprocess
import sys
import tempfile

MIN_LEN = 12
UNIT = "secret-fingerprints.service"

PEM_RE = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.DOTALL,
)
ENV_RE = re.compile(r"(?:export\s+)?[A-Za-z_][A-Za-z0-9_.-]*\s*=\s*(.*)")
RUN_RE = re.compile(r"[A-Za-z0-9_-]+")


def log(msg):
    print(f"secret-fingerprints: {msg}", flush=True)


def now_iso():
    now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
    return now.isoformat().replace("+00:00", "Z")


def strip_quotes(v):
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def env_value(line):
    """The value of a KEY=value line (quotes or ` #` comment removed), else None."""
    m = ENV_RE.fullmatch(line)
    if not m:
        return None
    v = m.group(1).strip()
    if v[:1] in "\"'":
        end = v.find(v[0], 1)
        return v[1:end] if end > 0 else v[1:]
    return v.split(" #", 1)[0].rstrip()


def json_strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from json_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from json_strings(v)


def candidates(text):
    """Values in one secret's plaintext worth fingerprinting (all >= MIN_LEN).

    Private-key blocks are removed first; the regex detectors catch their
    armour. Taken as given: the content of a single-line file, and every
    KEY=value value that is not a path — the file or the key says it is a
    secret. Taken only when they hold a digit and a letter: other lines,
    JSON string values,
    and every maximal [A-Za-z0-9_-] run of any candidate; this keeps
    ordinary words ("service_account", a path, a secret's own name) out.
    """
    body = PEM_RE.sub("", text)
    lines = [
        ln.strip() for ln in body.splitlines()
        if ln.strip() and not ln.strip().startswith("#")
    ]
    given, derived = set(), set()
    for line in lines:
        value = env_value(line)
        # A path value is a reference to a secret, not the secret.
        if value is not None and not value.startswith(("/", "~/")):
            given.add(value)
        if len(lines) == 1:
            given.add(strip_quotes(line))
        elif value is None:
            derived.add(strip_quotes(line))
    try:
        derived.update(json_strings(json.loads(body)))
    except ValueError:
        pass
    for v in given | derived:
        derived.update(RUN_RE.findall(v))
    derived = {
        v for v in derived
        if any(c.isdigit() for c in v) and any(c.isalpha() for c in v)
    }
    return {v for v in given | derived if len(v) >= MIN_LEN}


def machine_token(v):
    """True if v has the shape of a random-generator token.

    Gate for secrets the reader cannot read: the output file hands the
    reader salt and fast hashes, so a human-chosen value would be
    offline-guessable. Shape rule, not an entropy bound: >= 32 chars of
    [A-Za-z0-9_+/=.-], and either hex (>= 32 hex digits, UUIDs included)
    or mixed case with >= 4 separate digit runs. Rejects phrases and
    word+year values; keeps random base62/base64 tokens ~85% of the time
    at 40 chars, ~99% at 64. A value built on purpose to fit can pass.
    """
    if len(v) < 32 or not re.fullmatch(r"[A-Za-z0-9_+/=.-]+", v):
        return False
    if re.fullmatch(r"[0-9A-Fa-f-]+", v) and sum(c != "-" for c in v) >= 32:
        return True
    return (
        any(c.isupper() for c in v)
        and any(c.islower() for c in v)
        and len(re.findall(r"[0-9]+", v)) >= 4
    )


def readable_by(user, paths):
    """The subset of paths `user` may read, asked by a child running as `user`.

    Returns None when the probe itself fails.
    """
    pw = pwd.getpwnam(user)
    probe = "import json,os,sys;print(json.dumps([os.access(p,os.R_OK) for p in json.load(sys.stdin)]))"
    try:
        child = subprocess.run(
            [sys.executable, "-I", "-c", probe],
            input=json.dumps(paths), capture_output=True, text=True, check=True,
            user=pw.pw_uid, group=pw.pw_gid,
            extra_groups=os.getgrouplist(user, pw.pw_gid), env={}, cwd="/",
        )
        answers = json.loads(child.stdout)
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    return {p for p, ok in zip(paths, answers) if ok is True}


def write_atomic(path, text, gid, mode):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp.")
    try:
        with os.fdopen(fd, "w") as f:
            os.fchown(f.fileno(), 0, gid)
            os.fchmod(f.fileno(), mode)
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        os.remove(tmp)
        raise


def generate(manifest, user, group, out_path):
    """Write OUT_PATH. Returns None, or what is wrong with the result."""
    with open(manifest) as f:
        paths = sorted(set(json.load(f)))
    readable = readable_by(user, paths)
    salt = secrets.token_bytes(32)

    fps, unread, withheld, root_only = set(), 0, 0, 0
    for p in paths:
        try:
            with open(p, "rb") as f:
                text = f.read().decode("utf-8", errors="replace")
        except OSError:
            unread += 1
            continue
        values = candidates(text)
        if readable is None or p not in readable:
            root_only += 1
            kept = {v for v in values if machine_token(v)}
            withheld += len(values) - len(kept)
            values = kept
        fps.update(hashlib.sha256(salt + v.encode()).hexdigest() for v in values)

    doc = {
        "version": 1,
        "salt": salt.hex(),
        "min_len": MIN_LEN,
        "fingerprints": sorted(fps),
        "generated": now_iso(),
    }
    write_atomic(out_path, json.dumps(doc) + "\n", grp.getgrnam(group).gr_gid, 0o440)
    log(f"{len(paths)} secrets ({root_only} root-only, {unread} unreadable); "
        f"{len(fps)} fingerprints; {withheld} root-only values withheld")

    if readable is None:
        return "the readability probe failed, so every secret was treated as root-only."
    if unread:
        return f"{unread} of {len(paths)} secrets could not be read."
    return None


def report(record, problem):
    if problem is None:
        try:
            os.remove(record)
        except FileNotFoundError:
            pass
        return
    rec = {
        "unit": UNIT,
        "result": "degraded",
        "exit_status": "0",
        "failed_at": now_iso(),
        "summary": f"Known-value secret masking is incomplete: {problem} "
                   "Some agenix secret values may not be masked in agent output.",
        "inspect": f"journalctl -u {UNIT} -n 50",
    }
    write_atomic(record, json.dumps(rec) + "\n", 0, 0o644)


def main(argv):
    if len(argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2
    manifest, user, group, out_path, record = argv[1:]
    try:
        problem = generate(manifest, user, group, out_path)
    except Exception as e:  # the type only: a message can quote input
        problem = f"the generator crashed ({type(e).__name__})."
    if problem:
        log("DEGRADED: " + problem)
    try:
        report(record, problem)
    except OSError as e:
        log(f"could not write the failure record ({type(e).__name__})")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
