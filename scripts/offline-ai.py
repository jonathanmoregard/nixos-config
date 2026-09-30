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
import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.error
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
DOC_DIRS = [Path(p) for p in os.environ.get("OFFLINE_AI_DOC_DIRS", "").split(":") if p]
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
    """Option names ranked by rare-term matches; a name hit outweighs a description hit."""
    entries = option_index(source)
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


def scope(user):
    return ["--user"] if user else []


def check_unit(unit):
    if not UNIT_NAME.match(unit):
        raise ValueError(f"not a valid unit name: {unit!r}")
    return unit


def unit_status(unit, user=False):
    return run(["systemctl", *scope(user), "status", "--no-pager", "-n", "15", "--", check_unit(unit)])


def unit_logs(unit, user=False, lines=40):
    count = str(max(1, min(int(lines), 120)))
    return run(["journalctl", *scope(user), "-u", check_unit(unit), "-b", "-n", count, "--no-pager"])


def list_units(match, user=False):
    needle = match.lower()
    out = run(["systemctl", *scope(user), "list-units", "--all", "--plain", "--no-legend", "--no-pager"])
    files = run(["systemctl", *scope(user), "list-unit-files", "--plain", "--no-legend", "--no-pager"])
    hits = [line for line in out.splitlines() if needle in line.lower()]
    known = {line.split()[0] for line in hits if line.split()}
    for line in files.splitlines():
        fields = line.split()
        if fields and needle in fields[0].lower() and fields[0] not in known:
            hits.append(f"{fields[0]} (not loaded; unit file state: {fields[1] if len(fields) > 1 else '?'})")
    return "\n".join(hits[:40]) or f"no {'user' if user else 'system'} unit matches {match!r}"


# -------------------------------------------------------------- documents


def extract_pages(path):
    if path.suffix.lower() == ".pdf":
        try:
            done = subprocess.run(
                ["pdftotext", "-layout", str(path), "-"], capture_output=True, text=True, timeout=300
            )
        except (FileNotFoundError, subprocess.TimeoutExpired):
            return []
        return done.stdout.split("\f")
    text = path.read_text(encoding="utf-8", errors="replace")
    return [text[i : i + 3000] for i in range(0, len(text), 3000)]


def doc_files():
    for root in DOC_DIRS:
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if path.is_file() and path.suffix.lower() in (".pdf", ".txt", ".md"):
                yield path


def load_doc_index(rebuild=False):
    """Pages of every document, extracted once and cached by path, size and mtime."""
    index_path = CACHE_DIR / "docs.json"
    cached = {}
    if index_path.exists() and not rebuild:
        try:
            cached = json.loads(index_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            cached = {}
    fresh, changed = {}, False
    for path in doc_files():
        stat = path.stat()
        stamp = f"{stat.st_size}:{int(stat.st_mtime)}"
        entry = cached.get(str(path))
        if entry is None or entry["stamp"] != stamp:
            print(f"[index] reading {path.name}", file=sys.stderr)
            entry = {"stamp": stamp, "pages": extract_pages(path)}
            changed = True
        fresh[str(path)] = entry
    if changed or set(fresh) != set(cached):
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        tmp = index_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(fresh), encoding="utf-8")
        tmp.replace(index_path)
    return fresh


def search_docs(query, limit=4):
    index = load_doc_index()
    # Stemmed on both sides, so "burn" finds the page headed "BURNS".
    terms = set(keywords(query))
    if not terms:
        return "empty query"
    pages = []
    for path, entry in index.items():
        for number, text in enumerate(entry["pages"], 1):
            words = [stem(w) for w in WORD.findall(text.lower())]
            if words:
                pages.append((path, number, text, words))
    if not pages:
        return "no local documents are indexed"
    doc_freq = {t: sum(1 for p in pages if t in set(p[3])) for t in terms}
    average = sum(len(p[3]) for p in pages) / len(pages)
    scored = []
    for path, number, text, words in pages:
        score = 0.0
        for term in terms:
            count = words.count(term)
            if count:
                idf = math.log(1 + (len(pages) - doc_freq[term] + 0.5) / (doc_freq[term] + 0.5))
                score += idf * count * 2.2 / (count + 1.2 * (0.25 + 0.75 * len(words) / average))
        if score:
            scored.append((score, path, number, text))
    scored.sort(key=lambda item: -item[0])
    out = []
    for _, path, number, text in scored[: max(1, min(int(limit), 8))]:
        snippet = re.sub(r"[ \t]+", " ", text).strip()[:1200]
        out.append(f"### {Path(path).name}, page {number}\n{snippet}")
    return "\n\n".join(out) or f"nothing in the local documents matches {query!r}"


