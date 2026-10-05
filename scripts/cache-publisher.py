#!/usr/bin/env python3
"""Push locally built Nix outputs of PUBLIC GitHub repos to the public cache.

Leak-proof by construction: provenance is established forwards, from a
GitHub ref that anonymous HTTP proves public, never backwards from store
paths. Every gate defaults to SKIP; the only path to `cachix push` is an
entry that passed all of them. See modules/nixos/cache-publisher.nix.

Subcommands:
  run   process the spool (systemd service, user cache-publisher)
  scan  enqueue HEADs of local GitHub checkouts (systemd timer, user jonathan)

Spool entries are files holding one line `owner/repo <40-hex sha>`. They are
data only: the publisher re-derives everything from GitHub.
"""
import json
import os
import re
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse

ENTRY_RE = re.compile(r"^([A-Za-z0-9-]{1,39})/([A-Za-z0-9._-]{1,100}) ([0-9a-f]{40})$")
GITHUB_HOSTS = {"github.com", "codeload.github.com", "api.github.com", "raw.githubusercontent.com"}
GH_PATH_RE = re.compile(r"^/(?:repos/)?([A-Za-z0-9-]{1,39})/([A-Za-z0-9._-]{1,100}?)(?:\.git)?(?:/|$)")


class Retry(Exception):
    """Transient failure: keep the entry, try again later."""

    def __init__(self, reason, not_before=0):
        super().__init__(reason)
        self.not_before = not_before


class Skip(Exception):
    """Final decision for this entry: do not push."""


# No credential of any kind may reach nix: with one it could fetch private
# repos. The anonymous GitHub checks are the primary gate; this keeps the
# evaluator unable to see private content at all.
NIX_CONFIG = "access-tokens =\nnetrc-file = /dev/null\n"
# Fresh-store operations substitute from cache.nixos.org only: never from
# the target cache (it could hold what a bug pushed earlier) or a local one.
NIX_CONFIG_FRESH = NIX_CONFIG + (
    "substituters = https://cache.nixos.org\n"
    "extra-substituters =\n"
    "allow-import-from-derivation = false\n"
    "pure-eval = true\n"
    # Pinned, not inherited: untrusted builders run as cache-publisher.
    "sandbox = true\n"
    "sandbox-fallback = false\n"
    "extra-sandbox-paths =\n"
    "builders =\n"
    "accept-flake-config = false\n"
    "allow-unsafe-native-code-during-evaluation = false\n"
    "plugin-files =\n"
    # Restricted evaluation: only these URI prefixes may be fetched at eval
    # time. No file://, no path:, no arbitrary hosts.
    "restrict-eval = true\n"
    "allowed-uris = github: https://github.com/ https://api.github.com/ "
    "https://codeload.github.com/ https://channels.nixos.org/ https://releases.nixos.org/\n")

TRANSIENT = ("unable to download", "http error 404", "could not resolve host", "couldn't resolve host",
             "timeout", "timed out", "connection refused", "network is unreachable",
             "http error 5", "http error 429", "temporary failure")


def nix_error(args, stderr):
    """A failed nix call is a skip, unless it looks like the network: then retry."""
    msg = f"nix {args[0]} failed: {stderr.strip()[-300:]}"
    low = stderr.lower()
    return Retry(msg) if any(t in low for t in TRANSIENT) else Skip(msg)


# ── real side effects (tests replace these) ─────────────────────────────────

