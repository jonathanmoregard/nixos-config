#!/usr/bin/env python3
"""offline-ai: a small assistant for when the internet is down.

Talks to a local llama-server (OpenAI-compatible chat API) and gives the
model read-only tools over things that are already on this machine: the
NixOS and home-manager option reference, the system flake, systemd unit
state, and local document folders. It never changes system state itself;
it proposes commands and the operator runs them.

Standard library only, so it keeps working when nothing can be fetched.
"""

import argparse
import difflib
import filecmp
import html
import html.parser
import http.client
import json
import math
import os
import re
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

URL = os.environ.get("OFFLINE_AI_URL", "http://127.0.0.1:8717")
UNIT = os.environ.get("OFFLINE_AI_UNIT", "offline-ai-llm.service")
MODEL = os.environ.get("OFFLINE_AI_MODEL", "")
CONFIG_ROOT = Path(os.environ.get("OFFLINE_AI_CONFIG_ROOT", "/etc/nixos"))
FLAKE_HOST = os.environ.get("OFFLINE_AI_FLAKE_HOST", "")
OPTION_FILES = {
    "nixos": os.environ.get("OFFLINE_AI_NIXOS_OPTIONS", ""),
    "home-manager": os.environ.get("OFFLINE_AI_HM_OPTIONS", ""),
}
LIBRARY_URL = os.environ.get("OFFLINE_AI_LIBRARY_URL", "http://127.0.0.1:8718")
# Units that give way while the big model is loaded, as "system" and "user"
# lists (timers before the services they start). Only those that were running
# are stopped, and exactly those are started again afterwards.
EVICT = {
    False: os.environ.get("OFFLINE_AI_EVICT_SYSTEM", "").split(),
    True: os.environ.get("OFFLINE_AI_EVICT_USER", "").split(),
}
EVICTED = Path(os.environ.get("XDG_RUNTIME_DIR") or f"/tmp/offline-ai-{os.getuid()}") / "offline-ai" / "evicted.json"
# When the listed units are not enough, other large units of this user give
# way too, largest first, until the model fits: frozen with their memory
# pushed to swap, or, when they hold GPU memory (pinned RAM on this APU, which
# only goes with the process), stopped and started again afterwards. Desktop
# applications, terminals, the session bus and whatever this CLI itself runs
# inside are never touched.
MEMINFO = Path(os.environ.get("OFFLINE_AI_MEMINFO", "/proc/meminfo"))
CGROUP_ROOT = Path(os.environ.get("OFFLINE_AI_CGROUP_ROOT", "/sys/fs/cgroup"))
PROC = Path(os.environ.get("OFFLINE_AI_PROC", "/proc"))  # where GPU use is read from
USER_CGROUP = os.environ.get("OFFLINE_AI_USER_CGROUP", "")  # the user manager's cgroup; found from /proc by default
FREEZE_MIN = 512 * 2**20  # units holding less than this are not worth freezing
HEADROOM = 2**30  # free memory left over once the model is in
NEVER_FREEZE = re.compile(r"^(app-|kitty-|tmux-|dbus|offline-ai|init\.scope|session-)")
LIBRARY_UNIT = os.environ.get("OFFLINE_AI_LIBRARY_UNIT", "offline-ai-library.service")


def parse_collections(spec):
    """`label=/dir:label=/dir`; a bare directory is labelled with its own name."""
    collections = {}
    for item in spec.split(":"):
        label, sep, path = item.partition("=")
        if item and not sep:
            label, path = Path(item).name, item
        if path:
            collections[label] = Path(path)
    return collections


COLLECTIONS = parse_collections(os.environ.get("OFFLINE_AI_DOC_DIRS", ""))
DOC_DIRS = list(COLLECTIONS.values())
CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "offline-ai"

MAX_STEPS = 8
MAX_TOOL_CHARS = 6000
UNIT_NAME = re.compile(r"^[A-Za-z0-9@:._\\-]+$")
WORD = re.compile(r"[a-z0-9]+")


def clip(text, limit=MAX_TOOL_CHARS):
    if len(text) <= limit:
        return text
    return text[:limit] + f"\n[... truncated, {len(text) - limit} more characters]"


# ---------------------------------------------------------------- options

_options = {}


def load_options(source):
    if source not in OPTION_FILES:
        raise ValueError(f"unknown source {source!r}; use 'nixos' or 'home-manager'")
    if source not in _options:
        path = OPTION_FILES[source]
        if not path or not os.path.exists(path):
            raise ValueError(f"the {source} option reference is not installed on this machine")
        with open(path, encoding="utf-8") as fh:
            _options[source] = json.load(fh)
    return _options[source]


def render(value):
    if isinstance(value, dict) and "text" in value:
        return value["text"]
    return json.dumps(value)


def clean_description(text):
    text = re.sub(r"\{[a-z]+\}`([^`]*)`", r"`\1`", text or "")
    return text.strip()


