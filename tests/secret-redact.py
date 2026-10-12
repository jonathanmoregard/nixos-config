"""Checks for the built `secret-redact` CLI (see tests/secret-redact.nix).

Usage: python3 secret-redact.py <path to built secret-redact> <path to sh>

Every token is generated at run time (never a literal, so this file is no
gitleaks hit) and masked out of everything printed. Exit 0 = all green.
"""
from __future__ import annotations

import base64
import importlib.machinery
import importlib.util
import json
import os
import secrets
import stat
import string
import subprocess
import sys
import tempfile
import time

CLI, SH = sys.argv[1], sys.argv[2]
_loader = importlib.machinery.SourceFileLoader(
    "secret_redact", os.path.join(os.path.dirname(os.path.dirname(os.path.realpath(CLI))), "lib", "secret_redact.py"))
sr = importlib.util.module_from_spec(importlib.util.spec_from_loader("secret_redact", _loader))
_loader.exec_module(sr)

FAILURES: list[str] = []
TOKENS: list[str] = []
SCRATCH = tempfile.mkdtemp(prefix="secret-redact-test-")
ALNUM = string.ascii_letters + string.digits


def _safe(text) -> str:
    text = str(text)
    for t in TOKENS:
        text = text.replace(t, f"<TOKEN {t[:4]}…{len(t)}>")
    return text


def check(label: str, cond, detail="") -> None:
    print(f"  [{'OK ' if cond else 'FAIL'}] {label}" + (f" :: {_safe(detail)[:300]}" if detail and not cond else ""))
    if not cond:
        FAILURES.append(label)


def section(name: str) -> None:
    print(f"\n== {name} ==")


def rand(n: int, alphabet: str = ALNUM) -> str:
    """n random characters, the last a digit: gitleaks skips low-entropy values."""
    return "".join(secrets.choice(alphabet) for _ in range(n - 1)) + secrets.choice(string.digits)


def tok(kind: str = "gitlab") -> str:
    value = {
        "gitlab": lambda: "glp" + "at-" + rand(20),
        "github": lambda: "gh" + "p_" + rand(36),
        "sha": lambda: rand(40, "0123456789abcdef"),
        "fireworks": lambda: "fw_" + rand(24),
        "tavily": lambda: "tv" + "ly-dev-" + rand(32),
        "oauth": lambda: "sk-" + "ant-oat01-" + rand(95) + "AA",
    }[kind]()
    TOKENS.append(value)
    return value


def cli(texts, timeout: float = 120, args=(), raw: bytes | None = None, cwd: str | None = None):
    """(exit code, parsed stdout or None, stderr, seconds)."""
    t0 = time.monotonic()
    p = subprocess.run([CLI, *args], input=raw if raw is not None else json.dumps(
        {"texts": texts, "timeout": timeout}).encode(), capture_output=True, cwd=cwd or SCRATCH)
    out = json.loads(p.stdout) if p.returncode == 0 else None
    return p.returncode, out, p.stderr.decode(), time.monotonic() - t0


def redacted(texts, **kw) -> list[str]:
    rc, out, err, _ = cli(texts, **kw)
    if rc != 0:
        raise AssertionError(f"secret-redact exited {rc}: {err}")
    return out["texts"]


def find(texts) -> dict[str, str]:
    return sr.find_secrets(texts, gitleaks=sr.GITLEAKS, rules=sr.RULES, deadline=time.monotonic() + 120)


def fake_gitleaks(name: str, body: str) -> str:
    path = os.path.join(SCRATCH, f"fake-{name}")
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(f"#!{SH}\n{body}\n")
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
    return path


# ----------------------------------------------------------------------
section("the contract callers rely on")
check("gitleaks and the rules are pinned store paths",
      sr.GITLEAKS.startswith("/nix/store/") and sr.RULES.startswith("/nix/store/") and os.path.isfile(sr.RULES))
rc, out, err, _ = cli([])
check("no texts: exit 0, nothing back", rc == 0 and out == {"texts": [], "counts": []}, err)
benign = ["plain prose about keys and tokens", "", "commit 3f2a9c1 fixed the key rotation script"]
check("benign texts come back unchanged", redacted(benign) == benign)
t = tok()
rc, out, err, _ = cli([f"A={t}\nnext line", "nothing here"])
check("a token becomes [REDACTED:<rule>:<n>chars], counted per text under its rule",
      rc == 0 and out["texts"] == [f"A=[REDACTED:gitlab-pat:{len(t)}chars]\nnext line", "nothing here"]
      and out["counts"] == [{"gitlab-pat": 1}, {}], out)