class World:
    def __init__(self, cfg):
        self.cfg = cfg

    def http_get(self, url):
        """Anonymous GET. Returns (status, headers, body). Never sends auth."""
        req = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": "cache-publisher",
        })
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.status, dict(r.headers), r.read()
        except urllib.error.HTTPError as e:
            return e.code, dict(e.headers or {}), b""

    def nix(self, args):
        env = dict(os.environ)
        # No credentials may reach the evaluator: a token would let it fetch
        # private repos. The anonymous GitHub checks are the primary gate;
        # this keeps the evaluator unable to see private content at all.
        env["NIX_CONFIG"] = NIX_CONFIG_FRESH
        p = subprocess.run(["nix", "--extra-experimental-features", "nix-command flakes", *args],
                           capture_output=True, text=True, env=env, timeout=1800)
        if p.returncode != 0:
            raise nix_error(args, p.stderr)
        return p.stdout

    def nix_store(self, args):
        env = dict(os.environ)
        env["NIX_CONFIG"] = NIX_CONFIG
        p = subprocess.run(["nix-store", *args], capture_output=True, text=True, env=env, timeout=600)
        if p.returncode != 0:
            raise nix_error(["nix-store", *args], p.stderr)
        return p.stdout

    def cachix_push(self, paths):
        with open(self.cfg["token_file"]) as f:
            token = f.read().strip()
        if not token:
            raise Retry("empty cachix token file")
        env = {"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", "/var/empty"),
               "NIX_REMOTE": self.cfg["local_store"], "CACHIX_AUTH_TOKEN": token}
        for k in ("NIX_SSL_CERT_FILE", "SSL_CERT_FILE"):
            if os.environ.get(k):
                env[k] = os.environ[k]
        p = subprocess.run(["cachix", "push", "--omit-deriver", self.cfg["cache"], *paths],
                           capture_output=True, text=True, env=env, timeout=3600)
        if p.returncode != 0:
            raise Retry(f"cachix push failed rc={p.returncode}: {p.stderr.strip()[-300:]}")

    def now(self):
        return time.time()


# ── gates ───────────────────────────────────────────────────────────────────

