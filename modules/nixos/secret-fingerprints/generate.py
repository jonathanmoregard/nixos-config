"""Write salted SHA-256 fingerprints of every agenix secret value.

Producer half of known-value secret masking; see ../secret-fingerprints.nix
for the design and the consumer contract. Runs as root.

Invariant: no secret value, and no secret name, is ever printed. Every log
line carries counts only. Exceptions are caught and reported by type name,
never by message, because a decode or parse error message can quote input.

Usage: generate.py MANIFEST USER STATE_DIR OUT_PATH RECORD
  MANIFEST   JSON list of secret paths (from config.age.secrets.*.path)
  USER       reader the output file is for (its owner)
  STATE_DIR  holds the per-host salt (persisted across boots)
  OUT_PATH   output JSON, written atomically
  RECORD     /var/lib/unit-failures/<unit>.json: written on a degraded run,
             removed on a clean one
"""

import datetime
import hashlib
import json
import os
import pwd
import re
import secrets
import subprocess
import sys
import tempfile

VERSION = 1
MIN_LEN = 12

# Maximal runs of this class are candidates in their own right: they are
# what a secret looks like when it sits inside a URL, a header or a quoted
# string in tool output.
RUN_RE = re.compile(r"[A-Za-z0-9_-]+")

# PEM / OpenSSH private-key blocks, in the clear or JSON-escaped (\n). The
# regex detectors already catch these by their armour; their base64 body
# lines would only add noise here.
PEM_RE = re.compile(
    r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?-----END [A-Z0-9 ]*PRIVATE KEY-----",
    re.DOTALL,
)
PEM_MARKER = "PRIVATE KEY-----"
PEM_SENTINEL = "\x00pem\x00"

ENV_RE = re.compile(r"^(?:export\s+)?[A-Za-z_][A-Za-z0-9_.-]*\s*=\s*(.*)$")

# Root-only candidates: see machine_token().
TOKEN_ALPHABET_RE = re.compile(r"[A-Za-z0-9_+/=.-]+")
HEX_RE = re.compile(r"[0-9A-Fa-f-]+")
DIGIT_RUN_RE = re.compile(r"[0-9]+")


def log(msg):
    print(f"secret-fingerprints: {msg}", flush=True)


def strip_quotes(v):
    if len(v) >= 2 and v[0] == v[-1] and v[0] in "\"'":
        return v[1:-1]
    return v


def env_value(line):
    """Value of a KEY=value line, quotes stripped; None if not one."""
    m = ENV_RE.match(line)
    if not m:
        return None
    v = m.group(1).strip()
    if v[:1] in "\"'":
        end = v.find(v[0], 1)
        return v[1:end] if end > 0 else v[1:]
    # Unquoted: a ` #` starts a comment, as in shell and dotenv.
    hash_at = v.find(" #")
    if hash_at >= 0:
        v = v[:hash_at].rstrip()
    return v


def json_strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for v in node.values():
            yield from json_strings(v)
    elif isinstance(node, list):
        for v in node:
            yield from json_strings(v)


def has_digit_and_letter(v):
    return any(c.isdigit() for c in v) and any(c.isalpha() for c in v)


def candidates(text):
    """Every value worth fingerprinting in one secret's plaintext.

    whole: the whole file, trimmed — always a candidate (>= MIN_LEN), even
      a low-entropy one: the file IS the secret.
    derived: KEY=value values, JSON string values, other non-empty lines,
      and every maximal [A-Za-z0-9_-] run of any of these. A derived value
      must contain a digit and a letter: env files and service-account
      JSON also hold non-secret words ("service_account", a file path,
      a secret's own name), and masking those everywhere in tool output
      would be a regression with no protection gained.
    """
    had_pem = PEM_RE.search(text) is not None
    body = PEM_RE.sub(PEM_SENTINEL, text)
    whole = text.strip()

    primary = set()
    if whole and not had_pem:
        primary.add(("whole", whole))

    for raw in body.splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or PEM_SENTINEL in line:
            continue
        v = env_value(line)
        if v is not None:
            primary.add(("derived", v.strip()))
        else:
            primary.add(("derived", strip_quotes(line)))

    stripped = text.strip()
    if stripped[:1] in "{[":
        try:
            doc = json.loads(stripped)
        except ValueError:
            doc = None
        for s in json_strings(doc):
            primary.add(("derived", s.strip()))

    out = {}
    for kind, v in primary:
        if PEM_MARKER in v:
            continue
        if kind == "whole" or v == whole:
            out[v] = "whole"
        else:
            out.setdefault(v, "derived")
        for run in RUN_RE.findall(v):
            out.setdefault(run, "derived")

    return {
        v
        for v, kind in out.items()
        if len(v) >= MIN_LEN
        and PEM_MARKER not in v
        and (kind == "whole" or has_digit_and_letter(v))
    }


