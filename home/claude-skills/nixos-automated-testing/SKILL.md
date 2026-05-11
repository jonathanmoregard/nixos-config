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

## Run the gate locally

From a worktree:

```bash
cd ~/Repos/nixos-config-worktrees/<your-branch>
nix build .#checks.x86_64-linux.dellan-vm -L
```

`-L` streams test-driver stdout. ~90 sec warm, ~3 min cold. Boots an
ephemeral QEMU VM, asserts HM activation, X session, kitty topology,
keyring PAM, etc. Pass → green. Fail → traceback in stdout.

CI runs the same gate on every PR (status check `vm-minimal (1..3)`),
so local invocation is for fast iteration before pushing.

## When to extend the test

| Change | Add to `tests/dellan-vm.nix` |
|--------|------------------------------|
| HM-installed binary on PATH | `dellan.succeed("test -x /etc/profiles/per-user/jonathan/bin/<name>")` |
| systemd user unit | `dellan.wait_for_unit("<name>", "jonathan")` |
| systemd system unit | `dellan.wait_for_unit("<name>")` |
| Script with deterministic behavior | `dellan.succeed("su jonathan -c '<cmd>'")` |
| New file rendered by HM | `dellan.succeed("test -f /home/jonathan/<path>")` |

## MANDATORY: positive-path assertion for any new behavior

Asserting only the no-op path (script exits 0 when its precondition is
missing) is a footgun. Both "broken socket / wrong path" and
"precondition genuinely missing" produce exit 0 — the test goes green
while the feature is silently dead.

For every new script / service / integration, add at least one
assertion that **forces the success path** and verifies the expected
side effect:

- Spawn the dependency (real X session via
  `services.xserver.displayManager.autoLogin = { enable = true; user = "<u>"; }`
  and `dellan.wait_for_x()`).
- Run the thing for real, not a mock.
- Assert the artifact materializes (`test -s <path>`) AND its content
  is structured as expected (`jq ...`, `grep -q ...`).

Example pattern:

```python
dellan.wait_for_x()
dellan.succeed(
    "su jonathan -c 'DISPLAY=:0 nohup kitty -1 --detach >/tmp/kitty-launch.log 2>&1' &"
)
dellan.wait_until_succeeds(
    "su jonathan -c 'sock=$(ls /tmp/kitty.sock-* 2>/dev/null | head -1); "
    "[ -n \"$sock\" ] && kitty @ --to unix:$sock ls >/dev/null'",
    timeout=30,
)
dellan.succeed("su jonathan -c kitty-session-save")
dellan.succeed("test -s /home/jonathan/.cache/kitty-session/snapshot.json")
```

If you cannot construct the success path in the VM (truly hardware-bound),
say so explicitly in the test comment and gate-skip the assertion — but
only after confirming the no-op path is not your only check.

## When to skip the gate

- Pure hardware-config edits (`hardware-configuration.nix`, real-disk
  LUKS, GPU drivers, touchpad firmware) — VM can't model them.
- Comment-only / formatting changes — eval check is enough:
  `nix eval .#checks.x86_64-linux.dellan-vm.drvPath`.

For everything else (HM packages, modules, services, scripts, secrets
wiring, overlays): run the gate.

## Iterating fast — cheap checks before the gate

Each VM-gate run costs ~90-180s. Burn fewer cycles by pruning errors at
cheaper layers first:

| Cost | Command | Catches |
|------|---------|---------|
| ~1s | `nix eval --no-warn-dirty .#checks.x86_64-linux.dellan-vm.drvPath` | Nix syntax + module type errors |
| ~5-30s | `nix build --no-link --print-out-paths .#nixosConfigurations.dellan.config.home-manager.users.jonathan.home.path` | Generated scripts compile (writeShellApplication shellcheck, writePython3Bin lint) |
| ~5s | Read `<home-path-out>/bin/<wrapper>` | Heredoc escaping, shebang at byte 0, paths interpolated correctly |
| ~90-180s | `nix build .#checks.x86_64-linux.dellan-vm -L` | Real boot, real X session, real systemd-user, real assertions |

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