key = rand(31) + "k"
TOKENS.append(key)
a, b = redacted([f'api_key = "{key}"', f"later, bare: {key} ."])
check("a secret found in one text is redacted in every text of the call",
      key not in a and key not in b and "[REDACTED:" in b, [a, b])

# ----------------------------------------------------------------------
section("fail closed: any fault exits 1, never echoing the input")
canary = "canary-" + rand(16)
TOKENS.append(canary)
for label, args, raw in (
        ("stdin is not JSON", (), f"{canary} not json".encode()),
        ("texts is not a list of strings", (), json.dumps({"texts": [canary, 3], "timeout": 5}).encode()),
        ("no timeout", (), json.dumps({"texts": [canary]}).encode()),
        ("missing gitleaks", ("--gitleaks", "/nonexistent/gitleaks"), None),
        ("gitleaks crashes", ("--gitleaks", fake_gitleaks("crash", "echo 'FTL broken config' >&2; exit 2")), None),
        ("report is garbage", ("--gitleaks", fake_gitleaks(
            "garbage", "echo 'not json'; echo 'INF scanned ~999999999 bytes' >&2")), None),
        ("report is not a list", ("--gitleaks", fake_gitleaks(
            "dict", "echo '{\"File\": 1}'; echo 'INF scanned ~999999999 bytes' >&2")), None),
        ("gitleaks read fewer bytes than written", ("--gitleaks", fake_gitleaks(
            "short", "echo '[]'; echo 'INF scanned ~0 bytes' >&2")), None),
        ("no read count from gitleaks", ("--gitleaks", fake_gitleaks("silent", "echo '[]'")), None),
        ("a finding in an unknown file", ("--gitleaks", fake_gitleaks(
            "unknown", "echo '[{\"File\": \"in/99.txt\", \"RuleID\": \"x\", \"Secret\": \"abcdefgh1\"}]';"
            " echo 'INF scanned ~999999999 bytes' >&2")), None),
        ("a decoded finding outside its file", ("--gitleaks", fake_gitleaks(
            "decoded", "echo '[{\"File\": \"in/0.txt\", \"RuleID\": \"x\", \"Tags\": [\"decoded:base64\"],"
            " \"StartLine\": 99}]'; echo 'INF scanned ~999999999 bytes' >&2")), None),
):
    rc, out, err, _ = cli([f"text with {canary}"], timeout=10, args=args, raw=raw)
    check(f"{label}: exit 1 with a reason", rc == 1 and out is None and err.startswith("secret-redact: "), err)
    check(f"{label}: the reason carries no input", canary not in err, err)
rc, _, err, secs = cli([f"text with {canary}"], timeout=0.5, args=("--gitleaks", fake_gitleaks("slow", "sleep 5")))
check(f"gitleaks past the timeout: exit 1 in {secs:.1f}s", rc == 1 and "timed out" in err and secs < 4, err)
rc, _, err, _ = cli([f"text with {canary}"], timeout=-1)
check("no time left: exit 1", rc == 1, err)

# ----------------------------------------------------------------------
section("binary-type sniffing never skips a text")
# The last two put a magic at a fixed FILE offset (tar at 257, ISO 9660 at 32769),
# past the header, so only the header's own type keeps them from being sniffed.
for prefix in ("%PDF-1.4", "%!PS-Adobe-3.0", "{\\rtf1", "MZ", "SQLite format 3",
               "y" * (257 - len(sr.HEADER)) + "ustar", "z" * (32769 - len(sr.HEADER)) + "CD001"):
    t = tok()
    check(f"a text starting {prefix[:16]!r} ({len(prefix)} chars) is scanned", t not in redacted([f"{prefix}\n{t}"])[0])

# ----------------------------------------------------------------------
section("each text is judged alone")
sha = tok("sha")
alone = redacted([f"commit {sha} merged"])[0]
check("a keyword in one text does not switch a rule on for another",
      redacted(["notes about sourcegraph search", f"commit {sha} merged"])[1] == alone)
check("(the same rule does fire when its keyword is in the text itself)",
      sha not in redacted([f"sourcegraph {sha}"])[0])