def read_doc_page(document, page):
    index = load_doc_index()
    matches = [p for p in index if Path(p).name == document or p == document]
    if not matches:
        names = ", ".join(sorted(Path(p).name for p in index))
        return f"no such document: {document}. Available: {names}"
    pages = index[matches[0]]["pages"]
    page = int(page)
    if not 1 <= page <= len(pages):
        return f"{document} has pages 1-{len(pages)}"
    return f"{Path(matches[0]).name}, page {page} of {len(pages)}\n{pages[page - 1].strip()}"


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
    tool("list_units", "List systemd units whose name contains the text, with their current state.",
         {"match": {"type": "string"}, "user": USER}, ["match"]),
    tool("unit_status", "systemctl status for one unit.",
         {"unit": {"type": "string"}, "user": USER}, ["unit"]),
    tool("unit_logs", "Journal lines for one unit from the current boot.",
         {"unit": {"type": "string"}, "user": USER, "lines": {"type": "integer"}}, ["unit"]),
    tool("search_docs", "Search the local reference library (medical, water, food, shelter and similar "
         "practical handbooks). Returns the best matching pages.",
         {"query": {"type": "string"}, "limit": {"type": "integer"}}, ["query"]),
    tool("read_doc_page", "Read one full page of a local document found with search_docs.",
         {"document": {"type": "string"}, "page": {"type": "integer"}}, ["document", "page"]),
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
    "search_docs": search_docs,
    "read_doc_page": read_doc_page,
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
    version = "unknown"
    try:
        version = Path("/run/current-system/nixos-version").read_text().strip()
    except OSError:
        pass
    host = FLAKE_HOST or os.uname().nodename
    return f"""You are an offline assistant on a NixOS laptop. There is no internet.

Machine facts:
- hostname {os.uname().nodename}, NixOS {version}, configured by a flake at {CONFIG_ROOT} (host attribute `{host}`).
- User-level services are declared with home-manager inside that flake.
- Rebuild without network: `sudo nixos-rebuild switch --flake {CONFIG_ROOT}#{host} --offline`. It only succeeds if every needed package is already in the local store.
- A unit can be started or stopped immediately with systemctl; NixOS unit files are read-only, so `systemctl enable/disable` does not work and permanent changes go in the flake.
- NixOS and home-manager spell systemd units differently. NixOS: `systemd.services.NAME = {{ serviceConfig.ExecStart = ...; wantedBy = [ ... ]; }}` and `systemd.timers.NAME.timerConfig.OnCalendar`. home-manager uses the unit file's own section names: `systemd.user.services.NAME = {{ Unit = {{ ... }}; Service = {{ ExecStart = ...; }}; Install = {{ WantedBy = [ ... ]; }}; }}` and `systemd.user.timers.NAME = {{ Timer = {{ OnCalendar = ...; }}; Install = {{ WantedBy = [ "timers.target" ]; }}; }}`.
- To change a value another module already sets, override it with `lib.mkForce`.

Rules:
- You cannot change anything. Give the operator exact commands or Nix code to apply themselves.- Before giving a systemctl or journalctl command for a named service, get the exact unit name from list_units; it often differs from the package name. Try user units too if no system unit matches.
- Before writing Nix code, look at how this flake already does the same kind of thing (search_config, then read_file) and follow that pattern.
- Before you write a NixOS or home-manager option name, confirm it with search_options or show_option. Never give an option name you have not seen in a tool result. home-manager and NixOS use different option sets; check the right one.
- search_options matches words in option names. Search with one to three words that would appear in the name (`pam limits`, `firewall port`, `kernel params`), not a sentence. If the first search misses, try other words, or browse with show_option on a prefix such as `security.pam`. Then call show_option on the option you intend to use and copy its attribute names from the example.
- For questions about this machine's services or configuration, look first (list_units, unit_status, search_config).
- For practical non-computer questions, use search_docs and name the document and page you relied on.
- If the tools do not show it, say you could not verify it.
- Be brief: the answer, the commands, one line of why."""


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