STOPWORDS = frozenset(
    "a about after all also am an and any are as at be both but by can code do does each every for "
    "from get give have how i if in including into is it its me my nix nixos no not now of on only "
    "option options or out plus right so some something still than that the them then there this to "
    "up use using value want what when where which while why with without write".split()
)
# allowedTCPPorts -> allowed TCP Ports
CAMEL = re.compile(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")
_option_index = {}


def stem(word):
    if len(word) > 3 and word.endswith("s") and not word.endswith(("ss", "us", "is")):
        return word[:-1]
    return word


def keywords(text):
    """Distinct search terms of a free-text question, stop words removed."""
    seen = []
    for word in WORD.findall(text.lower()):
        if word in STOPWORDS:
            continue
        word = stem(word)
        if len(word) > 1 and word not in seen:
            seen.append(word)
    return seen


def option_index(source):
    if source not in _option_index:
        entries = []
        for name, opt in load_options(source).items():
            segments = frozenset(stem(w) for w in WORD.findall(CAMEL.sub(" ", name).lower()))
            described = frozenset(stem(w) for w in WORD.findall((opt.get("description") or "").lower()))
            entries.append((name, segments, described))
        _option_index[source] = entries
    return _option_index[source]


def rank_options(query, source, limit):
    return rank_entries(option_index(source), query, limit)


def rank_entries(entries, query, limit):
    """Names ranked by rare-term matches; a name hit outweighs a description hit."""
    terms = keywords(query)
    weights = {}
    for term in terms:
        hits = sum(1 for _, segments, described in entries if term in segments or term in described)
        if hits:
            weights[term] = math.log(1 + len(entries) / hits)
    scored = []
    for name, segments, described in entries:
        score = sum(w * (4 if t in segments else 1 if t in described else 0) for t, w in weights.items())
        if score:
            scored.append((-score, len(name), name))
    scored.sort()
    return [name for _, _, name in scored[:limit]]


def search_options(query, source="nixos", limit=10):
    options = load_options(source)
    if not keywords(query):
        return "empty query"
    lines = []
    for name in rank_options(query, source, max(1, min(int(limit), 25))):
        opt = options[name]
        first = clean_description(opt.get("description")).split("\n")[0]
        lines.append(f"{name} :: {opt.get('type', '?')} -- {first[:160]}")
    return "\n".join(lines) or f"no {source} option matches {query!r}"


def show_option(name, source="nixos"):
    options = load_options(source)
    name = name.strip().rstrip(".")
    opt = options.get(name)
    if opt is None:
        children = sorted(n for n in options if n.startswith(name + "."))
        if len(children) > 40:
            # Too many to list: show the next level of the tree so it can be browsed.
            depth = name.count(".") + 1
            branches = {}
            for child in children:
                branch = ".".join(child.split(".")[: depth + 1])
                branches[branch] = branches.get(branch, 0) + 1
            listing = [f"{b}  ({n} options)" if n > 1 else b for b, n in sorted(branches.items())]
            return f"{name} has {len(children)} options. Next level:\n" + "\n".join(listing[:150])
        # Free-form options (home-manager's systemd units, settings attrsets)
        # document their shape on an ancestor, so show the nearest one.
        parent = name
        while "." in parent and parent not in options:
            parent = parent.rsplit(".", 1)[0]
        inherited = ""
        if parent in options:
            inherited = (f"\n\nNearest documented option above it (free-form values below "
                         f"this point follow its description and example):\n{show_option(parent, source)}")
        if children:
            return f"{name} is not an option itself. Options under it:\n" + "\n".join(children) + inherited
        near = difflib.get_close_matches(name, options.keys(), n=8, cutoff=0.6)
        hint = ("\nClosest names:\n" + "\n".join(near)) if near else ""
        return f"NO SUCH OPTION in {source}: {name}{hint}{inherited}"
    parts = [f"{name}", f"type: {opt.get('type', '?')}"]
    if "default" in opt:
        parts.append(f"default: {render(opt['default'])}")
    if "example" in opt:
        parts.append(f"example: {render(opt['example'])}")
    parts.append("description: " + clean_description(opt.get("description")))
    if opt.get("declarations"):
        parts.append("declared in: " + ", ".join(map(str, opt["declarations"])))
    return "\n".join(parts)


# ----------------------------------------------------------- config files


def allowed_path(path):
    resolved = Path(path).expanduser().resolve()
    for root in [CONFIG_ROOT, *DOC_DIRS]:
        try:
            resolved.relative_to(root.resolve())
            return resolved
        except ValueError:
            continue
    raise ValueError(f"{path} is outside the readable roots ({CONFIG_ROOT} and the document folders)")


def search_config(pattern):
    try:
        regex = re.compile(pattern, re.IGNORECASE)
    except re.error as exc:
        return f"bad regular expression: {exc}"
    hits = []
    for path in sorted(CONFIG_ROOT.rglob("*.nix")):
        if ".git" in path.parts:
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for number, line in enumerate(text.splitlines(), 1):
            if regex.search(line):
                hits.append(f"{path.relative_to(CONFIG_ROOT)}:{number}: {line.strip()[:200]}")
                if len(hits) >= 40:
                    return "\n".join(hits) + "\n[more matches not shown; narrow the pattern]"
    return "\n".join(hits) or f"no match for {pattern!r} under {CONFIG_ROOT}"


def read_file(path, start=1, lines=120):
    target = Path(path)
    if not target.is_absolute():
        target = CONFIG_ROOT / target
    target = allowed_path(target)
    content = target.read_text(encoding="utf-8", errors="replace").splitlines()
    start = max(1, int(start))
    chunk = content[start - 1 : start - 1 + max(1, min(int(lines), 200))]
    body = "\n".join(f"{start + i}: {line}" for i, line in enumerate(chunk))
    return f"{target} (lines {start}-{start + len(chunk) - 1} of {len(content)})\n{body}"


# ---------------------------------------------------------------- systemd


def run(argv, timeout=15):
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    except FileNotFoundError:
        return f"{argv[0]} is not available"
    except subprocess.TimeoutExpired:
        return f"{' '.join(argv)} timed out after {timeout}s"
    return (done.stdout + done.stderr).strip() or f"(no output, exit {done.returncode})"


def flag(value):
    """A model may send a boolean as a string; "false" must not count as true."""
    if isinstance(value, str):
        return value.strip().lower() in ("true", "1", "yes")
    return bool(value)


def scope(user):
    return ["--user"] if flag(user) else []


def check_unit(unit):
    if not UNIT_NAME.match(unit):
        raise ValueError(f"not a valid unit name: {unit!r}")
    return unit


def unit_status(unit, user=False):
    return run(["systemctl", *scope(user), "status", "--no-pager", "-n", "15", "--", check_unit(unit)])


def unit_logs(unit, user=False, lines=40):
    count = str(max(1, min(int(lines), 120)))
    return run(["journalctl", *scope(user), "-u", check_unit(unit), "-b", "-n", count, "--no-pager"])


def matching_units(needle, user):
    out = run(["systemctl", *scope(user), "list-units", "--all", "--plain", "--no-legend", "--no-pager"])
    files = run(["systemctl", *scope(user), "list-unit-files", "--plain", "--no-legend", "--no-pager"])
    hits = [re.sub(r" {2,}", "  ", line) for line in out.splitlines() if needle in line.lower()]
    known = {line.split()[0] for line in hits if line.split()}
    for line in files.splitlines():
        fields = line.split()
        if fields and needle in fields[0].lower() and fields[0] not in known:
            hits.append(f"{fields[0]} (not loaded; unit file state: {fields[1] if len(fields) > 1 else '?'})")
    return hits


def list_units(match, user=None):
    """Units whose name contains the text; both system and user units unless one scope is asked for."""
    needle = str(match).lower()
    scopes = [False, True] if user is None else [flag(user)]
    parts = []
    for scoped in scopes:
        hits = matching_units(needle, scoped)
        label = "user units (systemctl --user)" if scoped else "system units"
        parts.append(f"## {label}\n" + ("\n".join(hits[:30]) if hits else "none"))
    return "\n\n".join(parts)


# ------------------------------------------------------------ diagnostics


def quiet(argv, timeout):
    """stdout of a read-only command; None when it is missing or too slow."""
    try:
        done = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                              text=True, errors="replace", timeout=timeout)
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    return done.stdout


def megabytes(count):
    return f"{count / 1024:.1f} GiB" if count >= 1024 else f"{count} MiB"


def absolute(path):
    """An absolute path: a model-supplied `-delete` must reach find as a path, never an expression."""
    return str(Path(str(path)).expanduser().resolve())


def disk_usage(path="/"):
    target = absolute(path)
    free = run(["df", "-h", "--output=source,fstype,size,used,avail,pcent,target", "--", target])
    listing = quiet(["du", "-x", "-d", "1", "-BM", "--", target], 120)
    if listing is None:
        return f"{free}\n\nMeasuring {target} took more than two minutes; ask for a narrower path."
    sizes = []
    for line in listing.splitlines():
        size, _, name = line.partition("\t")
        if size.endswith("M") and size[:-1].isdigit():
            sizes.append((int(size[:-1]), name))
    sizes.sort(reverse=True)
    rows = "\n".join(f"{megabytes(size):>10}  {name}" for size, name in sizes[:25])
    return (f"{free}\n\nLargest entries directly under {target} (same filesystem only; "
            f"folders this user cannot read are not counted):\n{rows or '(nothing readable)'}")


def big_files(path="~", min_mb=200):
    target = absolute(path)
    floor = max(1, int(min_mb))
    listing = quiet(["find", target, "-xdev", "-type", "f", "-size", f"+{floor}M", "-printf", "%s\t%p\n"], 120)
    if listing is None:
        return f"Searching {target} took more than two minutes; ask for a narrower path."
    files = []
    for line in listing.splitlines():
        size, _, name = line.partition("\t")
        if size.isdigit():
            files.append((int(size), name))
    files.sort(reverse=True)
    rows = "\n".join(f"{megabytes(size // (1024 * 1024)):>10}  {name}" for size, name in files[:30])
    return rows or f"no file larger than {floor} MiB under {target}"


def processes(sort="memory"):
    key = "-pcpu" if str(sort).lower().startswith("c") else "-rss"
    listing = quiet(["ps", "-eo", "pid,user:12,pcpu,pmem,rss:10,etime,args", f"--sort={key}"], 15)
    if listing is None:
        return "ps is not available"
    mine = {str(os.getpid()), str(os.getppid())}
    rows = []
    for line in listing.splitlines()[:16]:
        row = line[:170]
        if line.split()[:1] and line.split()[0] in mine:
            row += "   <- this assistant itself"
        rows.append(row)
    note = ""
    if any("llama-server" in row for row in rows):
        note = ("\n\nNote: llama-server is this assistant's own model. Its memory and CPU use are expected "
                "while it answers and are released by `offline-ai down`; it is not the cause being asked about.")
    return "\n".join(rows) + "\n\n" + run(["free", "-h"]) + "\n\nload: " + run(["cat", "/proc/loadavg"]) + note