class Publisher:
    def __init__(self, cfg, world, log=print):
        self.cfg = cfg
        self.w = world
        self.log = log
        self.input_cache = {}  # "o/r" -> (time, True); lock inputs only

    def gh(self, path):
        st, hdrs, body = self.w.http_get(self.cfg["github_api"] + path)
        if st in (403, 429):
            reset = hdrs.get("x-ratelimit-reset") or hdrs.get("X-RateLimit-Reset")
            ra = hdrs.get("retry-after") or hdrs.get("Retry-After")
            nb = self.w.now() + int(ra) if ra and ra.isdigit() else int(reset) if reset and reset.isdigit() else self.w.now() + 3600
            raise RateLimited(f"github rate limited ({st})", nb)
        return st, body

    def repo_public(self, owner, repo):
        """True only for HTTP 200 + private false + visibility public."""
        try:
            st, body = self.gh(f"/repos/{owner}/{repo}")
        except Retry:
            raise
        except Exception as e:  # network down, DNS, timeout
            raise Retry(f"github unreachable: {e}")
        if st == 404:
            return False
        if st != 200:
            raise Retry(f"github /repos status {st}")
        try:
            d = json.loads(body)
        except ValueError:
            raise Retry("github /repos returned non-JSON")
        return d.get("private") is False and d.get("visibility") == "public"

    def input_public(self, owner, repo):
        key = f"{owner}/{repo}".lower()
        hit = self.input_cache.get(key)
        if hit and self.w.now() - hit < self.cfg["input_ttl"]:
            return True
        ok = self.repo_public(owner, repo)
        if ok:
            self.input_cache[key] = self.w.now()
        return ok

    def input_rev_public(self, owner, repo, rev):
        if not re.fullmatch(r"[0-9a-f]{40}", rev or ""):
            raise Skip(f"lock input {owner}/{repo} has no full rev")
        key = f"{owner}/{repo}@{rev}".lower()
        hit = self.input_cache.get(key)
        if hit and self.w.now() - hit < self.cfg["input_ttl"]:
            return
        st = self.commit_status(owner, repo, rev)
        if st != 200:
            raise Skip(f"lock input {owner}/{repo}@{rev[:12]} is not anonymously fetchable (status {st})")
        self.input_cache[key] = self.w.now()

    def commit_status(self, owner, repo, sha):
        try:
            st, _ = self.gh(f"/repos/{owner}/{repo}/commits/{sha}")
        except Retry:
            raise
        except Exception as e:
            raise Retry(f"github unreachable: {e}")
        if st >= 500:
            raise Retry(f"github commits status {st}")
        return st

    def commit_public(self, owner, repo, sha):
        st = self.commit_status(owner, repo, sha)
        if st != 200:
            # The push may not have reached GitHub yet: retry until expiry.
            raise Retry(f"commit {sha[:12]} not anonymously fetchable yet (status {st})")

    def github_repo_of(self, url):
        u = urlparse(url)
        if u.scheme not in ("https", "http") or u.hostname not in GITHUB_HOSTS:
            return None
        m = GH_PATH_RE.match(u.path)
        return (m.group(1), m.group(2)) if m else None

    def audit_lock(self, ref):
        meta = json.loads(self.w.nix(["flake", "metadata", *self.fresh(), "--json", "--no-update-lock-file", ref]))
        if meta.get("dirtyRevision") or not meta.get("revision"):
            raise Skip("flake ref is dirty or has no revision")
        nodes = (meta.get("locks") or {}).get("nodes") or {}
        root = (meta.get("locks") or {}).get("root", "root")
        inputs = []
        for name, node in nodes.items():
            if name == root:
                continue
            locked = node.get("locked")
            if not locked:
                raise Skip(f"lock node {name} is unlocked")
            t = locked.get("type")
            if t == "github":
                if locked.get("host") not in (None, "github.com"):
                    raise Skip(f"lock node {name}: github host {locked.get('host')} not allowed")
                if not self.input_public(locked["owner"], locked["repo"]):
                    raise Skip(f"lock node {name}: {locked['owner']}/{locked['repo']} is not public")
                # The narHash pins content, and Nix reuses a valid local store path
                # without downloading it. Proving the locked rev itself is public
                # keeps a lock entry from smuggling private content under a
                # public repo's name.
                self.input_rev_public(locked["owner"], locked["repo"], locked.get("rev", ""))
                inputs.append((locked["owner"], locked["repo"], locked["rev"]))
            elif t == "git":
                url = locked.get("url", "")
                gr = self.github_repo_of(url) if url.startswith("https://") else None
                if not gr:
                    raise Skip(f"lock node {name}: git input {url!r} is not an https GitHub URL")
                if not self.input_public(*gr):
                    raise Skip(f"lock node {name}: {gr[0]}/{gr[1]} is not public")
                self.input_rev_public(*gr, locked.get("rev", ""))
                inputs.append((*gr, locked["rev"]))
            elif t in ("tarball", "file"):
                url = locked.get("url", "")
                # GitHub content only as a typed github/git input: those carry
                # a rev that is re-checked right before upload; a tarball URL
                # would slip past that re-check.
                if self.github_repo_of(url):
                    raise Skip(f"lock node {name}: GitHub {t} input {url!r}; use a github: input")
                if not self.url_allowed(url):
                    raise Skip(f"lock node {name}: {t} url {url!r} not allowlisted")
            else:
                raise Skip(f"lock node {name}: input type {t!r} not allowed")
        return inputs

    def url_allowed(self, url):
        u = urlparse(url)
        if u.scheme != "https" or not u.hostname:
            return False
        gr = self.github_repo_of(url)
        if gr:
            return self.input_public(*gr)
        return any(u.hostname == h or u.hostname.endswith("." + h) for h in self.cfg["url_allow"])

    def local(self):
        """The host store, through the daemon: metadata only. The service's
        filesystem holds just its own closure, not the host /nix/store."""
        return ["--store", self.cfg["local_store"]]

    def path_info(self, paths):
        if not paths:
            return {}
        out = self.w.nix(["path-info", "--json", "--json-format", "1", *self.local(), *paths])
        return json.loads(out)

    def upstream_set(self, paths):
        """Subset of paths that the upstream cache (cache.nixos.org) serves."""
        paths = sorted(set(paths))
        found = set()
        for i in range(0, len(paths), 500):
            chunk = paths[i:i + 500]
            info = json.loads(self.w.nix(["path-info", "--json", "--json-format", "1",
                                          "--store", self.cfg["upstream"], *chunk]))
            found |= {p for p, v in info.items() if v is not None}
        return found

    def drv_show(self, drv):
        d = json.loads(self.w.nix(["derivation", "show", drv]))
        d = d.get("derivations", d)
        if len(d) != 1:
            raise Skip(f"cannot read derivation {drv}")
        return next(iter(d.values()))

    @staticmethod
    def is_fod(drv):
        if (drv.get("env") or {}).get("outputHash"):
            return True
        return any(isinstance(o, dict) and o.get("hash") for o in (drv.get("outputs") or {}).values())

    @staticmethod
    def fod_hash_algo(drv):
        """sha256/sha512/sha1/md5/... of a fixed-output derivation, or None."""
        for o in (drv.get("outputs") or {}).values():
            if not isinstance(o, dict):
                continue
            if o.get("hashAlgo"):
                return str(o["hashAlgo"]).split(":")[-1]
            h = o.get("hash")
            if isinstance(h, str):
                m = re.match(r"^(md5|sha1|sha256|sha512)[-:]", h)
                if m:
                    return m.group(1)
        env = drv.get("env") or {}
        if env.get("outputHashAlgo"):
            return env["outputHashAlgo"]
        m = re.match(r"^(md5|sha1|sha256|sha512)[-:]", env.get("outputHash") or "")
        return m.group(1) if m else None

    def fresh(self):
        """Store the anonymous evaluation runs in. It never sees a private
        path, so nothing the local store holds can satisfy a fetch there."""
        return ["--store", self.cfg["eval_store"]]

    def candidates(self, ref):
        expr = ('ps: builtins.mapAttrs (n: p: { drv = p.drvPath; '
                'outs = map (o: (builtins.getAttr o p).outPath) (p.outputs or ["out"]); }) ps')
        out = self.w.nix(["eval", *self.fresh(), "--json", f"{ref}#packages.{self.cfg['system']}", "--apply", expr])
        attrs = json.loads(out)
        return {a: v for a, v in attrs.items()
                if isinstance(v, dict) and isinstance(v.get("outs"), list) and v.get("drv")}

    def select(self, outs):
        """Outputs worth pushing: valid locally, built here, not FOD, not
        upstream, and with more than min_nar bytes of closure that
        cache.nixos.org does not already serve (the "compiled code" test:
        a text-only repo's outputs are tiny, a wrapper around locally built
        libraries is not)."""
        info = self.path_info(outs)
        upstream = self.upstream_set([p for p in outs if info.get(p)])
        keep = []
        for p in outs:
            v = info.get(p)
            if not v:
                continue  # not built locally: nothing to push, nothing to build
            if not v.get("ultimate"):
                continue
            if (v.get("ca") or "").startswith("fixed:"):
                continue
            if p in upstream:
                continue
            keep.append(p)
        if not keep:
            return []
        closure = json.loads(self.w.nix(["path-info", "--json", "--json-format", "1", *self.local(),
                                         "--recursive", *keep]))
        if any(v is None for v in closure.values()):
            return []  # incomplete locally: cachix could not push it anyway
        up = self.upstream_set(closure)
        size = sum(v.get("narSize", 0) for p, v in closure.items() if p not in up)
        return keep if size >= self.cfg["min_nar"] else []

    def audit_build_graph(self, drv):
        """Prove every byte the build consumed is public.

        Eval-time sources are proven by the anonymous fresh-store evaluation.
        Build-time fetches (fixed-output derivations) are pinned only by
        hash, and Nix keys downstream output paths on that hash, not on the
        URL: a FOD whose hash matches private content already in the local
        store would make a "public" recipe yield a local output built from
        private bytes. So each FOD must be served by cache.nixos.org, or be
        downloaded anonymously into the fresh store right now (Nix verifies
        the hash). A URL or host is never taken as proof."""
        graph = json.loads(self.w.nix(["derivation", "show", *self.fresh(), "--recursive", drv]))
        graph = graph.get("derivations", graph)
        fods = []
        for name, d in sorted(graph.items()):
            env = d.get("env") or {}
            sa = d.get("structuredAttrs") or {}
            for k in ("__noChroot", "__impure"):
                if env.get(k) in ("1", True) or sa.get(k) is True:
                    raise Skip(f"{name} sets {k}: its local output may contain host state")
            if self.is_fod(d):
                algo = self.fod_hash_algo(d)
                if algo not in ("sha256", "sha512"):
                    # A weak hash lets public and private bytes share a path.
                    raise Skip(f"fixed-output {name} uses hash algorithm {algo!r}")
                fods.append(name if name.startswith("/") else f"/nix/store/{name}")
        if not fods:
            return
        # A FOD has exactly one output, so --outputs prints one line per drv.
        outs = self.w.nix_store([*self.fresh(), "--query", "--outputs", *fods]).split()
        if len(outs) != len(fods):
            raise Skip("cannot map fixed-output derivations to their outputs")
        upstream = self.upstream_set(outs)
        missing = [f"{d}^out" for d, o in zip(fods, outs) if o not in upstream]
        if missing:
            # substituters = cache.nixos.org only (see NIX_CONFIG_FRESH): the
            # bytes come from their public URL or from upstream, never from
            # the local store or the target cache.
            self.w.nix(["build", *self.fresh(), "--no-link", *missing])

    def process(self, owner, repo, sha):
        """Returns list of pushed paths. Raises Skip/Retry."""
        if not self.repo_public(owner, repo):
            raise Skip(f"{owner}/{repo} is not public")
        self.commit_public(owner, repo, sha)
        ref = f"github:{owner}/{repo}/{sha}"
        inputs = self.audit_lock(ref)  # also the "no flake.nix" skip: nothing to publish
        pushed = []
        for attr, c in sorted(self.candidates(ref).items()):
            # Output paths come from the anonymous evaluation, so a local
            # path with the same name was built from exactly that public
            # recipe (input-addressed paths hash the whole build graph).
            keep = self.select(c["outs"])
            if not keep:
                self.log(f"skip {owner}/{repo}#{attr}: nothing built locally above threshold")
                continue
            try:
                self.audit_build_graph(c["drv"])
            except Skip as e:
                self.log(f"skip {owner}/{repo}#{attr}: {e}")
                continue
            pushed += keep
        if not pushed:
            return []
        # The last word belongs to GitHub, right before upload: the repo, the
        # commit and every GitHub lock input, uncached.
        if not self.repo_public(owner, repo):
            raise Skip(f"{owner}/{repo} stopped being public before upload")
        self.commit_public(owner, repo, sha)
        for o, r, rev in inputs:
            if not self.repo_public(o, r):
                raise Skip(f"lock input {o}/{r} stopped being public before upload")
            if self.commit_status(o, r, rev) != 200:
                raise Skip(f"lock input {o}/{r}@{rev[:12]} stopped being fetchable before upload")
        self.w.cachix_push(pushed)
        return pushed


