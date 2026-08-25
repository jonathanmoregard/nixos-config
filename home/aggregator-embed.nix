# The aggregator's background embed worker — the thing that actually fills
# the v5 sqlite-vec index.
#
# WHY THIS FILE IMPORTS UPSTREAM INSTEAD OF DECLARING UNITS HERE. Every other
# aggregator wiring in this repo is local: modules/nixos/aggregator-ingest-timer.nix
# deliberately does NOT use `services.aggregator.enable`, because that module
# still wires one ingest unit per source and the unified `ingest --all` runner
# replaced them. The embed units are the opposite case. They live in the
# aggregator's own tree, and that tree carries a flake check —
# `checks.<system>.aggregator-embed-unit-hygiene` — which asserts properties
# of the rendered unit files: that the seed unit runs `embed --seed-models`
# (the only entry point constructing BOTH the Embedder and the Reranker), that
# it names the same model repo the Python default resolves to, and that the
# sandbox directives survive. Vendoring a copy here would leave that check
# guarding a file nobody runs, which is precisely the failure the ingest
# module's own header describes: "merged to main" and "what runs" becoming
# unrelated facts.
#
# So: import the upstream module, take the embed half, and switch the two
# per-source ingest timers OFF because this host's ingest is the all-sources
# timer instead. `services.aggregator.enable` gates the module as a whole and
# each piece has its own `enable`, which is what makes that split possible
# without patching upstream.
#
# WHAT THIS COSTS. `sentence-transformers` is a main dependency of the
# aggregator, so pinning the RAG rev pulls torch into the system closure —
# a multi-GB jump, and it lands in every VM test node that builds the
# aggregator package too. There is no smaller way to embed locally; the
# alternative is no vector arm at all.
#
# WHAT IT DOES NOT DO. Installing the timer does not download any weights.
# The worker runs with `HF_HUB_OFFLINE=1` and fails loudly if the models are
# absent; `aggregator-embed-seed.service` is the only path that fetches them
# (~2.4 GB, `HF_HUB_OFFLINE=0`), it is human-triggered, and it has no
# `Install.WantedBy` on purpose. Start it by hand once:
#
#   systemctl --user start aggregator-embed-seed
#
# BACKFILL SHAPE, so the timer's behaviour is not mistaken for a stall. The
# worker walks sources in a fixed priority order — dropbox, substack,
# claude-web, chatgpt, sessions, subagents, then everything unranked — and
# finishes each before starting the next, so `aggregator status` answers
# "which sources are searchable today" rather than one percentage for the
# whole corpus. Measured on the real cache at 40 tok/s: dropbox ~1.1 days,
# dropbox + substack + claude-web ~4 days, the whole corpus ~54.8 days, of
# which 91% is sessions + subagents. A tick that reports progress and does
# not finish is the normal case for weeks.
#
# `aggregator-src` IS REQUIRED, AND A NIX DEFAULT CANNOT SOFTEN THAT. This
# module uses the argument inside `imports`, and the module system resolves an
# argument it was not handed by looking in `_module.args` — which needs
# `config`, which needs `imports`.
#
# A `? throw (...)` default does NOT stop that lookup. `lib.modules` supplies
# every declared argument via `args.<name>` or `config._module.args.<name>`,
# so the default is shadowed and never reached. An earlier revision of this
# file carried one and its header claimed a mis-wired site would fail with a
# named sentence. It would not, so the default is gone rather than left here
# to be trusted — a dead safety mechanism is worse than none, because the next
# person reads the comment instead of the trace.
#
# What a mis-wired site ACTUALLY gets, reproduced against `lib.evalModules`
# with this module's exact shape (defaulted arg, forced while `imports` is
# being evaluated):
#
#   … while evaluating the module argument `aggregator-src' in "…":
#   … noting that argument `aggregator-src` is not externally provided, so
#     querying `_module.args` instead, requiring `config`
#   error: infinite recursion encountered
#
# Nix names the argument itself, which is the half that matters. The fix is
# always the same: add `extraSpecialArgs = { inherit aggregator-src; };` to the
# home-manager block that built the failing configuration. Every site that
# constructs one must pass it — both host blocks in flake.nix, both builders in
# tests/lib/common.nix, and tests/microvm.nix, which rolls its own.
{ pkgs, aggregator-src, ... }:

{
  imports = [ "${aggregator-src}/nix/aggregator.nix" ];

  services.aggregator = {
    enable = true;

    # The same `pkgs.aggregator` the ingest timer execs, built by
    # overlays/aggregator.nix from the `aggregator-src` rev in flake.lock.
    # Naming the package rather than a path under /home is load-bearing —
    # tests/base.nix asserts mechanically that no aggregator unit runs code
    # out of a checkout.
    package = pkgs.aggregator;

    # OFF, and not because they are broken. modules/nixos/aggregator-ingest-timer.nix
    # runs `ingest --all` across all nine sources on one timer; these two
    # would be a second and third writer against the same cache.db doing a
    # subset of the same work.
    sources.sessions.enable = false;
    sources.github.enable = false;

    embed.enable = true;
  };
}