# ----------------------------------------------------------------------
section("pieces: one gitleaks read each, overlapping")
step = sr.PIECE_BYTES - sr.OVERLAP_BYTES
for name, n in (("empty", 0), ("one byte", 1), ("exactly one piece", sr.PIECE_BYTES),
                ("one byte over", sr.PIECE_BYTES + 1), ("400 KB", 400_000)):
    data = os.urandom(n)
    ps = sr.pieces(data)
    check(f"{name}: HEADER + any piece fits one gitleaks read (100,000 bytes)",
          max(len(sr.HEADER + p) for p in ps) <= 100_000)
    check(f"{name}: consecutive pieces overlap by {sr.OVERLAP_BYTES} bytes",
          all(ps[i][step:] == ps[i + 1][: sr.OVERLAP_BYTES] for i in range(len(ps) - 1)))
    check(f"{name}: pieces cover the data",
          ps[0] == data[: len(ps[0])] and data.endswith(ps[-1])
          and len(ps) == max(1, -(-(n - sr.OVERLAP_BYTES) // step)))
tokens = [tok() for _ in range(12000)]
t0 = time.monotonic()
found = find([" ".join(tokens)])
# About 1 random token in 240,000 is rejected by gitleaks' own rule even alone;
# only a token the batch misses but a single-text scan catches is a cut loss.
missed = [t for t in tokens if t not in found and t in find([t])]
check(f"12,000 tokens on one line: none lost to a piece cut ({time.monotonic() - t0:.1f}s)", not missed, len(missed))

# ----------------------------------------------------------------------
section("armored private keys")
key_lines = ["".join(secrets.choice(ALNUM + "+/") for _ in range(64)) for _ in range(3200)]
TOKENS.extend(key_lines)


def armored(kind: str, lines: list[str], last: str = "Ab3+/x==", end: bool = True) -> str:
    block = " BLOCK" if kind == "PGP" else ""
    out = f"-----BEGIN {kind} " + f"PRIVATE KEY{block}-----\n" + "\n".join(lines) + f"\n{last}\n"
    return out + (f"-----END {kind} " + f"PRIVATE KEY{block}-----" if end else "")


big = armored("PGP", key_lines, last="=Xy4Z")
for label, text, keep in (
        ("a 29 KB key across two piece boundaries",
         "x" * 75_000 + "\n" + armored("RSA", key_lines[:460]) + "\ntrailing prose\n", "trailing prose"),
        (f"a {len(big) // 1000} KB block across {len(sr.pieces(big.encode()))} pieces",
         "x" * 10_000 + "\n" + big + "\ntrailing prose\n", "trailing prose"),
        ("a BEGIN with no END: redacted to the end of the text", "head\n" + big[:150_000], "head\n"),
        ("an END-only tail with a short last line",
         "\n".join(key_lines[:20]) + "\nAb3+/x==\n-----END RSA " + "PRIVATE KEY-----\nafter\n", "\nafter\n"),
        ("an END-only PGP tail with its =CRC line",
         "\n".join(key_lines[:20]) + "\n=Xy4Z\n-----END PGP " + "PRIVATE KEY BLOCK-----\nafter\n", "\nafter\n")):
    out = redacted([text])[0]
    check(f"{label}: no body line survives, the text around it does",
          not any(line in out for line in key_lines) and keep in out, out[-160:])
prose = "Rotate the private key in the vault; -----BEGIN is not a header here.\n"
check("prose about keys is not a key", redacted([prose])[0] == prose)

# ----------------------------------------------------------------------
section("rules for formats gitleaks lacks: on a token, not inside a word or a blob")


def b64(n: int) -> str:
    return base64.b64encode(os.urandom(n)).decode()


def hits(text: str) -> set[str]:
    return set(find([text]).values())


for rule, value in (("fireworks-api-key", tok("fireworks")), ("tavily-api-key", tok("tavily")),
                    ("anthropic-oauth-token", tok("oauth"))):
    either = {rule, "known-prefix-token"}
    for label, text in (("env assignment", f"KEY={value}\n"), ("quoted value", f'key: "{value}"'),
                        ("start of input", value)):
        check(f"{rule}: fires on {label}", either & hits(text))
    for sep in ("/", "+", ""):
        check(f"{rule}: does NOT fire mid-base64 (after {sep or 'an alnum char'!r})",
              not either & hits(b64(60)[:40] + sep + value + b64(30)))
for label, value in (("truncated fine-grained PAT", "github" + "_pat_11" + rand(41)),
                     ("short classic PAT", "gh" + "p_" + rand(20)),
                     ("Anthropic admin key", "sk-" + "ant-admin01-" + rand(40)),
                     ("OpenAI legacy key", "sk-" + rand(48)),
                     ("short JWT", "eyJ" + rand(10) + ".eyJ" + rand(10) + "." + rand(10))):
    TOKENS.append(value)
    check(f"known-prefix-token: fires on a {label}", hits(f"value: {value}\n"))
for label, text in (("inside a word", "task-" + rand(30)), ("mid-base64", b64(30)[:20] + "+gh" + "p_" + rand(30)),
                    ("a short identifier", "test_github" + "_pat_redacted")):
    check(f"known-prefix-token: does NOT fire {label}", "known-prefix-token" not in hits(text))

# ----------------------------------------------------------------------
section("findings: decoded runs, idempotency")
gh = tok("github")
encoded = base64.b64encode(f"user:{gh}".encode()).decode()
out = redacted([f"Authorization: Basic {encoded} tail"])[0]
check("a decoded finding redacts the encoded run on its line, nothing else",
      encoded not in out and out.startswith("Authorization: Basic [REDACTED:") and out.endswith("] tail"), out)
gx = "GOC" + "SPX-" + rand(28)
TOKENS.append(gx)
out = redacted([f"Authorization: Basic {encoded} {gx}"])[0]
check("a marker next to a decoded run is not taken for an encoded run",
      "[REDACTED:[REDACTED:" not in out and out.count("[REDACTED:") == 2, out)
mixed = [f"key {tok()} and {gh}\n{encoded}", f"Authorization: Basic {encoded} {gx}", big[:5000]]
once = redacted(mixed)
check("redacting the output again changes nothing (idempotent)", redacted(once) == once)

# ----------------------------------------------------------------------
section("applying findings: overlaps merge, cap, deadline")


def apply(text, targets):
    counts: dict[str, int] = {}
    return sr.redact(text, targets, counts, time.monotonic() + 60), counts


check("every occurrence of every target is replaced",
      apply("a SECRET1x b SECRET1x c", {"SECRET1x": "r"}) == ("a [REDACTED:r:8chars] b [REDACTED:r:8chars] c", {"r": 2}))
check("overlapping targets become one marker, named by the longest at its start",
      apply("xx ABCDEFGH yy", {"ABCDEF": "a", "DEFGH": "b", "ABC": "c"})[0] == "xx [REDACTED:a:8chars] yy")
check("overlapping occurrences of one target leave nothing behind",
      apply("aaaaa", {"aaa": "r"})[0] == "[REDACTED:r:5chars]")
check("no targets, or an empty one: text unchanged", apply("plain", {"": "r"})[0] == "plain")
check("adjacent targets keep separate markers",
      apply("AAAABBBB", {"AAAA": "a", "BBBB": "b"})[0] == "[REDACTED:a:4chars][REDACTED:b:4chars]")
many = [tok() for _ in range(sr.MAX_TARGETS)]
text = "".join(f"token: {t}\n" for t in many) + ("the quick brown fox jumps over the lazy dog " * 20 + "\n") * 3500
rc, out, err, secs = cli([text])
check(f"{sr.MAX_TARGETS} distinct secrets + 3 MB: all redacted in {secs:.1f}s (< 8 s)",
      rc == 0 and not any(t in out["texts"][0] for t in many) and secs < 8, err)
rc, out, err, _ = cli([" ".join(many + [tok() for _ in range(50)])])
check(f"more than {sr.MAX_TARGETS} distinct secrets: exit 1, naming the limit", rc == 1 and "distinct secrets" in err, err)
flood = os.path.join(SCRATCH, "flood.json")
with open(flood, "w", encoding="utf-8") as fh:
    json.dump([{"File": "in/0.txt", "RuleID": "flood", "Secret": "a" * n} for n in range(20, 1020)], fh)
rc, _, err, secs = cli(["a" * 2_000_000], timeout=2, args=(
    "--gitleaks", fake_gitleaks("flood", f"cat {flood}; echo 'INF scanned ~999999999 bytes' >&2")))
check(f"applying findings honours the timeout: exit 1 in {secs:.1f}s", rc == 1 and secs < 4 and "timeout" in err, err)

# ----------------------------------------------------------------------
section("nothing can silence a finding")
ignore_dir = os.path.join(SCRATCH, "with-ignore-file")
os.makedirs(ignore_dir)
t = tok()
with open(os.path.join(ignore_dir, ".gitleaksignore"), "w", encoding="utf-8") as fh:
    fh.write("".join(f"{p}gitlab-pat:{n}\n" for p in ("", ":", "in/0.txt:") for n in (1, 2, 3)))
check("a .gitleaksignore in the caller's cwd is not read", t not in redacted([t], cwd=ignore_dir)[0])
t = tok()
check("a gitleaks:allow comment does not hide a token", t not in redacted([f"{t}  # gitleaks" + ":allow"])[0])

# ----------------------------------------------------------------------
section("Summary")
if FAILURES:
    print(f"\nFAIL: {len(FAILURES)} failure(s):")
    for f in FAILURES:
        print(f"  - {f}")
    sys.exit(1)
print("\nall green")
