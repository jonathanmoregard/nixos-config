"""Unit tests for scripts/cache-publisher.py: every gate fails closed.

The world (GitHub API, nix, cachix) is stubbed; the gates are the real code.
Run: python3 -m unittest tests/cache-publisher/test_publisher.py
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.environ.get("CACHE_PUBLISHER_SRC", os.path.join(HERE, "..", "..", "scripts", "cache-publisher.py"))
spec = importlib.util.spec_from_file_location("cp", SRC)
cp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cp)

SHA = "a" * 40
SHA2 = "b" * 40
NIXPKGS_REV = "c" * 40
OUT = "/nix/store/0000000000000000000000000000000a-tool-1.0"
DEP = "/nix/store/0000000000000000000000000000000b-libfoo-2.0"
GLIBC = "/nix/store/0000000000000000000000000000000c-glibc-2.40"
SRCP = "/nix/store/0000000000000000000000000000000d-source"
FODP = "/nix/store/0000000000000000000000000000000e-vendored.tar.gz"
# A locally built path the publisher must never upload: stands in for a
# private repo's output that a public flake names but did not produce.
PRIV = "/nix/store/0000000000000000000000000000000f-klaffat-secret-1.0"
MiB = 1024 * 1024


def lock(**inputs):
    nodes = {"root": {"inputs": {k: k for k in inputs}}}
    nodes.update({k: {"locked": v} for k, v in inputs.items()})
    return {"root": "root", "nodes": nodes, "version": 7}


NIXPKGS = {"type": "github", "owner": "NixOS", "repo": "nixpkgs", "rev": NIXPKGS_REV, "narHash": "sha256-x"}


class World:
    """Stub world. `repos` values: 'public' | 'private' | list of those (one per call)."""

    def __init__(self):
        self.t = 1_000_000.0
        self.repos = {"me/tool": "public", "NixOS/nixpkgs": "public"}
        self.commits = {f"me/tool@{SHA}", f"NixOS/nixpkgs@{NIXPKGS_REV}"}
        self.network_down = False
        self.rate_limited = False
        self.meta = {"revision": SHA, "locks": lock(nixpkgs=NIXPKGS)}
        self.no_flake = False
        self.packages = {"default": [OUT]}
        # What the anonymous store's own copy of `<attr>.drv` declares as its
        # output paths, per attr. Defaults to the evaluated ones (an honest
        # flake); set an entry to make the derivation disagree with what the
        # flake's attrset claimed, or to [] for a drvPath that was never
        # instantiated there (a literal string in the flake).
        self.drv_outs = {}
        # Make evaluation report a drvPath that is really a nix flag, as a
        # hostile flake can: `--version` is accepted, exits 0 and prints
        # non-JSON. `unexpected`/`unexpected_for` raise something that is
        # neither Retry nor Skip, which used to escape run() entirely.
        self.drv_flag = False
        self.unexpected = None
        self.unexpected_for = None
        self.local = {OUT: {"ultimate": True, "ca": None, "narSize": 5 * MiB, "deriver": OUT + ".drv"}}
        self.closure = {OUT: {"narSize": 5 * MiB}, DEP: {"narSize": 3 * MiB}, GLIBC: {"narSize": 30 * MiB}}
        # build graph of the candidate, as `nix derivation show -r` in the eval store
        self.graph = {"tool.drv": {"env": {}, "outputs": {"out": {"path": "x"}}},
                      "glibc-src.drv": {"env": {"outputHash": "sha256-g", "urls": "https://ftp.gnu.org/glibc.tar.xz"}},
                      "crate.drv": {"env": {}, "outputs": {"out": {"hash": "sha256-c", "method": "flat"}}}}
        self.fod_outs = {"glibc-src.drv": [GLIBC]}
        self.upstream = {GLIBC}
        self.pushed = []
        self.nix_calls = []
        self.nix_fail = None
        self.gh_calls = []
        self.seen = {}
        self.realised = []
        self.unfetchable = set()

    def now(self):
        return self.t

    def http_get(self, url):
        self.gh_calls.append(url)
        if self.network_down:
            raise OSError("Network is unreachable")
        if self.rate_limited:
            return 403, {"x-ratelimit-reset": str(int(self.t) + 900), "x-ratelimit-remaining": "0"}, b""
        path = url.split("api.example", 1)[1]
        parts = path.strip("/").split("/")
        name = f"{parts[1]}/{parts[2]}"
        if len(parts) == 3:
            v = self.repos.get(name)
            if isinstance(v, list):
                v = v.pop(0) if len(v) > 1 else v[0]
            self.seen[name] = v
            if v in ("private200", "internal"):
                # an authenticated-looking answer: 200, but not public
                body = {"private": v == "private200", "visibility": "private" if v == "private200" else "internal"}
                return 200, {}, json.dumps(body).encode()
            if v != "public":
                return 404, {}, b'{"message":"Not Found"}'
            return 200, {}, json.dumps({"private": False, "visibility": "public"}).encode()
        if parts[3] == "commits":
            v = self.seen.get(name, self.repos.get(name))
            ok = v in ("public", "private200", "internal") and f"{name}@{parts[4]}" in self.commits
            return (200 if ok else 404), {}, b"{}"
        return 404, {}, b""

    def nix(self, args):
        self.nix_calls.append(args)
        # systemd-run-based wrappers expand ${VAR}; keep args free of it
        assert not any("${" in a for a in args), args
        if self.unexpected:
            raise self.unexpected
        if self.unexpected_for and any(f"github:{self.unexpected_for}/" in a for a in args):
            raise subprocess.TimeoutExpired("nix", 1800)
        if self.nix_fail:
            raise cp.nix_error(args, self.nix_fail)
        if args[:2] == ["flake", "metadata"]:
            if self.no_flake:
                raise cp.nix_error(args, "error: path '/nix/store/x-source/flake.nix' does not exist")
            return json.dumps(self.meta)
        if args[0] == "store":
            return ""
        if args[0] == "build":
            assert args[1:3] == ["--store", "/eval"], args  # anonymous realisation only
            self.realised += [a for a in args if a.endswith("^out")]
            for a in args:
                if a.endswith("^out") and os.path.basename(a[:-4]) in self.unfetchable:
                    raise cp.nix_error(args, "error: unable to download 'https://x/y': HTTP error 404")
            return ""
        if args[0] == "eval":
            assert args[1:3] == ["--store", "/eval"], args  # anonymous fresh store, never local
            return json.dumps({a: {"drv": "--version" if self.drv_flag else f"/nix/store/{a}.drv",
                                   "outs": o} for a, o in self.packages.items()})
        if args[0] == "derivation":
            assert args[2:4] == ["--store", "/eval"], args
            # Real `nix derivation show` (json version 4, the pinned Nix)
            # keys the graph by BASENAME and reports outputs.<n>.path as a
            # basename too — verified against nix 2.34.9. Reproducing that
            # exactly is load-bearing: a stub that hands back absolute paths
            # lets an absolute-path lookup pass here and skip every candidate
            # in production. The graph includes the derivation asked about, so
            # the candidate's own drv is present with the outputs IT declares,
            # which is what binds a pushed path to the audited recipe.
            g = dict(self.graph)
            for a, evaluated in self.packages.items():
                real = self.drv_outs.get(a, evaluated)
                if real == [] and a in self.drv_outs:
                    continue  # never instantiated in the eval store
                g[f"{a}.drv"] = {
                    "env": {},
                    "outputs": {f"out{i}" if i else "out":
                                {"path": p.removeprefix("/nix/store/")}
                                for i, p in enumerate(real)},
                }
            return json.dumps({"derivations": g, "version": 4})
        if args[0] == "path-info":
            rest = args[4:]
            assert rest[0] == "--store", args
            store, rest = rest[1], rest[2:]
            if store == "https://upstream.example":
                return json.dumps({p: ({} if p in self.upstream else None) for p in rest})
            assert store == "daemon", args  # the host store only via the daemon
            if "--recursive" in rest:
                return json.dumps(self.closure)
            return json.dumps({p: self.local.get(p) for p in rest})
        raise AssertionError(f"unexpected nix call {args}")

    def nix_store(self, args):
        assert args[:4] == ["--store", "/eval", "--query", "--outputs"], args
        lines = []
        for drv in args[4:]:
            name = os.path.basename(drv)
            lines += self.fod_outs.get(name, ["/nix/store/" + name.replace(".drv", "") + "-out"])
        return "\n".join(lines) + "\n"

    def cachix_push(self, paths):
        self.pushed.append(list(paths))


class Case(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = self.tmp.name
        self.cfg = {
            "spool": os.path.join(base, "queue"), "state": os.path.join(base, "state"),
            "cache": "c", "token_file": "", "system": "x86_64-linux",
            "github_api": "https://api.example", "upstream": "https://upstream.example",
            "min_nar": MiB, "input_ttl": 600, "expire": 48 * 3600, "url_allow": ["nixos.org", "crates.io"],
            "eval_store": "/eval", "local_store": "daemon",
        }
        os.makedirs(self.cfg["spool"])
        self.w = World()
        self.logs = []

    def tearDown(self):
        self.tmp.cleanup()

    def enqueue(self, line):
        with open(os.path.join(self.cfg["spool"], f"e{len(os.listdir(self.cfg['spool']))}"), "w") as f:
            f.write(line + "\n")

    def run_once(self, line=f"me/tool {SHA}"):
        if line:
            self.enqueue(line)
        cp.run(self.cfg, self.w, log=self.logs.append)

    def pending(self):
        return os.listdir(os.path.join(self.cfg["state"], "pending"))

    def done(self):
        return os.listdir(os.path.join(self.cfg["state"], "done"))

    def log(self):
        return "\n".join(self.logs)

    # ── happy path ──────────────────────────────────────────────────────────
    def test_public_repo_pushes_built_output_only(self):
        self.run_once()
        self.assertEqual(self.w.pushed, [[OUT]])
        self.assertEqual(self.pending(), [])
        self.assertEqual(len(self.done()), 1)
        # every nix eval/fetch targets the github ref, never a local checkout
        refs = [a for c in self.w.nix_calls for a in c if a.startswith("github:") or "#" in a]
        self.assertTrue(refs and all(r.startswith(f"github:me/tool/{SHA}") for r in refs), refs)

    def test_done_entry_is_not_reprocessed(self):
        self.run_once()
        calls = len(self.w.gh_calls)
        self.run_once()
        self.assertEqual(len(self.w.gh_calls), calls)
        self.assertEqual(len(self.w.pushed), 1)

    # ── visibility ──────────────────────────────────────────────────────────
    def test_private_repo_404_never_pushes(self):
        self.w.repos["me/tool"] = "private"
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("is not public", self.log())
        self.assertEqual(self.w.nix_calls, [])  # nothing private is even fetched

    def test_200_but_private_or_internal_never_pushes(self):
        # A distinct sha per visibility, because the first iteration retires
        # its sha into `done` and `run` drops a later entry for a done sha —
        # with one sha the second case silently never ran, and deleting the
        # `visibility == "public"` check kept the whole suite green.
        for sha, v in ((SHA, "private200"), (SHA2, "internal")):
            self.w.commits.add(f"me/tool@{sha}")
            self.w.repos["me/tool"] = v
            self.w.seen.clear()
            self.run_once(f"me/tool {sha}")
            self.assertEqual(self.w.pushed, [], v)
            self.assertEqual(self.w.seen.get("me/tool"), v, v)

    def test_flip_to_private_before_upload_never_pushes(self):
        self.w.repos["me/tool"] = ["public", "private"]
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("stopped being public before upload", self.log())

    def test_unpushed_commit_retries_then_expires(self):
        self.w.commits.discard(f"me/tool@{SHA}")
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertEqual(len(self.pending()), 1)
        self.w.t += 49 * 3600
        self.run_once(None)
        self.assertEqual(self.pending(), [])
        self.assertIn("expire", self.log())
        self.assertEqual(self.w.pushed, [])

    def test_unpushed_commit_then_pushed_publishes(self):
        self.w.commits.discard(f"me/tool@{SHA}")
        self.run_once()
        self.w.commits.add(f"me/tool@{SHA}")
        self.w.t += 4000
        self.run_once(None)
        self.assertEqual(self.w.pushed, [[OUT]])

    def test_network_down_retries_without_push(self):
        self.w.network_down = True
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertEqual(len(self.pending()), 1)
        self.assertIn("github unreachable", self.log())

    def test_rate_limit_defers_until_reset(self):
        self.w.rate_limited = True
        self.run_once()
        st = json.load(open(os.path.join(self.cfg["state"], "pending", self.pending()[0])))
        self.assertEqual(st["next"], int(self.w.t) + 900)
        self.assertEqual(self.w.pushed, [])

    # ── lock audit ──────────────────────────────────────────────────────────
    def test_private_github_lock_input_skips(self):
        self.w.meta["locks"] = lock(nixpkgs=NIXPKGS, secret={"type": "github", "owner": "me", "repo": "klaffat", "rev": SHA2})
        self.w.repos["me/klaffat"] = "private"
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("me/klaffat is not public", self.log())

    def test_lock_input_rev_not_public_skips(self):
        self.w.meta["locks"] = lock(nixpkgs=dict(NIXPKGS, rev=SHA2))
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("not anonymously fetchable", self.log())

    def test_git_ssh_input_skips(self):
        self.w.meta["locks"] = lock(nixpkgs=NIXPKGS, x={"type": "git", "url": "ssh://git@github.com/me/tool.git", "rev": SHA})
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("not an https GitHub URL", self.log())

    def test_path_input_skips(self):
        self.w.meta["locks"] = lock(nixpkgs=NIXPKGS, x={"type": "path", "path": "/home/me/private"})
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("'path' not allowed", self.log())

    def test_tarball_input_off_allowlist_skips(self):
        self.w.meta["locks"] = lock(nixpkgs=NIXPKGS, x={"type": "tarball", "url": "https://evil.example/x.tar.gz"})
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    def test_github_tarball_input_skips(self):
        # Round-4 review: would bypass the pre-upload rev re-check
        self.w.meta["locks"] = lock(nixpkgs=NIXPKGS, x={
            "type": "tarball", "url": "https://github.com/NixOS/nixpkgs/archive/" + NIXPKGS_REV + ".tar.gz"})
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("use a github: input", self.log())

    def test_nixos_channel_tarball_input_ok(self):
        self.w.meta["locks"] = lock(nixpkgs=NIXPKGS, x={
            "type": "tarball", "url": "https://channels.nixos.org/nixos-unstable/nixexprs.tar.xz"})
        self.run_once()
        self.assertEqual(self.w.pushed, [[OUT]])

    def test_unlocked_input_skips(self):
        self.w.meta["locks"]["nodes"]["nixpkgs"] = {"original": {"type": "indirect", "id": "nixpkgs"}}
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("unlocked", self.log())

    def test_no_revision_skips(self):
        self.w.meta["revision"] = None
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    def test_no_flake_is_final_skip(self):
        self.w.no_flake = True
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertEqual(self.pending(), [])
        self.assertEqual(len(self.done()), 1)

    def test_transient_nix_error_retries(self):
        self.w.nix_fail = "error: unable to download 'https://github.com/...': Could not resolve host"
        self.run_once()
        self.assertEqual(len(self.pending()), 1)
        self.assertEqual(self.w.pushed, [])

    def test_anonymous_fetch_404_retries_until_expiry(self):
        # GitHub API says public, but the archive is not (yet) downloadable
        self.w.nix_fail = ("error: unable to download 'https://github.com/me/tool/archive/x.tar.gz': "
                           "HTTP error 404")
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertEqual(len(self.pending()), 1)

    # ── selection + closure audit ───────────────────────────────────────────
    def test_tiny_closure_not_pushed(self):
        # only upstream bytes beyond a tiny output: nothing worth pushing
        self.w.closure = {OUT: {"narSize": 4096}, GLIBC: {"narSize": 30 * MiB}}
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    def test_small_wrapper_with_big_local_closure_pushed(self):
        self.w.closure = {OUT: {"narSize": 900}, DEP: {"narSize": 40 * MiB}}
        self.run_once()
        self.assertEqual(self.w.pushed, [[OUT]])

    def test_closure_incomplete_locally_not_pushed(self):
        self.w.closure[DEP] = None
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    def test_output_already_on_upstream_not_pushed(self):
        self.w.upstream.add(OUT)
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    def test_unbuilt_output_not_pushed(self):
        self.w.local = {}
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    def test_substituted_output_not_pushed(self):
        self.w.local[OUT]["ultimate"] = False
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    # ── output paths are bound to the audited derivation ────────────────────
    # `candidates` reads drvPath and outPath out of the flake, and a flake can
    # state them independently: a hand-written attrset may pair a harmless
    # derivation's drvPath with any string as its outPath, which pure
    # evaluation accepts (a literal instantiates nothing). Auditing the
    # harmless graph then says nothing about the path being uploaded, so the
    # paths that decide the upload come from the derivation itself.
    def test_output_path_not_declared_by_candidate_drv_never_pushes(self):
        self.w.drv_outs["default"] = [OUT]          # what the recipe builds
        self.w.packages = {"default": [PRIV]}       # what the flake claims
        self.w.local[PRIV] = {"ultimate": True, "ca": None, "narSize": 5 * MiB,
                              "deriver": PRIV + ".drv"}
        self.w.closure[PRIV] = {"narSize": 5 * MiB}
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertNotIn(PRIV, str(self.w.pushed))
        self.assertIn("does not declare", self.log())

    def test_candidate_drv_absent_from_eval_store_never_pushes(self):
        # drvPath was a literal string, so the anonymous evaluation never
        # instantiated a derivation for it.
        self.w.drv_outs["default"] = []
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("not in the anonymous store", self.log())

    def test_honest_multi_output_package_still_pushes(self):
        self.w.packages = {"default": [OUT, DEP]}
        self.w.local[DEP] = {"ultimate": True, "ca": None, "narSize": 3 * MiB,
                             "deriver": OUT + ".drv"}
        self.run_once()
        self.assertEqual(self.w.pushed, [[OUT, DEP]])

    # ── local availability is not a verdict ─────────────────────────────────
    # Nothing built locally yet is a "not yet", not a "no": the hook enqueues
    # on push, which routinely happens before the build finishes. Retiring the
    # commit there would discard every later entry for that sha (`done` is
    # checked before the spool entry becomes pending), suppressing the upload
    # permanently.
    def test_unbuilt_commit_is_not_retired(self):
        self.w.local = {}
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertEqual(len(self.pending()), 1)
        self.assertEqual(self.done(), [])

    def test_unbuilt_commit_publishes_once_built(self):
        built = dict(self.w.local)
        self.w.local = {}
        self.run_once()
        self.w.local = built
        self.w.t += 4000
        self.run_once(None)
        self.assertEqual(self.w.pushed, [[OUT]])

    def test_unbuilt_commit_reenqueued_after_build_publishes(self):
        # The reviewer's reproduction: process unbuilt, build it, enqueue the
        # same sha again (hook push or hourly scan).
        built = dict(self.w.local)
        self.w.local = {}
        self.run_once()
        self.w.local = built
        self.w.t += 4000
        self.run_once()
        self.assertEqual(self.w.pushed, [[OUT]])

    def test_unbuilt_commit_eventually_expires(self):
        # Bounded: an entry that never gets built must not be retried forever.
        self.w.local = {}
        self.run_once()
        self.w.t += 49 * 3600
        self.run_once(None)
        self.assertEqual(self.pending(), [])
        self.assertEqual(len(self.done()), 1)
        self.assertEqual(self.w.pushed, [])

    def test_partially_built_multi_output_pushes_and_stays_queued(self):
        # One output built, one not. The built one goes, and the commit must
        # NOT be retired, or the second output is lost for good.
        self.w.packages = {"default": [OUT, DEP]}
        self.run_once()
        self.assertEqual(self.w.pushed, [[OUT]])
        self.assertEqual(len(self.pending()), 1)
        self.assertEqual(self.done(), [])
        # now the second output appears
        self.w.local[DEP] = {"ultimate": True, "ca": None, "narSize": 3 * MiB,
                             "deriver": OUT + ".drv"}
        self.w.t += 4000
        self.run_once(None)
        self.assertEqual(self.w.pushed[-1], [OUT, DEP])
        self.assertEqual(self.pending(), [])

    # ── a single entry cannot wedge the queue ───────────────────────────────
    def test_drv_path_that_is_a_nix_flag_is_skipped(self):
        # `nix derivation show --store /eval --version` exits 0 and prints
        # non-JSON, which crashed the run. Entries are processed in sorted
        # order, so one such entry starved every entry after it, every run.
        self.w.packages = {"default": [OUT]}
        self.w.drv_flag = True
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("not a store derivation path", self.log())

    def test_unexpected_exception_retries_instead_of_wedging(self):
        self.w.unexpected = subprocess.TimeoutExpired("nix", 1800)
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertEqual(len(self.pending()), 1)   # kept, with backoff
        self.assertEqual(self.done(), [])
        self.assertIn("unexpected TimeoutExpired", self.log())
        # and it expires rather than retrying forever
        self.w.t += 49 * 3600
        self.run_once(None)
        self.assertEqual(self.pending(), [])
        self.assertEqual(len(self.done()), 1)

    def test_one_poison_entry_does_not_starve_later_entries(self):
        # '0bad' sorts before 'me', which is the starvation order that made
        # this fatal rather than merely noisy.
        self.w.repos["0bad/repo"] = "public"
        self.w.commits.add(f"0bad/repo@{SHA}")
        self.w.unexpected_for = "0bad/repo"
        self.enqueue(f"0bad/repo {SHA}")
        self.run_once()
        self.assertEqual(self.w.pushed, [[OUT]])  # me/tool still published
        self.assertIn("unexpected TimeoutExpired", self.log())

    def test_built_but_nothing_worth_pushing_is_retired(self):
        # Built locally and simply too small: a conclusive answer. It must be
        # retired, not left re-evaluating every hour for 48 h.
        self.w.closure = {OUT: {"narSize": 4096}, GLIBC: {"narSize": 30 * MiB}}
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertEqual(self.pending(), [])
        self.assertEqual(len(self.done()), 1)

    def add_fod(self, name="vendored.drv", url="https://registry.npmjs.org/x.tgz", structured=False):
        d = {"env": {"out": "x"}, "outputs": {"out": {"hash": "sha256-x", "method": "nar"}}}
        if structured:
            d["structuredAttrs"] = {"urls": [url]}
        else:
            d["env"]["url"] = url
        self.w.graph[name] = d

    def test_upstream_fods_need_no_download(self):
        # glibc-src.drv is a FOD whose output cache.nixos.org serves
        self.run_once()
        self.assertEqual(self.w.pushed, [[OUT]])
        self.assertNotIn("/nix/store/glibc-src.drv^out", self.w.realised)

    def test_non_upstream_fod_is_downloaded_anonymously_then_pushed(self):
        self.add_fod()
        self.run_once()
        self.assertIn("/nix/store/vendored.drv^out", self.w.realised)
        self.assertEqual(self.w.pushed, [[OUT]])

    def test_fod_with_public_looking_url_but_private_hash_never_pushes(self):
        # Review finding: an allowlisted URL is not proof. The hash matches
        # private bytes in the local store; anonymously the URL can't produce it.
        self.add_fod(url="https://registry.npmjs.org/looks-public.tgz")
        self.w.unfetchable.add("vendored.drv")
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertEqual(len(self.pending()), 1)  # retried, then expired
        self.w.t += 49 * 3600
        self.run_once(None)
        self.assertEqual(self.w.pushed, [])
        self.assertEqual(self.pending(), [])

    def test_fod_from_private_github_never_pushes(self):
        self.add_fod(url="https://github.com/me/klaffat/archive/" + SHA2 + ".tar.gz", structured=True)
        self.w.unfetchable.add("vendored.drv")
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    def test_crate_fod_counts_as_build_input(self):
        # crate.drv in the default graph is a non-upstream FOD: it is realised
        self.run_once()
        self.assertIn("/nix/store/crate.drv^out", self.w.realised)

    def test_sha1_fod_hash_skips(self):
        self.w.graph["weak.drv"] = {"env": {}, "outputs": {"out": {"hash": "sha1-AAAA", "method": "flat"}}}
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("hash algorithm 'sha1'", self.log())

    def test_md5_fod_hash_skips(self):
        self.w.graph["weak.drv"] = {"env": {"outputHash": "AAAA", "outputHashAlgo": "md5"}}
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    def test_weak_fod_hash_even_if_upstream_skips(self):
        self.w.graph["glibc-src.drv"] = {"env": {"outputHash": "AAAA", "outputHashAlgo": "sha1"}}
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    def test_unknown_fod_hash_algo_skips(self):
        self.w.graph["odd.drv"] = {"env": {"outputHash": "AAAA"}, "outputs": {"out": {}}}
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    def test_no_chroot_derivation_skips(self):
        self.w.graph["impure.drv"] = {"env": {"__noChroot": "1"}, "outputs": {"out": {"path": "x"}}}
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("__noChroot", self.log())

    def test_impure_derivation_skips(self):
        self.w.graph["impure.drv"] = {"env": {}, "structuredAttrs": {"__impure": True}, "outputs": {"out": {}}}
        self.run_once()
        self.assertEqual(self.w.pushed, [])

    def test_lock_input_turning_private_before_upload_never_pushes(self):
        self.w.repos["NixOS/nixpkgs"] = ["public", "private"]
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertIn("stopped being public before upload", self.log())

    def test_input_cache_not_used_for_final_recheck(self):
        # first entry warms the input cache; second must still re-ask GitHub
        self.run_once()
        self.w.commits.add(f"me/tool@{SHA2}")
        self.w.repos["NixOS/nixpkgs"] = ["public", "private"]
        self.run_once(f"me/tool {SHA2}")
        self.assertEqual(len(self.w.pushed), 1)

    def test_eval_failure_in_fresh_store_never_pushes(self):
        # e.g. an eval-time fetch of private content: the anonymous store can't get it
        self.w.nix_fail = "error: Cannot find Git revision 'deadbeef' in ref 'refs/heads/main' of repository 'https://github.com/me/klaffat'"
        self.run_once()
        self.assertEqual(self.w.pushed, [])
        self.assertEqual(len(self.done()), 1)

    # ── spool hygiene ───────────────────────────────────────────────────────
    def test_malformed_entries_dropped(self):
        for bad in ["me/tool", f"me/tool {SHA} extra", f"../x {SHA}", "me/tool; rm -rf / " + SHA, f"me/tool {SHA[:39]}"]:
            self.enqueue(bad)
        cp.run(self.cfg, self.w, log=self.logs.append)
        self.assertEqual(os.listdir(self.cfg["spool"]), [])
        self.assertEqual(self.pending(), [])
        self.assertEqual(self.w.gh_calls, [])


@unittest.skipUnless(shutil.which("nix"), "needs a real nix")
class RealNixEval(unittest.TestCase):
    """Round-3 review: in plain pure eval, `fetchTree { type = "path"; narHash }`
    copies a host store path into the fresh store, so a public flake could
    smuggle private bytes into the "anonymous" evaluation. The publisher's
    NIX_CONFIG_FRESH (restrict-eval + allowed-uris) must refuse it."""

    def probe(self, nix_config):
        with tempfile.TemporaryDirectory() as d:
            secret = os.path.join(d, "private")  # stands in for a private host path
            os.makedirs(secret)
            with open(os.path.join(secret, "key"), "w") as f:
                f.write("PRIVATE-BYTES\n")
            env = dict(os.environ, NIX_CONFIG=nix_config, HOME=d)
            nar_hash = subprocess.run(["nix", "--extra-experimental-features", "nix-command",
                                       "hash", "path", secret],
                                      capture_output=True, text=True, env=env).stdout.strip()
            self.assertTrue(nar_hash.startswith("sha256-"), nar_hash)
            expr = f'(builtins.fetchTree {{ type = "path"; path = "{secret}"; narHash = "{nar_hash}"; }}).outPath'
            return subprocess.run(["nix", "--extra-experimental-features", "nix-command flakes",
                                   "eval", "--store", os.path.join(d, "s"), "--expr", expr],
                                  capture_output=True, text=True, env=env)

    def test_plain_pure_eval_imports_host_path(self):
        # control: proves the probe would catch a regression
        p = self.probe(cp.NIX_CONFIG + "pure-eval = true\n")
        self.assertEqual(p.returncode, 0, p.stderr)

    def test_fresh_config_refuses_host_path(self):
        p = self.probe(cp.NIX_CONFIG_FRESH)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn("access to URI", p.stderr)

    def test_candidates_expression_accepts_unrelated_drv_and_out(self):
        """Why Publisher.drv_outputs exists. Under the publisher's own
        fresh-store config, a derivation-shaped attrset can pair one
        derivation's drvPath with any string as its outPath: the expression
        reads two independent attributes, and a literal instantiates nothing.
        So `outs` carries no provenance and must never decide an upload.

        If this starts failing, Nix began enforcing the binding itself and the
        guard can be revisited — it is not a regression in the publisher."""
        attrs = ('{ evil = { type = "derivation"; '
                 'drvPath = "/nix/store/00000000000000000000000000000001-harmless.drv"; '
                 'outputs = [ "out" ]; '
                 'out.outPath = "/nix/store/00000000000000000000000000000002-private"; }; }')
        with tempfile.TemporaryDirectory() as d:
            env = dict(os.environ, NIX_CONFIG=cp.NIX_CONFIG_FRESH, HOME=d)
            p = subprocess.run(["nix", "--extra-experimental-features", "nix-command flakes",
                                "eval", "--json", "--store", os.path.join(d, "s"),
                                "--expr", f"({cp.CANDIDATES_APPLY}) {attrs}"],
                               capture_output=True, text=True, env=env)
        self.assertEqual(p.returncode, 0, p.stderr)
        got = json.loads(p.stdout)["evil"]
        self.assertEqual(got["drv"], "/nix/store/00000000000000000000000000000001-harmless.drv")
        self.assertEqual(got["outs"], ["/nix/store/00000000000000000000000000000002-private"])


@unittest.skipUnless(shutil.which("nix"), "needs a real nix")
class RealNixDrvOutputs(unittest.TestCase):
    """`drv_outputs` parses `nix derivation show`, whose shape only real Nix
    can settle. The pinned 2.34.9 (json version 4) keys the graph by BASENAME
    and reports `outputs.<n>.path` as a basename, while `drvPath` from
    evaluation is absolute. An absolute-only lookup therefore matches nothing,
    skips every candidate and retires the commit: publication silently off,
    and no stub notices, because the stub's fidelity is the only thing under
    test there. Hence this runs against the real thing."""

    def run_nix(self, env, args):
        p = subprocess.run(["nix", "--extra-experimental-features", "nix-command flakes", *args],
                           capture_output=True, text=True, env=env)
        if p.returncode != 0:
            raise AssertionError(f"nix {args[0]} failed: {p.stderr}")
        return p.stdout

    def test_drv_outputs_equals_evaluated_out_paths(self):
        probe = ('(derivation { name = "probe"; system = builtins.currentSystem; '
                 'builder = "/bin/sh"; args = [ "-c" "true" ]; '
                 'outputs = [ "out" "lib" ]; })')
        outer = self
        with tempfile.TemporaryDirectory() as d:
            store = os.path.join(d, "s")
            # Setup needs --impure for builtins.currentSystem; production does
            # not, so only the fixture uses this config.
            setup = dict(os.environ, NIX_CONFIG=cp.NIX_CONFIG, HOME=d)
            # Forcing drvPath instantiates the .drv into that store.
            drv = self.run_nix(setup, ["eval", "--impure", "--store", store, "--raw",
                                       "--expr", f"{probe}.drvPath"]).strip()
            evaluated = json.loads(self.run_nix(setup, [
                "eval", "--impure", "--store", store, "--json", "--expr",
                f'map (o: (builtins.getAttr o {probe}).outPath) [ "out" "lib" ]']))

            # `drv_outputs` itself runs under exactly what World.nix sets in
            # production — NIX_CONFIG_FRESH, with restrict-eval and pure-eval.
            # Reading a .drv needs no evaluation, so it must work there.
            prod = dict(os.environ, NIX_CONFIG=cp.NIX_CONFIG_FRESH, HOME=d)

            class W:
                def nix(self, args):
                    return outer.run_nix(prod, args)

            pub = cp.Publisher({"eval_store": store}, W(), log=lambda *a: None)
            got = pub.drv_outputs(drv)
        self.assertTrue(drv.startswith("/nix/store/"), drv)
        self.assertEqual(len(got), 2, got)
        self.assertTrue(all(p.startswith("/nix/store/") for p in got), got)
        self.assertEqual(sorted(got), sorted(evaluated))

    def test_drv_outputs_skips_a_drv_that_was_never_instantiated(self):
        with tempfile.TemporaryDirectory() as d:
            store = os.path.join(d, "s")
            env = dict(os.environ, NIX_CONFIG=cp.NIX_CONFIG, HOME=d)
            outer = self

            class W:
                def nix(self, args):
                    try:
                        return outer.run_nix(env, args)
                    except AssertionError as e:
                        raise cp.nix_error(args, str(e))

            pub = cp.Publisher({"eval_store": store}, W(), log=lambda *a: None)
            with self.assertRaises((cp.Skip, cp.Retry)):
                pub.drv_outputs("/nix/store/" + "0" * 32 + "-never-made.drv")


if __name__ == "__main__":
    unittest.main()