class RateLimited(Retry):
    pass


# ── spool driver ────────────────────────────────────────────────────────────

def read_entry(path):
    """Read a spool entry without following symlinks or blocking on FIFOs:
    jonathan controls what lands in the spool, the publisher's user must not
    be tricked into reading anything else."""
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError:
        return ""
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return ""
        return os.read(fd, 512).decode("ascii", "replace").strip()
    finally:
        os.close(fd)


def read_json(path):
    with open(path) as f:
        return json.load(f)


def write_json(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


def key_of(owner, repo, sha):
    return f"{owner}__{repo}__{sha}"


def run(cfg, world, log=print):
    spool, state = cfg["spool"], cfg["state"]
    for d in ("pending", "done"):
        os.makedirs(os.path.join(state, d), exist_ok=True)
    # 1. ingest spool files into pending state (dedupe; done entries dropped)
    for name in sorted(os.listdir(spool)):
        f = os.path.join(spool, name)
        line = read_entry(f)
        try:
            os.unlink(f)
        except OSError:
            pass
        m = ENTRY_RE.match(line)
        if not m:
            log(f"drop malformed spool entry {name!r}")
            continue
        k = key_of(*m.groups())
        if os.path.exists(os.path.join(state, "done", k)):
            continue
        pf = os.path.join(state, "pending", k)
        if not os.path.exists(pf):
            write_json(pf, {"entry": line, "first": world.now(), "next": 0, "tries": 0})
    # 2. keep the anonymous evaluation store bounded: drop it daily
    marker = os.path.join(state, "evalstore-gc")
    if os.path.isdir(cfg["eval_store"]) and (
            not os.path.exists(marker) or world.now() - os.path.getmtime(marker) > 86400):
        try:
            world.nix(["store", "gc", "--store", cfg["eval_store"]])
        except (Retry, Skip) as e:
            log(f"evalstore gc failed: {e}")
        with open(marker, "w"):
            pass
    # 3. process due pending entries
    pub = Publisher(cfg, world, log)
    for k in sorted(os.listdir(os.path.join(state, "pending"))):
        pf = os.path.join(state, "pending", k)
        st = read_json(pf)
        if st["next"] > world.now():
            continue
        owner, repo, sha = ENTRY_RE.match(st["entry"]).groups()
        try:
            pushed = pub.process(owner, repo, sha)
            log(f"done {owner}/{repo}@{sha[:12]}: pushed {len(pushed)} path(s)" + "".join(f"\n  {p}" for p in pushed))
            final = True
        except RateLimited as e:
            log(f"retry later {owner}/{repo}@{sha[:12]}: {e}")
            st["next"] = e.not_before
            write_json(pf, st)
            break  # every further call would be rate limited too
        except Retry as e:
            st["tries"] += 1
            if world.now() - st["first"] > cfg["expire"]:
                log(f"expire {owner}/{repo}@{sha[:12]}: {e}")
                final = True
            else:
                st["next"] = world.now() + min(3600, 120 * 2 ** min(st["tries"], 5))
                write_json(pf, st)
                log(f"retry {owner}/{repo}@{sha[:12]}: {e}")
                continue
        except Skip as e:
            log(f"skip {owner}/{repo}@{sha[:12]}: {e}")
            final = True
        if final:
            open(os.path.join(state, "done", k), "w").close()
            os.unlink(pf)


def scan(cfg, log=print):
    """Enqueue HEADs of GitHub checkouts that are on origin (pushed)."""
    roots = cfg["scan_roots"]
    n = 0
    for root in roots:
        try:
            names = os.listdir(root)
        except OSError:
            continue
        for name in names:
            d = os.path.join(root, name)
            if not os.path.exists(os.path.join(d, ".git")):
                continue

            def git(*a):
                return subprocess.run(["git", "-C", d, *a], capture_output=True, text=True, timeout=30)
            url = git("remote", "get-url", "origin").stdout.strip()
            m = re.match(r"^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9-]+)/([A-Za-z0-9._-]+?)(?:\.git)?/?$", url)
            if not m:
                continue
            head = git("rev-parse", "HEAD").stdout.strip()
            if not re.fullmatch(r"[0-9a-f]{40}", head):
                continue
            if not git("for-each-ref", "--contains", head, "refs/remotes/origin").stdout.strip():
                continue  # not pushed: not public yet
            enqueue(cfg["spool"], m.group(1), m.group(2), head)
            n += 1
    log(f"scan: enqueued {n} checkout HEAD(s)")


def enqueue(spool, owner, repo, sha):
    line = f"{owner}/{repo} {sha}"
    if not ENTRY_RE.match(line):
        return
    tmp = os.path.join(spool, f".{os.getpid()}-{sha}")
    with open(tmp, "w") as f:
        f.write(line + "\n")
    os.rename(tmp, os.path.join(spool, f"{int(time.time())}-{owner}-{repo}-{sha}"))


def config_from_env():
    e = os.environ
    return {
        "spool": e.get("CP_SPOOL", "/var/lib/cache-publisher/queue"),
        "state": e.get("CP_STATE", "/var/lib/cache-publisher/state"),
        "cache": e.get("CP_CACHE", "jonathanmoregard"),
        "token_file": e.get("CP_TOKEN_FILE", ""),
        "system": e.get("CP_SYSTEM", "x86_64-linux"),
        "github_api": e.get("CP_GITHUB_API", "https://api.github.com"),
        "upstream": e.get("CP_UPSTREAM", "https://cache.nixos.org"),
        "eval_store": e.get("CP_EVAL_STORE", "/var/lib/cache-publisher/evalstore"),
        "local_store": e.get("CP_LOCAL_STORE", "daemon"),
        "min_nar": int(e.get("CP_MIN_NAR_BYTES", str(1024 * 1024))),
        "input_ttl": int(e.get("CP_INPUT_TTL", "600")),
        "expire": int(e.get("CP_EXPIRE", str(48 * 3600))),
        "url_allow": e.get("CP_URL_ALLOW", "nixos.org").split(),
        "scan_roots": [os.path.expanduser(p) for p in e.get("CP_SCAN_ROOTS", "~/Repos ~/worktrees").split()],
    }


def main(argv):
    cfg = config_from_env()
    if argv[1:2] == ["run"]:
        run(cfg, World(cfg), log=lambda m: print(m, flush=True))
    elif argv[1:2] == ["scan"]:
        scan(cfg, log=lambda m: print(m, flush=True))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
