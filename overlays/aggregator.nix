# aggregator: the personal search index behind `aggregator_search_memory`,
# packaged as a real store path so `aggregator-ingest.service` stops running
# the developer's working tree.
#
# ── The defect this closes ──
#
# Until now the ingest unit's ExecStart pointed at a store path whose last
# line was:
#
#     exec uv run --directory /home/jonathan/Repos/aggregator aggregator ingest --all
#
# The store path was therefore a decoy. What actually ran was whatever was
# checked out in ~/Repos/aggregator at the moment the timer fired — any
# branch, any uncommitted edit, any half-finished experiment. On 2026-08-16
# the tree sat on a feature branch while the timer was live. Worse, `uv run`
# WRITES to that tree from a systemd unit (resolves and syncs `.venv`, and
# can rewrite `uv.lock`), so an unattended background job was mutating a
# directory a human was editing. "Merged to main" and "what runs" were
# unrelated facts.
#
# ── Why uv2nix and not buildPythonApplication ──
#
# `presidio-analyzer` and `presidio-anonymizer` are not in nixpkgs (checked
# 2026-08-16), so a nixpkgs-deps build would need two hand-written
# derivations plus their transitive fixups. That is the smaller problem.
# The bigger one is drift: with a hand-listed dependency set, a dependency
# ADDED upstream in the aggregator's pyproject.toml still builds fine here
# and then fails at runtime with an ImportError on the next timer tick.
# uv2nix derives the whole set from the repo's own `uv.lock`, so upstream's
# dependency changes arrive automatically with the source bump and the
# packaged environment is bit-for-bit the one the tests ran against.
# Session constraint 2026-08-11 — low upkeep, low manual work, robust —
# points the same way, and flake.nix already names uv2nix as the house
# pattern for personal Python CLIs (tts-tool, substack-url-tool,
# prose-decorate each ship their own uv2nix flake).
#
# ── Why the build lives HERE and not in the aggregator's own flake ──
#
# The aggregator repo does have a flake, but its `packages.default` is a
# stub: `buildPythonApplication` with `propagatedBuildInputs = []` and a
# comment saying fastmcp/presidio "may need overlays". It builds and
# produces a binary that cannot import anything. Fixing that belongs
# upstream; this change is explicitly scoped to nixos-config. When upstream
# grows a working uv2nix flake, delete this file and consume
# `aggregator.packages.${system}.default` the way listen-tools consumes
# tts-tool.
#
# ── sourcePreference = "wheel" ──
#
# Every one of the 119 locked packages publishes a wheel, so nothing has to
# be compiled here and the manylinux binaries (numpy, spacy, thinc,
# cryptography, pydantic-core) are autopatchelf'd by pyproject-nix's build
# hooks. Building from sdist instead would drag in a C/C++ toolchain and a
# BLAS for numpy for no behavioural gain.
#
# ── python311 ──
#
# Pinned to the repo's `.python-version` (3.11), which is also what
# `uv run` used, so the interpreter under the packaged code is the one the
# aggregator's own test suite exercises. nixpkgs' default `python3` is 3.14
# here; the lock resolves differently on that side of its
# `python_full_version >= '3.14'` marker.
#
# ── en_core_web_lg: production must keep the FULL Presidio path ──
#
# aggregator/core/scrub.py runs Presidio for entity-based PII detection
# ONLY when the spaCy model Presidio is configured for is installed, and
# degrades to regex-only with a logged warning otherwise. That degradation
# is silent in every way that matters: the run still exits 0, the row still
# gets stamped with SCRUB_FINGERPRINT = "presidio+gitleaks/v1", and nothing
# re-scrubs it later. Shipping the regex path would therefore quietly lower
# the PII floor on an index built from the user's entire history.
#
# Production today takes the FULL path — dellan's journal for
# aggregator-ingest.service contains zero "Presidio unavailable" lines,
# because the dev tree's .venv has en_core_web_lg installed out of band via
# `python -m spacy download`. Reproducing that in the store is not optional;
# it is preserving current behaviour.
#
# The model is NOT on PyPI and therefore not in uv.lock — spaCy publishes
# its models as GitHub release wheels. So it is fetched by URL, pinned by
# version + SRI hash, unpacked into a site-packages tree, and put on the
# venv's PYTHONPATH by the wrapper. PYTHONPATH rather than injecting a
# member into the uv2nix package set on purpose: the model is pure data
# with one entry-point file, and `spacy.util.get_installed_models()`
# resolves it through `importlib.metadata` entry points, which scan
# sys.path. That keeps this file independent of pyproject-nix's internal
# package-set contract, which is the part of the stack most likely to
# change under us.
#
# Cost: the unpacked model is ~445 MiB, which lands in dellan's system
# closure and in CI's store snapshot. It also exceeds the cachix
# post-build-hook's 256 MiB push budget (see tests/cachix-push-filter.nix),
# so it is fetched from GitHub rather than substituted on a cold builder.
#
# ── Bumping the aggregator ──
#
#   # in a nixos-config worktree: edit the rev in flake.nix's
#   # `aggregator-src.url`, then
#   nix flake lock
#   git add -A && git commit && open a PR
#
# NOT `nix flake update aggregator-src`. That instruction stood here and was
# wrong: the input is fully pinned (`github:owner/repo/<rev>`), so
# re-resolving it yields the same rev and the same narHash and the command
# exits 0 having changed nothing — a bump that looks like it ran and did not.
# flake.nix carries the same warning at the input; keep the two in step.
#
# The rev in flake.lock is the deployed version, full stop, and it is also
# the SCHEMA VERSION the ingest timer stamps on cache.db — see the note at
# `aggregator-src` in flake.nix for why a lagging rev kills recall silently.
# Nothing else needs editing unless the aggregator changes its Python
# version.
{ pyproject-nix, uv2nix, pyproject-build-systems, src }:
final: prev:
let
  inherit (prev) lib;
  python = prev.python311;

  workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = src; };

  pythonSet =
    (prev.callPackage pyproject-nix.build.packages { inherit python; })
      .overrideScope (lib.composeManyExtensions [
        pyproject-build-systems.overlays.default
        (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
      ]);

  venv = pythonSet.mkVirtualEnv "aggregator-env" workspace.deps.default;

  # spaCy's large English model. Version tracks the one the dev venv has
  # installed (3.8.0) and must stay inside spacy's own `>=3.8.0,<3.9.0`
  # range — bump both together or Presidio silently falls back.
  spacyModel = prev.stdenvNoCC.mkDerivation rec {
    pname = "en_core_web_lg";
    version = "3.8.0";

    src = prev.fetchurl {
      url = "https://github.com/explosion/spacy-models/releases/download/${pname}-${version}/${pname}-${version}-py3-none-any.whl";
      hash = "sha256-KT6VR6ZVslSZGYqxWlJbBblAenXxAlXkBejDhUMpq2M="; # pragma: allowlist secret
    };

    nativeBuildInputs = [ prev.unzip ];
    dontConfigure = true;
    dontBuild = true;

    unpackPhase = ''
      runHook preUnpack
      mkdir -p wheel
      unzip -q "$src" -d wheel
      runHook postUnpack
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/${python.sitePackages}"
      cp -r wheel/. "$out/${python.sitePackages}/"
      # Fail the BUILD, not the next ingest run, if the wheel layout ever
      # changes. entry_points.txt is the file catalogue reads to register
      # the model, so its absence is exactly the shape that would put
      # production back on the regex path without anything going red.
      test -d "$out/${python.sitePackages}/${pname}"
      test -f "$out/${python.sitePackages}/${pname}-${version}.dist-info/entry_points.txt"
      runHook postInstall
    '';

    meta = with lib; {
      description = "spaCy large English pipeline, required by presidio-analyzer";
      homepage = "https://github.com/explosion/spacy-models";
      license = licenses.mit;
      platforms = platforms.all;
    };
  };
in
{
  aggregator = prev.runCommand "aggregator-0.0.1"
    {
      nativeBuildInputs = [ prev.makeWrapper ];
      passthru = { inherit venv spacyModel python; };
      meta = with lib; {
        description = "Personal aggregator: local full-text index over the user's own history";
        mainProgram = "aggregator";
        platforms = platforms.linux;
      };
    } ''
    mkdir -p "$out/bin"
    for prog in aggregator aggregator-mcp; do
      makeWrapper "${venv}/bin/$prog" "$out/bin/$prog" \
        --prefix PYTHONPATH : "${spacyModel}/${python.sitePackages}"
    done
  '';
}