def machine_token(v):
    """True if v looks like the output of a random generator.

    Applied only to secrets the reader CANNOT read (root-only). The output
    file is readable by that reader, and fast salted SHA-256 of a
    human-chosen value is offline-crackable: a GPU runs ~1e10 guesses/s,
    so anything a word list or a mask attack reaches would leak. A value
    the reader can read gains nothing from this, so it is not applied
    there.

    No language-independent estimator gives a sound entropy LOWER bound for
    human text (zxcvbn rates "correct-horse-battery-staple" ~1e20 guesses
    and an English sentence ~1e42, and knows no Swedish), so this is a
    shape rule, not an estimate:

      * >= 24 chars, token alphabet only (no whitespace, no punctuation
        beyond _ - + / = .): phrases with spaces or symbols are out;
      * then EITHER hex (UUIDs, digests) with >= 32 hex digits,
      * OR upper AND lower AND >= 3 separate digit runs (base62/base64).

    Random 40-char base62/base64 passes ~92% of the time, 64-char ~99.5%;
    a miss only means that one root-only value is not masked. A
    human-built value that passes must interleave >= 3 digit groups with
    mixed-case text over >= 24 chars, which keeps even a word-model
    attack above ~2^60 guesses.
    """
    if len(v) < 24 or not TOKEN_ALPHABET_RE.fullmatch(v):
        return False
    if HEX_RE.fullmatch(v) and sum(c != "-" for c in v) >= 32:
        return True
    return (
        any(c.isupper() for c in v)
        and any(c.islower() for c in v)
        and len(DIGIT_RUN_RE.findall(v)) >= 3
    )


def readable_by(user, paths):
    """Which paths `user` can open for reading, asked AS that user.

    A child drops to the user's uid, gid and supplementary groups and calls
    access(2), so directory modes, ACLs and group membership all count —
    no reimplementation of permission rules. Contents are never read
    there. Anything it cannot answer counts as not readable, which only
    makes the entropy rule apply more widely.
    """
    pw = pwd.getpwnam(user)
    groups = os.getgrouplist(user, pw.pw_gid)
    try:
        child = subprocess.run(
            [
                sys.executable,
                "-I",
                "-c",
                "import json,os,sys;"
                "print(json.dumps([os.access(p,os.R_OK) for p in json.load(sys.stdin)]))",
            ],
            input=json.dumps(paths),
            capture_output=True,
            text=True,
            user=pw.pw_uid,
            group=pw.pw_gid,
            extra_groups=groups,
            env={},
            cwd="/",
            check=True,
        )
        answers = json.loads(child.stdout)
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        log(f"readability probe failed ({type(e).__name__}); "
            "treating every secret as root-only")
        return None
    return {p for p, ok in zip(paths, answers) if ok is True}


def load_salt(state_dir):
    path = os.path.join(state_dir, "salt")
    try:
        with open(path) as f:
            salt = f.read().strip()
        if re.fullmatch(r"[0-9a-f]{64}", salt):
            return salt, False
        log("salt file malformed; regenerating")
    except FileNotFoundError:
        pass
    salt = secrets.token_hex(32)
    fd, tmp = tempfile.mkstemp(dir=state_dir, prefix=".salt.")
    with os.fdopen(fd, "w") as f:
        f.write(salt + "\n")
        f.flush()
        os.fsync(f.fileno())
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
    return salt, True