def answer(messages, out=sys.stdout, log=sys.stderr):
    """Run the tool loop for the question already appended to messages."""
    for _ in range(MAX_STEPS):
        message = complete(messages, True, out)
        messages.append(message)
        calls = message.get("tool_calls")
        if not calls:
            out.write("\n")
            return message["content"]
        for call in calls:
            name, arguments = call["function"]["name"], call["function"]["arguments"]
            print(f"[tool] {name} {arguments}", file=log)
            messages.append({"role": "tool", "tool_call_id": call["id"], "content": call_tool(name, arguments)})
    messages.append({"role": "user", "content": "Stop looking things up and give your best answer now, "
                     "saying plainly what you could not verify."})
    message = complete(messages, False, out)
    messages.append(message)
    out.write("\n")
    return message["content"]


# ---------------------------------------------------------------- service


def healthy():
    try:
        with urllib.request.urlopen(URL + "/health", timeout=3) as response:
            return response.status == 200
    except (urllib.error.URLError, OSError):
        return False


def up():
    if healthy():
        return
    if MODEL and not os.path.exists(MODEL):
        sys.exit(f"the model is not on this machine: {MODEL}\n"
                 "Fetch it while online (46 GB):\n"
                 "  nix shell nixpkgs#python3Packages.huggingface-hub -c hf download "
                 "Qwen/Qwen3-Coder-Next-GGUF --include 'Qwen3-Coder-Next-Q4_K_M/*' "
                 "--local-dir ~/.local/share/llm-models/qwen3-coder-next")
    print(f"starting {UNIT} (loading the model can take a few minutes)...", file=sys.stderr)
    started = subprocess.run(["systemctl", "--user", "start", "--", UNIT], capture_output=True, text=True)
    if started.returncode != 0:
        sys.exit(f"could not start {UNIT}: {started.stderr.strip()}")
    deadline = time.time() + 900
    while time.time() < deadline:
        if healthy():
            return
        state = run(["systemctl", "--user", "is-active", "--", UNIT])
        if state in ("failed", "inactive"):
            sys.exit(f"{UNIT} is {state}; see: journalctl --user -u {UNIT} -b -n 40")
        time.sleep(3)
    sys.exit(f"{UNIT} did not become ready within 15 minutes")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("question", nargs="*", help="ask once; leave empty for a conversation; "
                        "or one of the commands: up, down, status, index")
    args = parser.parse_args()
    command = args.question[0] if len(args.question) == 1 else None

    if command == "down":
        sys.exit(subprocess.run(["systemctl", "--user", "stop", "--", UNIT]).returncode)
    if command == "status":
        print("model server:", "ready" if healthy() else run(["systemctl", "--user", "is-active", "--", UNIT]))
        for source, path in OPTION_FILES.items():
            print(f"{source} options:", "present" if path and os.path.exists(path) else "MISSING")
        print("document folders:", ", ".join(map(str, DOC_DIRS)) or "none")
        return
    if command == "index":
        index = load_doc_index(rebuild=True)
        print(f"indexed {len(index)} documents, {sum(len(e['pages']) for e in index.values())} pages")
        return

    up()
    if command == "up":
        print("ready")
        return
    messages = [{"role": "system", "content": system_prompt()}]
    if args.question:
        messages.append({"role": "user", "content": with_leads(" ".join(args.question))})
        answer(messages)
        return
    print("offline-ai. Empty line or Ctrl-D to quit.", file=sys.stderr)
    while True:
        try:
            question = input("\n> ").strip()
        except EOFError:
            break
        if not question:
            break
        messages.append({"role": "user", "content": with_leads(question)})
        answer(messages)


if __name__ == "__main__":
    main()
