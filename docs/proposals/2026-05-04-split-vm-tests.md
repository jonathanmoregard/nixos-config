# Proposal: split monolithic dellan-vm.nix into per-feature checks

**Status:** implemented 2026-05-11 (different shape than proposed — see below)
**Date:** 2026-05-04
**Driven by:** autodoro test block fails after round-7 CI/CD modules land; one failing assertion blocks the entire VM gate, including unrelated CI/CD checks.

## Shipped shape (2026-05-11)

5 lanes, no aggregate, `vm-<feature>` naming (not `dellan-vm-*`):

- `vm-base` (`tests/base.nix`) — boot + HM activation
- `vm-desktop` (`tests/desktop.nix`) — Cinnamon screenshot/clipboard plumbing
- `vm-keyring` (`tests/keyring.nix`) — PAM gnome-keyring
- `vm-kitty` (`tests/kitty.nix`) — session save/restore
- `vm-claude-pane` (`tests/claude-pane.nix`) — Phase 6 hook + enricher

`tests/lib/common.nix` exports `mkTest { name; testScript }`. CI matrix in `.github/workflows/ci.yml` enumerates lanes; one job per lane (`vm-minimal (<lane>)`).

Differences from original proposal:
- No `dellan-vm` aggregate `symlinkJoin` — CI matrix supersedes it; one less indirection.
- Dropped `dellan-` prefix from lane names — every check is x86_64-linux and dellan-derived; the prefix was redundant.
- No `autodoro.nix` lane (test block was deleted from the monolith pre-split; restore in a follow-up PR).
- No `cicd.nix` lane (webhook/auto-deploy logic has no e2e assertion; add when it does).
- Path-filter (`dorny/paths-filter`) deferred — every lane runs every PR for now; filter when wall-clock becomes a problem.

Original 2026-05-04 plan preserved below for context.

## Goal

Replace the single `tests/dellan-vm.nix` (currently 580 lines, multiple unrelated assertions) with one check derivation per feature area. Failure isolation, parallelism, faster path-filtered CI runs.

## Layout

```
tests/
  lib/common.nix              # shared scaffolding: hosts/dellan import, autoLogin, linger, virtualisation
  base.nix                    # boots, multi-user.target, HM activation, default.target for jonathan
  autodoro.nix                # autodoro launcher + GTK/GdkPixbuf runtime env
  kitty.nix                   # kitty session-save, 4-pane grid, restore cycle
  keyring.nix                 # gnome-keyring PAM wiring
  cicd.nix                    # webhook listening + nixos-deploy unit declared (post-2026-05-05: atticd + actions-runner removed; runner moved to GHA-hosted)
```

## flake.nix change

```nix
checks.x86_64-linux = let
  mkTest = path: pkgsLinux.callPackage path { inherit inputs; };
in {
  dellan-vm-base     = mkTest ./tests/base.nix;
  dellan-vm-autodoro = mkTest ./tests/autodoro.nix;
  dellan-vm-kitty    = mkTest ./tests/kitty.nix;
  dellan-vm-keyring  = mkTest ./tests/keyring.nix;
  dellan-vm-cicd     = mkTest ./tests/cicd.nix;
  # Aggregate: all tests succeed → top-level dellan-vm check passes
  dellan-vm = pkgsLinux.symlinkJoin {
    name = "dellan-vm-all";
    paths = with config.checks.x86_64-linux; [
      dellan-vm-base
      dellan-vm-autodoro
      dellan-vm-kitty
      dellan-vm-keyring
      dellan-vm-cicd
    ];
  };
};
```

(Aggregate keeps the existing `nix build .#checks.x86_64-linux.dellan-vm` invocation working — it now succeeds iff all sub-tests pass.)

## ci.yml change

Matrix fan-out so each lane runs one check independently:

```yaml
vm-tests:
  runs-on: ubuntu-latest
  strategy:
    fail-fast: false
    max-parallel: 3
    matrix:
      check: [base, autodoro, kitty, keyring, cicd]
  steps:
    - uses: actions/checkout@v4
    - run: nix build --no-link --print-build-logs .#checks.x86_64-linux.dellan-vm-${{ matrix.check }}
```

## Path-filtering

Run only relevant checks per PR:
- `home/autodoro.nix` change → only `dellan-vm-autodoro`
- `home/kitty.nix` → only `dellan-vm-kitty`
- `modules/nixos/{github-webhook,nixos-deploy,…}.nix` → only `dellan-vm-cicd`
- `home/cinnamon.nix` → only `dellan-vm-base` (or new `dellan-vm-graphical`)
- Touch any module imported by host: run all (fall-through)

Implement via `dorny/paths-filter@v3` action; emit a list output that the matrix consumes.

## Tradeoffs

**Pros:**
- One failure doesn't block unrelated tests
- Parallel lanes naturally map to parallel checks (3 lanes = 3 tests in flight)
- Path-filtered runs faster (touching kitty doesn't run autodoro test)
- Clearer "what does this test cover" per file
- `nix flake check` reports per-test status separately

**Cons:**
- Each test reboots VM (~30s overhead each → 5 tests = +2min wall vs 1 monolith). Mitigated by parallelism.
- More files to maintain (~6 vs 1)
- Shared scaffolding (`tests/lib/common.nix`) needs export discipline

## Effort

| Step | Time |
|---|---|
| Extract `tests/lib/common.nix` | 15min |
| Split current `dellan-vm.nix` into 5 per-feature files | 30min |
| Update `flake.nix` `checks` block + aggregate | 5min |
| Update `ci.yml` matrix + paths filter | 15min |
| Update `nixos-vm-test-gate` skill + `install.sh` | 10min |

**Total: ~1.25h.**

## Out of scope

- VM-graphical / VM-realapp tiers (E.1, E.2 in main spec) — those fold in naturally as new files later
- Splitting `kitty.nix` further (save vs restore vs grid) — premature; one file is fine
- Migrating to `flake-parts` — orthogonal, larger refactor

## Implementation order

1. Land aggregate-stub in `flake.nix` (current monolith stays as `dellan-vm-base`, others empty placeholders) — no functional change
2. Move autodoro block into `tests/autodoro.nix`, leave commented in `base.nix` — verify autodoro test runs in isolation, confirm the failure mode (unblocks debugging)
3. Move kitty block into `tests/kitty.nix`
4. Move keyring + new cicd into respective files
5. Add `paths-filter` to `ci.yml`
6. Drop the aggregate stub from `flake.nix` once matrix is producing per-check status reports

Each step is independently mergeable; can be done over time without big-bang risk.
