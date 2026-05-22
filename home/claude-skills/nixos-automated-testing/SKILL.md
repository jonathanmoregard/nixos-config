---
name: nixos-automated-testing
description: >
  NixOS automated testing. Use when writing, extending, or running
  automated tests for the nixos-config repo
  (~/Repos/nixos-config-worktrees/). Pair with `nixos-agent-testing`
  for complex changes (branching, GUI, daemons).
---

## Scope

This is the **assertion-driven** gate: `nixosTest`-based, headless,
script-driven, the same derivation CI builds. It proves things like
"the unit reaches active", "the binary is on PATH", "the script's
output matches this jq pattern". Pass → green. Fail → traceback.

For **interactive smoke-testing** (boot a real feature VM, drive it
via SSH/QMP/screencap, click on the actual login screen, watch a
service start in real time), use the `nixos-agent-testing` skill
instead. The two are complementary — this skill runs every PR; the
interactive VM is what you reach for when logic in a change needs
human-style verification before merge (any branching code or
multistep script).

## Lanes

One check derivation per feature area. Pick the lane your change
touches. Adding a lane is cheap (~30 lines + flake.nix wire-up); a
mixing-pot lane defeats the failure-isolation goal.

| Lane | Source | Covers |
|---|---|---|
| `vm-base` | `tests/base.nix` | boot + HM activation + systemd-user default.target |
| `vm-desktop` | `tests/desktop.nix` | CopyQ + gnome-screenshot + Cinnamon Print/Shift+Print dconf bindings |
| `vm-keyring` | `tests/keyring.nix` | gnome-keyring PAM wiring on `/etc/pam.d/login` |
| `vm-kitty` | `tests/kitty.nix` | kitty session save → kill → restore (4-pane 2x2 grid) |
| `vm-claude-pane` | `tests/claude-pane.nix` | Claude SessionStart hook + enricher → unique `claude_session_id` per pane |

Shared node config lives in `tests/lib/common.nix` — imports
`hosts/dellan/default.nix`, sets autoLogin/linger/virtualisation,
and exports `mkTest { name, testScript }`. Each lane is ~20 lines of
boilerplate + its own testScript.

## Run the gate locally

From a worktree:

```bash
cd ~/Repos/nixos-config-worktrees/<your-branch>

# Single lane (fastest feedback loop while iterating):
nix build .#checks.x86_64-linux.vm-base -L
nix build .#checks.x86_64-linux.vm-kitty -L

# All lanes (= what CI runs across its matrix):
nix flake check -L
```

`-L` streams test-driver stdout. Per-lane boot ~30s; whole VM run
~90s warm / ~3min cold. Lanes share the same node closure so the
first lane warms the cache for the rest. Pass → green. Fail →
traceback in stdout.

CI runs each lane as its own matrix job (`vm-minimal (<lane>)`); a
broken `kitty` lane doesn't block `keyring` reporting status.
`fail-fast: false` keeps every lane reporting even after one breaks.

## When to extend a test (and which one)

Pick the lane closest to what you changed. If your change touches
something new with no obvious home, add a new lane file rather than
piling onto `vm-base`.

**Prefer behavioural assertions over presence ones.** A presence check
(`test -x <bin>`, `test -f <path>`, "config file contains string") proves
nothing about runtime — render-grep / presence-only tests are how PR #57
passed CI while the keybinding was broken at runtime (`pass_selection_to_program`
runs the child without a controlling tty, so the bound `kitten clipboard`
silently failed). The rows below show presence as the minimum bar; the
right-hand column upgrades each to behavioural.

| Change | Presence (minimum) | Behavioural (preferred) |
|--------|------|-----------------|
| HM-installed binary on PATH | `test -x /etc/profiles/per-user/jonathan/bin/<name>` | `su jonathan -c '<name> --help' \| grep <expected-flag>` |
| systemd user unit | `wait_for_unit("<name>", "jonathan")` | trigger the unit's job + assert the side effect (timer fires → check artifact; daemon listens → curl it) |
| systemd system unit | `wait_for_unit("<name>")` | same — exercise the unit's actual job, not just liveness |
| Script with deterministic behavior | `su jonathan -c '<cmd>'` | run with the inputs a user would, assert exit code AND stdout shape |
| New file rendered by HM | `test -f /home/jonathan/<path>` | for a config file, prefer testing that the **app reading it does the right thing** — render-grep is the PR #57 anti-pattern |
| Whole new feature area | new `tests/<feature>.nix` + wire into `flake.nix` `checks` block + add to `ci.yml` matrix | use one of the small lanes (keyring/base) as a template |