def write_atomic(path, data, uid, gid, mode):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".fingerprints.")
    try:
        with os.fdopen(fd, "w") as f:
            os.fchmod(f.fileno(), mode)
            os.fchown(f.fileno(), uid, gid)
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def now_iso():
    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def report(record, problem):
    """Write (problem) or clear (None) the unit-failures record.

    The record, not the unit's exit status, is how a failure reaches
    Claude: ~/.claude/hooks/unit-failure-health.py lists every record at
    SessionStart. The unit itself exits 0 on a degraded run, because a
    failed unit fails `nixos-rebuild switch`, and the auto-deploy latches
    a failed switch as a poisoned commit: a masking helper must not be
    able to stop deploys.
    """
    if problem is None:
        try:
            os.remove(record)
        except FileNotFoundError:
            pass
        return
    rec = {
        "unit": "secret-fingerprints.service",
        "result": "degraded",
        "exit_status": "0",
        "invocation_id": os.environ.get("INVOCATION_ID", ""),
        "failed_at": now_iso(),
        "summary": "Known-value secret masking is incomplete: " + problem
        + " Some agenix secret values may NOT be masked in agent output.",
        "inspect": "journalctl -u secret-fingerprints.service -n 50",
    }
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(record), prefix=".secret-fingerprints.")
    with os.fdopen(fd, "w") as f:
        os.fchmod(f.fileno(), 0o644)
        json.dump(rec, f)
        f.write("\n")
    os.replace(tmp, record)


def run(manifest, user, state_dir, out_path):
    """Generate the file. Returns a problem description, or None."""
    with open(manifest) as f:
        paths = sorted(set(json.load(f)))

    readable = readable_by(user, paths)
    probe_failed = readable is None
    readable = readable or set()
    salt, fresh = load_salt(state_dir)
    salt_bytes = bytes.fromhex(salt)

    missing = unreadable = user_secrets = root_secrets = 0
    withheld = 0
    fps = set()
    for p in paths:
        try:
            with open(p, "rb") as f:
                raw = f.read()
        except FileNotFoundError:
            missing += 1
            continue
        except OSError as e:
            unreadable += 1
            log(f"read error ({type(e).__name__})")
            continue
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError:
            # Binary secret: only its ASCII runs can surface in text output.
            text = raw.decode("latin-1")
        values = candidates(text)
        if p in readable:
            user_secrets += 1
        else:
            root_secrets += 1
            kept = {v for v in values if machine_token(v)}
            withheld += len(values) - len(kept)
            values = kept
        for v in values:
            fps.add(hashlib.sha256(salt_bytes + v.encode("utf-8")).hexdigest())

    doc = {
        "version": VERSION,
        "salt": salt,
        "min_len": MIN_LEN,
        "fingerprints": sorted(fps),
        "generated": now_iso(),
    }
    pw = pwd.getpwnam(user)
    write_atomic(out_path, json.dumps(doc) + "\n", pw.pw_uid, 0, 0o400)

    log(
        f"{len(paths)} declared secrets: {user_secrets} {user}-readable, "
        f"{root_secrets} root-only, {missing} missing, {unreadable} unreadable; "
        f"{len(fps)} fingerprints written; {withheld} root-only candidates "
        f"withheld by the entropy rule; salt {'created' if fresh else 'reused'}"
    )
    if probe_failed:
        return ("the readability probe failed, so every secret was treated "
                "as root-only and low-entropy values were withheld.")
    if missing or unreadable:
        return (f"{missing + unreadable} of {len(paths)} declared secrets "
                "could not be read (the file holds the rest).")
    return None


def main(argv):
    if len(argv) != 6:
        print(__doc__, file=sys.stderr)
        return 2
    manifest, user, state_dir, out_path, record = argv[1:]
    try:
        problem = run(manifest, user, state_dir, out_path)
    except Exception as e:  # never echo a message that may quote input
        problem = (f"the generator crashed ({type(e).__name__}); "
                   "the file is stale or absent.")
    if problem:
        log("DEGRADED: " + problem)
    try:
        report(record, problem)
    except OSError as e:
        # No record means no way to tell Claude: fail the unit after all.
        log(f"FAILED: could not write the failure record ({type(e).__name__})")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