def network_status():
    parts = []
    for title, argv in (
        ("devices", ["nmcli", "-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device"]),
        ("addresses", ["ip", "-brief", "address"]),
        ("routes", ["ip", "route"]),
        ("radio switches", ["nmcli", "radio"]),
        ("wifi networks in range (last scan)",
         ["nmcli", "-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "no"]),
        ("dns", ["cat", "/etc/resolv.conf"]),
    ):
        text = run(argv, timeout=10)
        parts.append(f"## {title}\n" + "\n".join(text.splitlines()[:20]))
    return "\n\n".join(parts)


# -------------------------------------------------------------- man pages

MAN_NAME = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_.:+@\[-]*$")
MAN_SECTION = re.compile(r"^[0-9][A-Za-z0-9]*$")
MAN_FILE = re.compile(r"^(?P<name>.+)\.(?P<section>[0-9][A-Za-z0-9]*)(?:\.(?:gz|bz2|xz|zst))?$")
_man_index = None


def man_index(rebuild=False):
    """(name, section, one-line description) for every installed man page."""
    global _man_index
    if _man_index is not None and not rebuild:
        return _man_index
    roots = [os.path.realpath(d) for d in (quiet(["manpath"], 10) or "").strip().split(":") if d]
    stamp = "|".join(roots)
    cache_path = CACHE_DIR / "man.json"
    if cache_path.exists() and not rebuild:
        try:
            cached = json.loads(cache_path.read_text(encoding="utf-8"))
            if cached.get("stamp") == stamp:
                _man_index = [tuple(entry) for entry in cached["entries"]]
                return _man_index
        except (OSError, ValueError, KeyError) as exc:
            print(f"[index] manual page cache unreadable ({exc}); rebuilding it", file=sys.stderr)
    files, seen = {}, set()
    for root in roots:
        for path in sorted(Path(root).glob("man*/*")):
            match = MAN_FILE.match(path.name)
            if match and (match["name"], match["section"]) not in seen:
                seen.add((match["name"], match["section"]))
                files[str(path)] = (match["name"], match["section"])
    described = {}
    paths = list(files)
    for offset in range(0, len(paths), 400):
        for line in (quiet(["lexgrog", *paths[offset:offset + 400]], 120) or "").splitlines():
            path, sep, text = line.partition(': "')
            if sep and path in files and path not in described:
                described[path] = text.rstrip('"').partition(" - ")[2]
    entries = sorted((name, section, described.get(path, "")) for path, (name, section) in files.items())
    if entries:
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = cache_path.with_suffix(".tmp")
        tmp.write_text(json.dumps({"stamp": stamp, "entries": entries}), encoding="utf-8")
        tmp.replace(cache_path)
    _man_index = entries
    return entries


def search_man(query, limit=12):
    entries = man_index()
    if not entries:
        return "no man pages are installed"
    described = {f"{name}({section})": text for name, section, text in entries}
    indexed = [(label, frozenset(stem(w) for w in WORD.findall(label.lower())),
                frozenset(stem(w) for w in WORD.findall(text.lower()))) for label, text in described.items()]
    ranked = rank_entries(indexed, query, max(1, min(int(limit), 25)))
    return "\n".join(f"{label} -- {described[label]}" for label in ranked) or f"no man page matches {query!r}"


def read_man(name, section="", search="", start=1, lines=150):
    name, section = str(name).strip(), str(section).strip()
    if not MAN_NAME.match(name):
        raise ValueError(f"not a man page name: {name!r}")
    if section and not MAN_SECTION.match(section):
        raise ValueError(f"not a manual section (1-9, e.g. 8 or 3p): {section!r}")
    argv = ["man", "-P", "cat", "--", *([section] if section else []), name]
    try:
        done = subprocess.run(argv, capture_output=True, text=True, errors="replace", timeout=30,
                              env={**os.environ, "MANWIDTH": "100", "MAN_KEEP_FORMATTING": "0"})
    except FileNotFoundError:
        return "man is not available"
    except subprocess.TimeoutExpired:
        return "man timed out"
    if done.returncode != 0 or not done.stdout.strip():
        close = difflib.get_close_matches(name, [entry[0] for entry in man_index()], n=6, cutoff=0.6)
        hint = ("; similar pages: " + ", ".join(close)) if close else ""
        return f"no man page for {name}{hint}"
    body = re.sub(r".\x08|\x1b\[[0-9;]*m", "", done.stdout).splitlines()
    if search:
        # Long pages are reached by content, not by paging: every passage that mentions the text.
        needles = [n.strip() for n in str(search).lower().split("|") if n.strip()]
        hits = [i for i, line in enumerate(body) if any(n in line.lower() for n in needles)]
        if not hits:
            return f"{name}: no line mentions {search!r} ({len(body)} lines; try another word or read from start=1)"
        out, last = [], -1
        for hit in hits:
            first = max(hit - 2, last + 1)
            if first > hit + 8 or len(out) > 110:
                continue
            if first > last + 1:
                out.append(f"--- line {first + 1}")
            out.extend(body[first : hit + 9])
            last = hit + 8
        return f"{name}: {len(hits)} lines mention {search!r}\n" + "\n".join(out)
    start = max(1, int(start))
    chunk = body[start - 1 : start - 1 + max(1, min(int(lines), 250))]
    footer = ""
    if start - 1 + len(chunk) < len(body):
        footer = f"\n[more: call again with start={start + len(chunk)}]"
    return f"{name} (lines {start}-{start + len(chunk) - 1} of {len(body)})\n" + "\n".join(chunk) + footer


# -------------------------------------------------------------- documents


class Sections(html.parser.HTMLParser):
    """Visible text of an HTML page, cut at h1-h3 so a heading stays with its text."""

    SKIP = {"script", "style", "nav", "head", "svg"}
    BREAK = {"h1", "h2", "h3"}
    BLOCK = {"p", "div", "li", "tr", "br", "pre", "dt", "dd", "table", "section", "h1", "h2", "h3", "h4", "h5", "h6"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.sections, self.skipping = [[]], 0

    def handle_starttag(self, tag, attrs):
        if tag in self.SKIP:
            self.skipping += 1
        elif tag in self.BREAK:
            self.sections.append([])
        if tag in self.BLOCK:
            self.sections[-1].append("\n")

    def handle_endtag(self, tag):
        if tag in self.SKIP and self.skipping:
            self.skipping -= 1
        if tag in self.BLOCK:
            self.sections[-1].append("\n")

    def handle_data(self, data):
        if not self.skipping:
            self.sections[-1].append(data)


def html_sections(text):
    parser = Sections()
    parser.feed(text)
    parser.close()
    out = []
    for parts in parser.sections:
        section = re.sub(r"[ \t\r\f\v]+", " ", "".join(parts))
        section = re.sub(r"\s*\n\s*", "\n", section).strip()
        if section:
            out.append(section)
    return out


def chunked(sections, size=3500, floor=600):
    """Merge short neighbours and split long sections, so every page is a readable size."""
    pages, pending = [], ""
    for section in sections:
        pending = f"{pending}\n\n{section}" if pending else section
        if len(pending) >= floor:
            pages.extend(pending[i : i + size] for i in range(0, len(pending), size))
            pending = ""
    if pending:
        pages.append(pending)
    return pages


TEXT_SUFFIXES = (".txt", ".md")
HTML_SUFFIXES = (".html", ".htm", ".xhtml")
# The option reference as one HTML page is 25 MB; the option tools cover it.
MAX_TEXT_BYTES = 8 * 1024 * 1024


def extract_pages(path):
    """Pages of one document; None when it could not be read, so the failure is not cached."""
    suffix = path.suffix.lower()
    if suffix == ".pdf":
        try:
            done = subprocess.run(
                ["pdftotext", "-layout", str(path), "-"], capture_output=True, text=True, timeout=300
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return None
        return done.stdout.split("\f") if done.returncode == 0 else None
    text = path.read_text(encoding="utf-8", errors="replace")
    if suffix in HTML_SUFFIXES:
        return chunked(html_sections(text))
    return [text[i : i + 3000] for i in range(0, len(text), 3000)]


def doc_files():
    """(document id, path) for every readable document; the id starts with its collection."""
    for label, root in COLLECTIONS.items():
        if not root.is_dir():
            continue
        by_size = {}
        for path in sorted(root.rglob("*")):
            suffix = path.suffix.lower()
            if not path.is_file():
                continue
            size = path.stat().st_size
            if suffix == ".pdf" or (suffix in TEXT_SUFFIXES + HTML_SUFFIXES and size <= MAX_TEXT_BYTES):
                # Manuals ship the same page under two names (index.html, manual.html).
                if any(filecmp.cmp(path, other, shallow=False) for other in by_size.get(size, [])):
                    continue
                by_size.setdefault(size, []).append(path)
                yield f"{label}/{path.relative_to(root)}", path


_doc_index = None


def load_doc_index(rebuild=False):
    """Pages of every document by id, extracted once and cached by path, size and mtime."""
    global _doc_index
    if _doc_index is not None and not rebuild:
        return _doc_index
    index_path = CACHE_DIR / "docs.json"
    cached = {}
    if index_path.exists() and not rebuild:
        try:
            cached = json.loads(index_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            cached = {}
    fresh, index, changed = {}, {}, False
    for name, path in doc_files():
        stat = path.stat()
        stamp = f"{stat.st_size}:{int(stat.st_mtime)}"
        entry = cached.get(str(path))
        if not isinstance(entry, dict) or entry.get("stamp") != stamp:
            if not changed:
                print("[index] reading new or changed documents...", file=sys.stderr)
            pages = extract_pages(path)
            changed = True
            if pages is None:
                print(f"[index] could not read {name}", file=sys.stderr)
                continue
            entry = {"stamp": stamp, "pages": pages}
        fresh[str(path)] = entry
        index[name] = entry["pages"]
    if changed or set(fresh) != set(cached):
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = index_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(fresh), encoding="utf-8")
        tmp.replace(index_path)
    _doc_index = index
    return index


_doc_words = {}


def page_words(name, number, text):
    key = (name, number)
    if key not in _doc_words:
        _doc_words[key] = [stem(w) for w in WORD.findall(text.lower())]
    return _doc_words[key]


def search_docs(query, collection="", limit=4):
    index = load_doc_index()
    collection = str(collection or "").strip().strip("/")
    if collection and collection not in COLLECTIONS:
        return f"no collection {collection!r}; available: {', '.join(COLLECTIONS) or 'none'}"
    # Stemmed on both sides, so "burn" finds the page headed "BURNS".
    terms = set(keywords(query))
    if not terms:
        return "empty query"
    pages = []
    for name, texts in index.items():
        if collection and not name.startswith(collection + "/"):
            continue
        for number, text in enumerate(texts, 1):
            words = page_words(name, number, text)
            if words:
                pages.append((name, number, text, words))
    if not pages:
        return "no local documents are indexed"
    doc_freq = {t: sum(1 for p in pages if t in set(p[3])) for t in terms}
    average = sum(len(p[3]) for p in pages) / len(pages)
    scored = []
    for name, number, text, words in pages:
        score = 0.0
        for term in terms:
            count = words.count(term)
            if count:
                idf = math.log(1 + (len(pages) - doc_freq[term] + 0.5) / (doc_freq[term] + 0.5))
                # Pages shorter than average are scored as average: a stub that
                # mentions a word once must not outrank the chapter about it.
                length = max(1.0, len(words) / average)
                score += idf * count * 2.2 / (count + 1.2 * (0.25 + 0.75 * length))
        if score:
            scored.append((score, name, number, text))
    scored.sort(key=lambda item: -item[0])
    out, shown = [], set()
    for _, name, number, text in scored:
        snippet = re.sub(r"[ \t]+", " ", text).strip()[:1200]
        # The same passage can exist twice (a manual as one page and as many).
        if snippet[:300] in shown:
            continue
        shown.add(snippet[:300])
        out.append(f"### {name}, page {number}\n{snippet}")
        if len(out) >= max(1, min(int(limit), 8)):
            break
    return "\n\n".join(out) or f"nothing in the local documents matches {query!r}"


def read_doc_page(document, page):
    index = load_doc_index()
    document = str(document).strip()
    matches = [name for name in index if name == document]
    if not matches:
        matches = [name for name in index if name.endswith("/" + document) or Path(name).name == document]
    if not matches:
        return f"no such document: {document}. Find one with search_docs."
    if len(matches) > 1:
        return f"{document} is ambiguous; use the full name: " + ", ".join(sorted(matches)[:20])
    pages = index[matches[0]]
    page = int(page)
    if not 1 <= page <= len(pages):
        return f"{matches[0]} has pages 1-{len(pages)}"
    return f"{matches[0]}, page {page} of {len(pages)}\n{pages[page - 1].strip()}"


# ---------------------------------------------------------------- library


def xml_field(block, tag):
    found = re.search(rf"<{tag}>(.*?)</{tag}>", block, re.DOTALL)
    return html.unescape(found[1]) if found else ""


def library_get(path, timeout=20):
    with urllib.request.urlopen(LIBRARY_URL + path, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


def library_books():
    """(name, title, articles) of every book the library server offers; [] when it is not running."""
    try:
        feed = library_get("/catalog/v2/entries?count=-1", timeout=5)
    except (urllib.error.URLError, OSError, ValueError):
        return []
    books = []
    for entry in re.findall(r"<entry>(.*?)</entry>", feed, re.DOTALL):
        books.append((xml_field(entry, "name"), xml_field(entry, "title"), xml_field(entry, "articleCount")))
    return books


LIBRARY_DOWN = ("the reference library is not running or has no books; "
                "the operator starts it with `offline-ai library`")


def search_library(query, book="", limit=6):
    books = library_books()
    if not books:
        return LIBRARY_DOWN
    names = [name for name, _, _ in books]
    book = str(book or "").strip()
    if book and book not in names:
        return f"no book {book!r}; available: {', '.join(names)}"
    count = max(1, min(int(limit), 10))
    results, failed = [], []
    # One query per book: the server refuses a combined search across books in different languages.
    for name in [book] if book else names:
        params = urllib.parse.urlencode({"pattern": query, "books.filter.name": name, "format": "xml",
                                         "pageLength": count})
        try:
            feed = library_get("/search?" + params)
        except (urllib.error.URLError, OSError) as exc:
            failed.append(f"{name} ({exc})")
            continue
        for rank, item in enumerate(re.findall(r"<item>(.*?)</item>", feed, re.DOTALL)):
            snippet = re.sub(r"<[^>]+>", "", xml_field(item, "description")).strip()
            link = xml_field(item, "link").removeprefix("/content/")
            results.append((rank, f"### {xml_field(item, 'title')}\narticle: {link}\n{snippet[:500]}"))
    # Interleave by rank so every book's best hit comes before any book's second hit.
    results.sort(key=lambda item: item[0])
    text = "\n\n".join(text for _, text in results[: count * 2]) or f"nothing in the library matches {query!r}"
    if failed:
        text += "\n\n(search failed in: " + "; ".join(failed) + ")"
    return text


def read_article(article, page=1):
    article = str(article).strip().removeprefix("/content/").lstrip("/")
    if not article or ".." in article.split("/"):
        raise ValueError(f"not an article path: {article!r}")
    try:
        body = library_get("/content/" + urllib.parse.quote(article))
    except urllib.error.HTTPError as exc:
        return f"no such article: {article} (HTTP {exc.code}). Find one with search_library."
    except (urllib.error.URLError, OSError):
        return LIBRARY_DOWN
    pages = chunked(html_sections(body), size=5000)
    page = int(page)
    if not pages:
        return f"{article} has no readable text"
    if not 1 <= page <= len(pages):
        return f"{article} has pages 1-{len(pages)}"
    return f"{article}, page {page} of {len(pages)}\n{pages[page - 1]}"


def search_notes(query):
    # stdout only: offline, the embedding step prints a long traceback before
    # falling back to keyword search, and that would bury the results.
    argv = ["aggregator", "query", "--fields", "full", "--page-size", "5", "--", query]
    try:
        done = subprocess.run(argv, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        return "the notes search is not available on this machine"
    except subprocess.TimeoutExpired:
        return "the notes search timed out"
    return done.stdout.strip() or f"no notes found (exit {done.returncode}): {done.stderr.strip()[-300:]}"


# ------------------------------------------------------------------ tools


def tool(name, description, properties, required):
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {"type": "object", "properties": properties, "required": required},
        },
    }


def collection_summary():
    return ", ".join(COLLECTIONS) or "none"


SOURCE = {"type": "string", "enum": ["nixos", "home-manager"], "description": "which option reference"}
USER = {"type": "boolean", "description": "true for the user's own units (systemctl --user)"}

TOOLS = [
    tool("search_options", "Find NixOS or home-manager options by keyword. Use before writing any Nix code.",
         {"query": {"type": "string"}, "source": SOURCE, "limit": {"type": "integer"}}, ["query"]),
    tool("show_option", "Full reference for one option: type, default, example, description. "
         "Also lists the options under a prefix.",
         {"name": {"type": "string"}, "source": SOURCE}, ["name"]),
    tool("search_config", "Regex search over this machine's own NixOS flake (*.nix files).",
         {"pattern": {"type": "string"}}, ["pattern"]),
    tool("read_file", "Read part of a file from the NixOS flake or a document folder.",
         {"path": {"type": "string"}, "start": {"type": "integer"}, "lines": {"type": "integer"}}, ["path"]),
    tool("list_units", "List systemd units whose name contains the text, with their current state. "
         "Searches system and user units unless `user` is given.",
         {"match": {"type": "string"}, "user": USER}, ["match"]),
    tool("unit_status", "systemctl status for one unit.",
         {"unit": {"type": "string"}, "user": USER}, ["unit"]),
    tool("unit_logs", "Journal lines for one unit from the current boot.",
         {"unit": {"type": "string"}, "user": USER, "lines": {"type": "integer"}}, ["unit"]),
    tool("disk_usage", "Free space on the filesystem holding a path, and the largest entries directly under it. "
         "Call again on a large entry to go deeper.",
         {"path": {"type": "string", "description": "directory; default /"}}, []),
    tool("big_files", "The largest single files under a directory.",
         {"path": {"type": "string", "description": "directory; default the home directory"},
          "min_mb": {"type": "integer", "description": "smallest size to report, default 200"}}, []),
    tool("processes", "Running processes ranked by memory or CPU, plus free memory and load.",
         {"sort": {"type": "string", "enum": ["memory", "cpu"]}}, []),
    tool("network_status", "Network devices, addresses, routes, radio switches, wifi networks in range and DNS.",
         {}, []),
    tool("search_man", "Find installed manual pages by keyword (commands, config file formats, systemd).",
         {"query": {"type": "string"}, "limit": {"type": "integer"}}, ["query"]),
    tool("read_man", "Read an installed manual page, e.g. name `journalctl` or `systemd.timer`. "
         "Pass `search` to get just the passages that mention an option or word.",
         {"name": {"type": "string"}, "section": {"type": "string"},
          "search": {"type": "string", "description": "text to find in the page, e.g. `--since`; "
                     "separate alternatives with |"},
          "start": {"type": "integer"}, "lines": {"type": "integer"}}, ["name"]),
    tool("search_docs", "Search the documents stored on this machine. Collections: " + collection_summary()
         + ". Returns the best matching pages.",
         {"query": {"type": "string"}, "collection": {"type": "string", "description": "limit to one collection"},
          "limit": {"type": "integer"}}, ["query"]),
    tool("read_doc_page", "Read one full page of a document found with search_docs.",
         {"document": {"type": "string"}, "page": {"type": "integer"}}, ["document", "page"]),
    tool("search_library", "Full-text search in the offline reference library (wikis and Q&A archives on Linux, "
         "networking, radio, electronics and repair). Returns article paths.",
         {"query": {"type": "string"}, "book": {"type": "string", "description": "limit to one book"},
          "limit": {"type": "integer"}}, ["query"]),
    tool("read_article", "Read a library article found with search_library.",
         {"article": {"type": "string"}, "page": {"type": "integer"}}, ["article"]),
    tool("search_notes", "Keyword search over the operator's own past notes and sessions.",
         {"query": {"type": "string"}}, ["query"]),
]

FUNCTIONS = {
    "search_options": search_options,
    "show_option": show_option,
    "search_config": search_config,
    "read_file": read_file,
    "list_units": list_units,
    "unit_status": unit_status,
    "unit_logs": unit_logs,
    "disk_usage": disk_usage,
    "big_files": big_files,
    "processes": processes,
    "network_status": network_status,
    "search_man": search_man,
    "read_man": read_man,
    "search_docs": search_docs,
    "read_doc_page": read_doc_page,
    "search_library": search_library,
    "read_article": read_article,
    "search_notes": search_notes,
}


def call_tool(name, raw_arguments):
    function = FUNCTIONS.get(name)
    if function is None:
        return f"unknown tool {name!r}; available: {', '.join(FUNCTIONS)}"
    try:
        arguments = json.loads(raw_arguments or "{}")
        return clip(str(function(**arguments)))
    except Exception as exc:  # the model must see its own mistakes to correct them
        return f"tool error: {type(exc).__name__}: {exc}"


# ------------------------------------------------------------------- chat


def system_prompt():
    version_file = Path("/run/current-system/nixos-version")
    version = version_file.read_text().strip() if version_file.is_file() else "unknown"
    host = FLAKE_HOST or os.uname().nodename
    loader = "unknown"
    if Path("/boot/loader/loader.conf").exists():
        loader = "systemd-boot (older generations are in its boot menu; press Space during boot if it is hidden)"
    elif Path("/boot/grub").exists():
        loader = "GRUB"
    return f"""You are an offline assistant on a NixOS laptop. There is no internet.

Machine facts:
- hostname {os.uname().nodename}, NixOS {version}, configured by a flake at {CONFIG_ROOT} (host attribute `{host}`).
- User-level services and apps are declared with home-manager inside that flake. home-manager runs as a NixOS module here: every change, system or user, is applied with the nixos-rebuild command below; there is no separate `home-manager switch`.
- Boot loader: {loader}.
- Rebuild without network: `sudo nixos-rebuild switch --flake {CONFIG_ROOT}#{host} --offline`. It only succeeds if every needed package is already in the local store.
- A unit can be started or stopped immediately with systemctl; NixOS unit files are read-only, so `systemctl enable/disable` does not work and permanent changes go in the flake.
- NixOS and home-manager spell systemd units differently. NixOS: `systemd.services.NAME = {{ serviceConfig.ExecStart = ...; wantedBy = [ ... ]; }}` and `systemd.timers.NAME.timerConfig.OnCalendar`. home-manager uses the unit file's own section names: `systemd.user.services.NAME = {{ Unit = {{ ... }}; Service = {{ ExecStart = ...; }}; Install = {{ WantedBy = [ ... ]; }}; }}` and `systemd.user.timers.NAME = {{ Timer = {{ OnCalendar = ...; }}; Install = {{ WantedBy = [ "timers.target" ]; }}; }}`.
- To change a value another module already sets, override it with `lib.mkForce`.

Rules:
- You cannot change anything and you cannot run commands. When the operator asks for something to be done (start, stop, pause, delete, fix), never say it is done: look up how it is done on this machine, then give the exact commands or Nix code for them to run themselves.
- Never call something safe to delete because of its name. Say what it is if the tools showed you; otherwise say it needs checking. Databases, caches that hold history, models and backups are the operator's call.
- Before giving a systemctl or journalctl command for a named service, get the exact unit name from list_units; it often differs from the package name. Try user units too if no system unit matches.
- Before writing Nix code, look at how this flake already does the same kind of thing (search_config, then read_file) and follow that pattern.
- Before you write a NixOS or home-manager option name, confirm it with search_options or show_option. Never give an option name you have not seen in a tool result. home-manager and NixOS use different option sets; check the right one.
- search_options matches words in option names. Search with one to three words that would appear in the name (`pam limits`, `firewall port`, `kernel params`), not a sentence. If the first search misses, try other words, or browse with show_option on a prefix such as `security.pam`. Then call show_option on the option you intend to use and copy its attribute names from the example.
- For questions about this machine's services or configuration, look first (list_units, unit_status, search_config).
- For disk space, memory, slowness or connectivity, measure first (disk_usage, big_files, processes, network_status) and base the advice on what they show.
- Before giving a command with flags you are not sure of, check its manual page (search_man, read_man).
- For how-to knowledge beyond this machine, use search_docs (handbooks and manuals stored here) and search_library (offline wikis), and name the document or article you relied on.
- The stored documents include first-aid, medical, water, food and shelter handbooks (collections survival and survival-more) and an emergency medicine wiki in the library. For injuries, illness or survival questions, search them before answering, give the steps they give, and say to get professional help when it can be reached.
- If the tools do not show it, say you could not verify it.
- Be brief: the answer, the commands, one line of why."""


REMINDER = "(You can only look things up. Check with your tools first, then answer with the commands for me to run.)"


def with_leads(question):
    """The question plus keyword-matched option names, so the first lookup starts somewhere real."""
    leads = []
    for source, count in (("nixos", 6), ("home-manager", 4)):
        try:
            names = rank_options(question, source, count)
        except ValueError:
            continue
        if names:
            leads.append(f"{source}: " + ", ".join(names))
    question = f"{question}\n\n{REMINDER}"
    if not leads:
        return question
    return (f"{question}\n\n(Option names that merely share words with the question. Not tool results "
            "and mostly irrelevant; look up any you intend to use.)\n" + "\n".join(leads))


def post(payload):
    request = urllib.request.Request(
        URL + "/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    return urllib.request.urlopen(request, timeout=3600)


def complete(messages, use_tools, out):
    """One streamed model turn. Returns the assistant message."""
    payload = {"messages": messages, "stream": True, "temperature": 0.2}
    if use_tools:
        payload["tools"] = TOOLS
    content, calls = [], {}
    with post(payload) as response:
        for raw in response:
            line = raw.decode("utf-8", errors="replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            choices = json.loads(data).get("choices") or []
            if not choices:
                continue
            delta = choices[0].get("delta") or {}
            if delta.get("content"):
                content.append(delta["content"])
                out.write(delta["content"])
                out.flush()
            for part in delta.get("tool_calls") or []:
                slot = calls.setdefault(part.get("index", 0), {"id": "", "name": "", "arguments": ""})
                slot["id"] = part.get("id") or slot["id"]
                function = part.get("function") or {}
                slot["name"] = function.get("name") or slot["name"]
                slot["arguments"] += function.get("arguments") or ""
    message = {"role": "assistant", "content": "".join(content)}
    if calls:
        message["tool_calls"] = [
            {"id": c["id"] or f"call_{i}", "type": "function",
             "function": {"name": c["name"], "arguments": c["arguments"]}}
            for i, c in sorted(calls.items())
        ]
    return message


CODE = re.compile(r"```[^\n]*\n(.*?)```|`([^`\n]+)`", re.DOTALL)


def tools_given_as_commands(text):
    """Tool names written as the command of a line of code in an answer.

    A code block line counts; an inline span counts only with arguments, so
    naming a tool in prose (`processes`) is not flagged."""
    found = set()
    for block, inline in CODE.findall(text or ""):
        for line in (block or inline).splitlines():
            if re.match(r"^\s*[\w.-]+\s*[=:{]", line):
                continue  # an assignment such as `processes = 4;`, not a command
            words = line.strip().removeprefix("$").split()
            while words and words[0] in ("sudo", "doas"):
                words = words[1:]
            if words and words[0] in FUNCTIONS and (block or len(words) > 1):
                found.add(words[0])
    return found


def answer(messages, out=sys.stdout, log=sys.stderr):
    """Run the tool loop for the question already appended to messages."""
    asked, nudged = set(), False
    for _ in range(MAX_STEPS):
        message = complete(messages, True, out)
        messages.append(message)
        calls = message.get("tool_calls")
        if not calls:
            out.write("\n")
            misused = tools_given_as_commands(message["content"])
            if misused and not nudged:
                # Told in prose, a small model still hands its own tools to the operator as
                # shell commands. Catch it once and send it back to use them itself.
                nudged = True
                names = ", ".join(sorted(misused))
                print(f"[check] answer gave tool(s) {names} as commands; asking again", file=log)
                out.write("\n[revising: the answer above told you to run the assistant's own tools]\n\n")
                messages.append({"role": "user", "content":
                                 f"You gave {names} as commands for me to run. Those are your tools; I cannot run "
                                 "them. Call them yourself now, then answer with real shell commands only."})
                continue
            return message["content"]
        for call in calls:
            name, arguments = call["function"]["name"], call["function"]["arguments"]
            print(f"[tool] {name} {arguments}", file=log)
            if (name, arguments) in asked:
                # A small model can loop on one lookup; the answer would be the same.
                result = ("You already made this exact call and its result is above; it has not changed. "
                          "Answer from what you have, or look somewhere else.")
            else:
                asked.add((name, arguments))
                result = call_tool(name, arguments)
            messages.append({"role": "tool", "tool_call_id": call["id"], "content": result})
    messages.append({"role": "user", "content": "Stop looking things up and give your best answer now, "
                     "saying plainly what you could not verify."})
    message = complete(messages, False, out)
    messages.append(message)
    out.write("\n")
    return message["content"]


# ---------------------------------------------------------------- service

USAGE = """offline-ai — a local assistant for when the internet is down.

Two modes. Default mode is the machine as usual. Offline-AI mode stops the
services listed as giving way (the microVMs, dictation, ingest jobs), loads the
big model and the library, and gives the memory back when it ends.

  offline-ai                 enter offline-AI mode, then a conversation; leaving it returns to default mode
  offline-ai "question"      the same for one question
  offline-ai up              enter offline-AI mode and stay in it (about half a minute)
  offline-ai down            leave it: stop the model and the library, restart what was stopped
  offline-ai status          what is loaded and which references are present
  offline-ai library         start the browsable reference library and print where to open it
  offline-ai library fetch   download the archives the corpus lists (--list to preview, --all for optional ones)
  offline-ai index           re-read the document folders and manual pages
  offline-ai help            this text

The assistant only looks things up (options, this machine's flake, units and logs, disk,
processes, network, manual pages, documents, the library, your notes). It never changes
anything: it gives commands and Nix code for you to run."""


MODEL_ERRORS = (urllib.error.URLError, OSError, ValueError, http.client.HTTPException)


def model_error(exc):
    if isinstance(exc, urllib.error.HTTPError) and exc.code == 400:
        return ("the model refused the request (HTTP 400), most likely because the conversation "
                "outgrew its context window")
    return f"lost contact with the model server ({exc}); check it with: offline-ai status"


def healthy():
    try:
        with urllib.request.urlopen(URL + "/health", timeout=3) as response:
            return response.status == 200
    except (urllib.error.URLError, OSError):
        return False


def model_bytes():
    """Size of the model on disk; a model split into parts is the sum of its parts."""
    path = Path(MODEL)
    parts = re.match(r"^(.*)-\d{5}-of-\d{5}(\.gguf)$", path.name)
    files = sorted(path.parent.glob(f"{parts[1]}-*-of-*{parts[2]}")) if parts else [path]
    return sum(f.stat().st_size for f in files if f.is_file())


def meminfo(key):
    """A /proc/meminfo field in bytes, or None where it is not reported."""
    try:
        lines = MEMINFO.read_text().splitlines()
    except OSError:
        return None
    for line in lines:
        fields = line.split()
        if fields[:1] == [key + ":"] and len(fields) > 1 and fields[1].isdigit():
            return int(fields[1]) * 1024
    return None


def available_bytes():
    return meminfo("MemAvailable")


def swappable_bytes():
    """Anonymous memory the kernel can move to swap to make room: no more than
    there is of it, and no more than swap can take. Pinned GPU memory is not
    anonymous memory and never counts."""
    return min(meminfo("AnonPages") or 0, meminfo("SwapFree") or 0)


def systemctl_user(verb, unit):
    return subprocess.run(["systemctl", "--user", verb, "--", unit], capture_output=True, text=True)


def systemctl(user, verb, unit):
    return subprocess.run(["systemctl", *scope(user), verb, "--", unit], capture_output=True, text=True)


def read_evicted():
    """What gave way to the model, oldest first, as (user, unit, how, spec) entries.

    how is "stop" (start it again), "freeze" (thaw it) or "relaunch" (a
    transient unit, recreated from spec: argv, working directory, environment,
    slice). Records from older versions have only (user, unit) and were stops."""
    try:
        return [(bool(entry[0]), entry[1], entry[2] if len(entry) > 2 else "stop",
                 entry[3] if len(entry) > 3 else None)
                for entry in json.loads(EVICTED.read_text())]
    except (OSError, ValueError, TypeError, IndexError):
        return []


def write_evicted(entries):
    if not entries:
        EVICTED.unlink(missing_ok=True)
        return
    EVICTED.parent.mkdir(parents=True, exist_ok=True)
    tmp = EVICTED.with_suffix(".tmp")
    tmp.write_text(json.dumps([list(entry) for entry in entries]))
    tmp.replace(EVICTED)


def record(entry):
    """Append one entry at once, so an interrupted run can still restore it."""
    write_evicted(read_evicted() + [entry])


def unrecord(entry):
    entries = read_evicted()
    if entry in entries:
        entries.remove(entry)
    write_evicted(entries)


def evict():
    """Stop the running units that give way to the model; remember which, for restore()."""
    for user in (False, True):
        for unit in EVICT[user]:
            if any(entry[:2] == (user, unit) for entry in read_evicted()) or run(
                    ["systemctl", *scope(user), "is-active", "--", unit]) not in ("active", "activating", "reloading"):
                continue
            done = systemctl(user, "stop", unit)
            if done.returncode == 0:
                record((user, unit, "stop", None))
                print(f"stopped {unit} to make room", file=sys.stderr)
            else:
                print(f"could not stop {unit}: {done.stderr.strip()}", file=sys.stderr)


def own_cgroups():
    """The cgroups of this process and every process above it (terminal, shell, session)."""
    groups, pid = set(), os.getpid()
    while pid > 1:
        try:
            for line in Path(f"/proc/{pid}/cgroup").read_text().splitlines():
                if line.startswith("0::"):
                    groups.add(line[3:])
            stat = Path(f"/proc/{pid}/stat").read_text()
            pid = int(stat.rsplit(")", 1)[1].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return groups


def cgroup_bytes(group):
    """Memory the cgroup holds in RAM (anonymous and page cache)."""
    try:
        return int((group / "memory.current").read_text())
    except (OSError, ValueError):
        return 0


def gpu_bytes():
    """GPU memory per cgroup, from the DRM fdinfo of this user's processes.

    On an APU the GPU's buffers are ordinary RAM, pinned: not charged to any
    cgroup, not swappable, not released by freezing. A model server with its
    layers on the iGPU can hold tens of GiB this way. Each client is counted
    once however many descriptors share it."""
    seen, held = set(), {}
    for proc in PROC.iterdir():
        if not proc.name.isdigit():
            continue
        try:
            group = next((line[3:] for line in (proc / "cgroup").read_text().splitlines()
                          if line.startswith("0::")), None)
            fdinfos = list((proc / "fdinfo").iterdir())
        except OSError:
            continue
        for fdinfo in fdinfos:
            try:
                text = fdinfo.read_text()
            except OSError:
                continue
            if "drm-client-id" not in text:
                continue
            fields = dict(line.split(":", 1) for line in text.splitlines() if ":" in line)
            client = (fields.get("drm-pdev", "").strip(), fields.get("drm-client-id", "").strip())
            if client in seen or group is None:
                continue
            seen.add(client)
            # What is resident, wherever it sits: on an APU a buffer allotted as
            # VRAM can live in GTT, so drm-total-gtt alone undercounts. Older
            # amdgpu kernels report only drm-memory-<region>.
            kind = "drm-resident-" if any(key.startswith("drm-resident-") for key in fields) else "drm-memory-"
            for key, value in fields.items():
                parts = value.split()
                if key.startswith(kind) and parts and parts[0].isdigit():
                    scale = {"KiB": 2**10, "MiB": 2**20, "GiB": 2**30}.get(parts[1] if len(parts) > 1 else "", 1)
                    held[group] = held.get(group, 0) + int(parts[0]) * scale
    return held


def user_manager():
    """The cgroup directory of this user's systemd manager, or None outside one."""
    manager = Path(USER_CGROUP) if USER_CGROUP else None
    marker = f"user@{os.getuid()}.service"
    for group in own_cgroups() if manager is None else ():
        if marker in group:
            manager = CGROUP_ROOT / (group.lstrip("/").split(marker)[0] + marker)
            break
    if manager is None:  # run from an SSH login or cron: not below the manager, which is still there
        manager = CGROUP_ROOT / "user.slice" / f"user-{os.getuid()}.slice" / marker
    return manager if manager is not None and manager.is_dir() else None


def user_units():
    """This user's units that may give way, as (unit, cgroup dir). Desktop
    applications, terminals, the session bus, offline-ai's own units and
    whatever this CLI runs inside are left alone."""
    manager = user_manager()
    if manager is None:
        return []
    protected = [CGROUP_ROOT / group.lstrip("/") for group in own_cgroups()]
    found = []
    for group in manager.rglob("*"):
        name = group.name
        if not group.is_dir() or not name.endswith((".service", ".scope")) or NEVER_FREEZE.match(name):
            continue
        if group.parent.name.endswith((".service", ".scope")):
            continue  # a unit's own sub-cgroup, not a unit
        if "session.slice" in group.relative_to(manager).parts:
            continue  # what the desktop session itself runs on (compositor, shell)
        if any(p == group or group in p.parents for p in protected):
            continue
        found.append((name, group))
    return found


def bus_path(unit):
    """The D-Bus object path of a unit: every byte outside [A-Za-z0-9] as _xx."""
    return "/org/freedesktop/systemd1/unit/" + "".join(
        c if c.isascii() and c.isalnum() else "".join(f"_{b:02x}" for b in c.encode()) for c in unit)


def relaunch_spec(unit):
    """How to start a transient unit again once it is gone: its exact argv,
    working directory, environment and slice, read from the manager."""
    done = subprocess.run(["busctl", "--user", "--json=short", "get-property", "org.freedesktop.systemd1",
                           bus_path(unit), "org.freedesktop.systemd1.Service",
                           "ExecStart", "Environment", "WorkingDirectory", "Slice"],
                          capture_output=True, text=True)
    if done.returncode != 0:
        return None
    try:
        execs, env, workdir, slice_ = (json.loads(line)["data"] for line in done.stdout.splitlines() if line.strip())
        # WorkingDirectory reads "!/path" when a missing directory is allowed.
        return {"argv": execs[0][1], "env": env, "workdir": workdir.lstrip("!"), "slice": slice_}
    except (ValueError, KeyError, IndexError, TypeError):
        return None


def give_way(unit, group, gpu):
    """Free what one unit holds. GPU memory goes only when the process does, so
    a unit holding it is stopped, to be started again later (recreated from
    its recorded command line if it was transient). Anything else is frozen
    and its memory pushed to swap; thawing it later brings it back as it was."""
    if gpu:
        if unit.endswith(".scope"):
            # A scope's processes were started outside systemd: nothing could start them again.
            print(f"left {unit} running ({gpu / 2**30:.1f} GiB of GPU memory): it could not be started again",
                  file=sys.stderr)
            return False
        transient = run(["systemctl", "--user", "show", "-p", "Transient", "--value", "--", unit]) == "yes"
        spec = relaunch_spec(unit) if transient else None
        if transient and spec is None:
            print(f"left {unit} running: could not record how to start it again", file=sys.stderr)
            return False
        # Recorded before acting, so a run killed in between still knows how to bring it back.
        entry = (True, unit, "relaunch" if transient else "stop", spec)
        record(entry)
        done = systemctl(True, "stop", unit)
        if done.returncode != 0:
            unrecord(entry)
            print(f"could not stop {unit}: {done.stderr.strip()}", file=sys.stderr)
            return False
        print(f"stopped {unit} ({gpu / 2**30:.1f} GiB of GPU memory) to make room", file=sys.stderr)
        return True
    size = cgroup_bytes(group)
    entry = (True, unit, "freeze", None)
    record(entry)
    done = systemctl(True, "freeze", unit)
    if done.returncode != 0:
        unrecord(entry)
        print(f"could not freeze {unit}: {done.stderr.strip()}", file=sys.stderr)
        return False
    try:
        (group / "memory.reclaim").write_text(str(size))
    except OSError:
        pass  # EAGAIN: less than asked could be reclaimed; what was is still freed
    print(f"froze {unit} ({size / 2**30:.1f} GiB moved to swap) to make room", file=sys.stderr)
    return True


def make_room(need):
    """Free memory until `need` bytes are available: this user's large units
    give way, largest first, and stop as soon as there is enough."""
    held = gpu_bytes()
    candidates = []
    for unit, group in user_units():
        try:
            if (group / "cgroup.freeze").read_text().strip() == "1":
                continue  # already frozen, by us or anyone
        except OSError:
            continue
        gpu = sum(size for path, size in held.items()
                  if CGROUP_ROOT / path.lstrip("/") == group or group in (CGROUP_ROOT / path.lstrip("/")).parents)
        size = gpu + cgroup_bytes(group)
        if size >= FREEZE_MIN:
            candidates.append((size, unit, group, gpu if gpu >= FREEZE_MIN else 0))
    for size, unit, group, gpu in sorted(candidates, key=lambda item: item[0], reverse=True):
        free = available_bytes()
        if free is None or free >= need:
            return
        give_way(unit, group, gpu)
    # What is still short is left to the kernel: as the model loads it moves
    # the coldest pages of everything else to swap, which up() allows for.


def bring_back(user, unit, how, spec):
    if how == "freeze":
        return systemctl(user, "thaw", unit)
    if how == "relaunch":
        argv = ["systemd-run", "--user", f"--unit={unit}", "--collect"]
        if spec.get("slice"):
            argv.append(f"--slice={spec['slice']}")
        if spec.get("workdir"):
            argv.append(f"--working-directory={spec['workdir']}")
        argv += [f"--setenv={pair}" for pair in spec.get("env") or []]
        return subprocess.run([*argv, "--", *spec["argv"]], capture_output=True, text=True)
    return systemctl(user, "start", unit)


def restore():
    """Bring back what gave way, latest first; keep anything that failed for next time."""
    failed = []
    for entry in reversed(read_evicted()):
        user, unit, how, spec = entry
        if how == "freeze" and run(["systemctl", *scope(user), "show", "-p", "LoadState", "--value", "--", unit]) != "loaded":
            print(f"{unit} is gone; nothing to thaw", file=sys.stderr)  # its processes ended while frozen
            continue
        done = bring_back(*entry)
        word = {"freeze": "thaw", "relaunch": "relaunch"}.get(how, "restart")
        if done.returncode == 0:
            print(f"{word.rstrip('e')}ed {unit}", file=sys.stderr)
        else:
            failed.insert(0, entry)
            print(f"could not {word} {unit}: {done.stderr.strip()}", file=sys.stderr)
    write_evicted(failed)
    return not failed




def enter_offline_mode(force=False):
    evict()
    try:
        if MODEL and os.path.exists(MODEL) and not healthy():
            make_room(model_bytes() + HEADROOM)
        up(force=force)
    except SystemExit:
        restore()  # the model did not load: give back what was stopped for it
        raise
    start_library()


def leave_offline_mode():
    systemctl_user("stop", LIBRARY_UNIT)
    stopped = systemctl_user("stop", UNIT)
    restored = restore()
    return stopped.returncode == 0 and restored


def up(force=False):
    if healthy():
        return
    if MODEL and not os.path.exists(MODEL):
        sys.exit(f"the model is not on this machine: {MODEL}\n"
                 "Fetch it while online (46 GB):\n"
                 "  nix shell nixpkgs#python3Packages.huggingface-hub -c hf download "
                 "Qwen/Qwen3-Coder-Next-GGUF --include 'Qwen3-Coder-Next-Q4_K_M/*' "
                 "--local-dir ~/.local/share/llm-models/qwen3-coder-next")
    loading = run(["systemctl", "--user", "is-active", "--", UNIT]) in ("active", "activating")
    if MODEL and not force and not loading:
        need, free, swappable = model_bytes(), available_bytes(), swappable_bytes()
        if free is not None and need > free + swappable:
            sys.exit(f"not enough memory: the model needs about {need / 2**30:.0f} GiB; "
                     f"{free / 2**30:.0f} GiB is available and {swappable / 2**30:.0f} GiB more could go to swap.\n"
                     "Close something large first (`ps -eo rss,comm --sort=-rss | head`), "
                     "or run `offline-ai up --force` to load anyway.")
        if free is not None and need > free:
            print(f"{(need - free) / 2**30:.0f} GiB of other programs' idle memory will move to swap "
                  "while the model loads", file=sys.stderr)
    print(f"loading the model ({UNIT})...", file=sys.stderr)
    started = systemctl_user("start", UNIT)
    if started.returncode != 0:
        sys.exit(f"could not start {UNIT}: {started.stderr.strip()}")
    began = time.time()
    while time.time() - began < 900:
        if healthy():
            print(f"model ready after {time.time() - began:.0f} s", file=sys.stderr)
            return
        state = run(["systemctl", "--user", "is-active", "--", UNIT])
        if state in ("failed", "inactive"):
            sys.exit(f"{UNIT} is {state}; see: journalctl --user -u {UNIT} -b -n 40")
        time.sleep(3)
    sys.exit(f"{UNIT} did not become ready within 15 minutes")


def start_library():
    """Start the library server if it is not answering. Returns the books it offers."""
    books = library_books()
    if books:
        return books
    if systemctl_user("start", LIBRARY_UNIT).returncode != 0:
        return []
    for _ in range(20):
        books = library_books()
        if books:
            return books
        if run(["systemctl", "--user", "is-active", "--", LIBRARY_UNIT]) in ("failed", "inactive"):
            return []  # nothing to serve: the unit has already exited
        time.sleep(0.5)
    return []


def status_lines():
    index = load_doc_index()
    lines = ["model server: " + ("ready" if healthy() else run(["systemctl", "--user", "is-active", "--", UNIT]))]
    evicted = read_evicted()
    lines.append("mode: offline-AI, stopped for it: " + ", ".join(
        unit + (" (frozen)" if how == "freeze" else "") for _, unit, how, _spec in evicted) if evicted
                 else "mode: " + ("offline-AI" if healthy() else "default"))
    for source, path in OPTION_FILES.items():
        lines.append(f"{source} options: " + ("present" if path and os.path.exists(path) else "MISSING"))
    for label in COLLECTIONS:
        names = [name for name in index if name.startswith(label + "/")]
        lines.append(f"documents, {label}: {len(names)} files, {sum(len(index[n]) for n in names)} pages")
    if not COLLECTIONS:
        lines.append("documents: none configured")
    lines.append(f"manual pages: {len(man_index())}")
    profile = run(["powerprofilesctl", "get"], timeout=5)
    if profile in ("balanced", "power-saver"):
        lines.append(f"power profile: {profile} (answers are faster with `powerprofilesctl set performance`)")
    books = library_books()
    if books:
        lines.append(f"library ({LIBRARY_URL}): " + "; ".join(f"{title} [{count} articles]" for _, title, count in books))
    else:
        lines.append("library: not running (start it with `offline-ai library`)")
    return lines


def main():
    parser = argparse.ArgumentParser(usage=USAGE, add_help=False)
    parser.add_argument("question", nargs="*")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("-h", "--help", action="store_true")
    args, extra = parser.parse_known_args()
    if args.question[:2] == ["library", "fetch"]:
        rest = args.question[2:] + extra + (["--help"] if args.help else [])
        try:
            os.execvp("offline-ai-library-fetch", ["offline-ai-library-fetch", *rest])
        except FileNotFoundError:
            sys.exit("offline-ai-library-fetch is not installed")
    if extra:
        parser.error("unrecognized arguments: " + " ".join(extra))
    command = args.question[0] if len(args.question) == 1 else None

    if args.help or command == "help":
        print(USAGE)
        return
    if command == "down":
        sys.exit(0 if leave_offline_mode() else 1)
    if command == "status":
        print("\n".join(status_lines()))
        return
    if command == "index":
        index = load_doc_index(rebuild=True)
        print(f"indexed {len(index)} documents, {sum(len(pages) for pages in index.values())} pages, "
              f"{len(man_index(rebuild=True))} manual pages")
        return
    if command == "library":
        books = start_library()
        if not books:
            sys.exit("the library has no archives to serve. Fetch some while online:\n"
                     "  offline-ai library fetch --list\n  offline-ai library fetch\n"
                     f"(details: journalctl --user -u {LIBRARY_UNIT} -b -n 20)")
        print(f"library: {LIBRARY_URL}")
        for name, title, count in books:
            print(f"  {title} ({name}, {count} articles)")
        for label, root in COLLECTIONS.items():
            if (root / "index.html").is_file():
                print(f"{label} index: file://{root / 'index.html'}")
        return

    if command == "up":
        enter_offline_mode(force=args.force)
        print("\n".join(status_lines()))
        return

    # A conversation started from default mode enters offline-AI mode and leaves it
    # again when it ends, however it ends; one started after `up` leaves the mode alone.
    owns_mode = not healthy()
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda signum, frame: sys.exit(128 + signum))
    try:
        if owns_mode:
            enter_offline_mode(force=args.force)
        converse(args.question)
    finally:
        if owns_mode:
            print("leaving offline-AI mode...", file=sys.stderr)
            leave_offline_mode()


def converse(question):
    messages = [{"role": "system", "content": system_prompt()}]
    if question:
        messages.append({"role": "user", "content": with_leads(" ".join(question))})
        try:
            answer(messages)
        except MODEL_ERRORS as exc:
            sys.exit(model_error(exc))
        return
    print("\n".join(status_lines()), file=sys.stderr)
    print("\noffline-ai. Ask a question; empty line or Ctrl-D to quit.", file=sys.stderr)
    while True:
        try:
            line = input("\n> ").strip()
        except (EOFError, KeyboardInterrupt):
            break
        if not line:
            break
        messages.append({"role": "user", "content": with_leads(line)})
        try:
            answer(messages)
        except MODEL_ERRORS as exc:
            print(model_error(exc) + "\nStarting a fresh conversation.", file=sys.stderr)
            del messages[1:]


if __name__ == "__main__":
    main()