## When to skip the gate

- Pure hardware-config edits (`hardware-configuration.nix`, real-disk
  LUKS, GPU drivers, touchpad firmware) — VM can't model them.
- Comment-only / formatting changes — eval check is enough:
  `nix eval .#checks.x86_64-linux.vm-base.drvPath`.

For everything else (HM packages, modules, services, scripts, secrets
wiring, overlays): run the gate.

## Iterating fast — cheap checks before the gate

Each lane costs ~90-180s. Burn fewer cycles by pruning errors at
cheaper layers first:

| Cost | Command | Catches |
|------|---------|---------|
| ~1s | `nix eval --no-warn-dirty .#checks.x86_64-linux.vm-base.drvPath` | Nix syntax + module type errors (any lane works; pick one that builds fast) |
| ~5-30s | `nix build --no-link --print-out-paths .#nixosConfigurations.dellan.config.home-manager.users.jonathan.home.path` | Generated scripts compile (writeShellApplication shellcheck, writePython3Bin lint) |
| ~5s | Read `<home-path-out>/bin/<wrapper>` | Heredoc escaping, shebang at byte 0, paths interpolated correctly |
| ~90-180s | `nix build .#checks.x86_64-linux.vm-<feature> -L` | Real boot, real X session, real systemd-user, real assertions for that lane |

Always run the first three before queuing a VM. They catch ~80% of
mistakes in seconds.

## Diagnostic dumps in testScript

`print(...)` in the Python `testScript` writes to the test driver's
stdout, which is captured in the build log. Use this to inspect VM state
when an assertion fails:

```python
dellan.succeed(f"su jonathan -c '... ls > /tmp/state.json'")
print("[diag] state:\n" + dellan.succeed("cat /tmp/state.json"))
dellan.succeed("jq -e '...' /tmp/state.json")  # the actual assertion
```

Always dump first, assert second — once the assertion fails the cleanup
phase tears down the VM and you've lost the chance to introspect.

## Test-script gotchas

- **Don't name a node `nodes.machine`** — the framework auto-injects a
  `machine` symbol for single-node tests, and `nodes.machine` collides
  with mypy error `Name "machine" already defined`. Use
  `nodes.<your-host-name>` instead.
- **`pgrep -x kitty` (or any program-name pgrep) self-matches a wrapper
  script** because the kernel sets `comm` from argv[0]. Detect runtime
  presence via socket / pidfile / lockfile, not process-name pgrep.
- **Short-lived commands close the window/tab they spawned** — kitty
  closes a window when its foreground process exits. Use
  `sleep infinity` or a long-running placeholder when setting up test
  topology.
- **Glob patterns inside `su -c '...'` can be eaten by the outer
  shell** — `echo []` may glob-expand to nothing; use
  `printf '%s' '[]'` instead.
- **`nixpkgs.config` and `nixpkgs.overlays` become read-only** when the
  test framework injects pkgs externally. Keep them in `flake.nix`'s
  `pkgsLinux`/`pkgsDarwin` definitions, never in modules.

## Failure modes

- `Path '<file>' in the repository "/etc/nixos" is not tracked by Git`
  → forgot `git add -A`.
- `nixpkgs.config' is defined multiple times` / `set to read-only` →
  overlay or config in a module instead of flake.nix. Move it.
- VM boot timeout on `multi-user.target` → likely activation script
  failure. Check the test driver log for the failed unit.
- `Name "machine" already defined` (mypy error) → don't name a node
  `machine`; framework reserves it. Use `dellan` or any other name.

## What the gate cannot catch

The test exercises systemd activation + binary presence + script
logic — NOT live UI, not branching that the script-driven assertions
don't traverse, not anything requiring real human interaction. Out
of scope:

- Cinnamon applet rendering bugs
- HM `home.activation` scripts that write to live `~/.config` and
  clobber existing real files (test starts with a clean home)
- Behavior that requires a real graphical session (kitty actually
  rendering, X clients connecting, GPU acceleration)
- Logic branches the test doesn't construct inputs for

For those use the **`nixos-agent-testing`** skill — interactive
feature VM with SSH/QMP/screencap/sendkey, exact same dellan
configuration, lets you drive the real code paths and capture
proof. The two skills are intentional complements: this one is the
automated assertion gate every PR runs; agent-testing is the
human-style verification you reach for when assertions alone can't
prove the change.
