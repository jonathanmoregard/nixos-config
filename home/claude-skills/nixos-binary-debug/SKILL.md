---
name: nixos-binary-debug
description: >
  Debug a patched compiled binary in a NixOS overlay (kitty/glfw,
  any nixpkgs derivation with overlay-applied patches). Use when a
  source patch is applied via overlay but the compiled binary
  doesn't behave as expected — verify the patch made it into the
  binary, then locate where the code path actually runs.
---

## When to invoke this skill

- You added a patch to a nixpkgs overlay (`overlays/<pkg>.nix`,
  `overlays/<pkg>/<patch>.patch`) and after `nixos-rebuild` /
  `nix build`, the runtime behaviour doesn't match the source.
- The same overlay built green in a previous PR but a new patch
  produces a binary that behaves like the unpatched version.
- A C-level diagnostic (`fprintf`, `printf`) in your patch should
  fire but you see nothing in the logs.
- A patched function still calls the unpatched path (suspect:
  symbol still resolving to old shared lib).

## Decision tree — which check first

```
Patched code doesn't behave →
  1. Is the source patched at all?                  ── strings <bin> | grep <unique-source-marker>
  2. Is the function compiled in?                   ── nm <bin> | grep <symbol>
  3. Is the function exported (for shared libs)?    ── nm -D <bin> | grep <symbol>
  4. Is the right shared lib loaded at runtime?     ── ldd <bin>  +  cat /proc/<pid>/maps
  5. Does the code path actually fire?              ── file-based debug logging (see below)
```

Each step rules out a specific class of "why didn't my patch take
effect" without burning hours on the wrong layer.

## Always wrap binary tools in `nix shell`

```bash
nix shell nixpkgs#binutils -c bash -c '
  nm /nix/store/...-kitty-0.46.2/lib/kitty/glfw-x11.so | grep _glfwPlatformInit
'
```

Host system's `nm` / `strings` / `ldd` may not match the libc
version that built the /nix/store binary. Use `nix shell nixpkgs#<tool>`
to pull a matching version. Tools commonly needed:

- `nixpkgs#binutils` — `nm`, `objdump`, `strings`, `readelf`
- `nixpkgs#patchelf` — `patchelf --print-needed`, `--print-rpath`
- `nixpkgs#strace` — runtime syscall trace
- `nixpkgs#file` — quick "what kind of file is this"

## Recipes

### Verify patch markers landed in the binary

If your patch added a unique string (e.g. `"scrolldbg"`, a marker
log line, or a renamed function), grep for it:

```bash
nix shell nixpkgs#binutils -c bash -c \
  'strings /nix/store/...-kitty-0.46.2/lib/kitty/glfw-x11.so | grep scrolldbg'
```

If `strings | grep` returns nothing, the patch didn't reach the
compiled output. Causes:
- `nixpkgs.overlays` not picked up because it's declared in a
  module (must be in `flake.nix`'s `pkgsLinux`/`pkgsDarwin`).
- Patch applied but compiler stripped the marker (release build
  + dead-code elimination — add `-O0` or move the marker into a
  function that's actually called).
- Wrong derivation rebuilt (overlay applied to a different
  attribute path than the one your config consumes).

### Verify a symbol is present + exported

```bash
nix shell nixpkgs#binutils -c bash -c '
  nm /nix/store/.../glfw-x11.so | grep -i my_patched_function
  echo "---"
  nm -D /nix/store/.../glfw-x11.so | grep -i my_patched_function
'
```

`nm` lists all symbols (including local/static); `nm -D` lists
only exported (dynamic) symbols. If the function appears in `nm`
but not `nm -D`, it's not callable across the .so boundary —
either mark it `extern` / strip `static`, or call it from inside
the same compilation unit.

### Verify the right .so is loaded at runtime

```bash
# At runtime, after kitty is launched in the VM:
ssh -p 2222 ... -i ~/.ssh/id_ed25519 jonathan@localhost \
  'pidof kitty | xargs -I{} cat /proc/{}/maps | grep glfw'
```

The expected line is something like:

```
7fXXX-7fYYY r-xp 0000000 ... /nix/store/<hash>-kitty-0.46.2/lib/kitty/glfw-x11.so
```

If the `<hash>` doesn't match your latest build's hash, the wrong
version is loaded. Causes:
- VM is using a stale system closure (rebuild + reboot the VM, not
  just `nix run` against the worktree).
- HM activation didn't relink because home generation hash didn't
  change (force with `home-manager switch` or a no-op edit).
- Dynamic loader resolved to a different path via `LD_LIBRARY_PATH`
  or rpath — check with `patchelf --print-rpath <kitty-bin>`.

### File-based debug logging from C inside the patched binary

**Do not use `fprintf(stderr, …)`** — see `nixos-automated-testing`
SKILL.md "Test-script gotchas" section for full rationale. Short
version: stderr is invisible in VM test harness output, and fflush
won't save you.

Pattern:

```c
// In the patched function
#include <stdio.h>
static void debug_log(const char *fmt, ...) {
    FILE *fd = fopen("/tmp/glfw-debug.log", "a");
    if (!fd) return;
    va_list ap;
    va_start(ap, fmt);
    vfprintf(fd, fmt, ap);
    va_end(ap);
    fclose(fd);
}

// At the trace point
debug_log("scrolldbg: phase=%d valuator=%d\n", phase, val);
```

Gate the calls behind an env var so prod builds don't write:

```c
if (!getenv("KITTY_DEBUG_SCROLL")) return;
debug_log(...);
```

Read from the test:

```python
machine.succeed("KITTY_DEBUG_SCROLL=1 kitty ...")
print(machine.succeed("cat /tmp/glfw-debug.log"))
```

### Multi-component bash-section pattern

When the question isn't "is the patch in?" but "is the whole chain
working?" (test → driver → app → lib → kernel), chain diagnostic
echoes in one bash call to make a single readable artefact:

```bash
echo "=== build hash ===" && \
ls -la result/lib/kitty/glfw-x11.so && \
echo "=== patched markers ===" && \
nix shell nixpkgs#binutils -c bash -c \
  'strings result/lib/kitty/glfw-x11.so | grep -E "scrolldbg|MOMENTUM"' && \
echo "=== runtime .so ===" && \
ssh -p 2222 ... 'pidof kitty | xargs -I{} cat /proc/{}/maps | grep glfw' && \
echo "=== runtime log ===" && \
ssh -p 2222 ... 'cat /tmp/glfw-debug.log 2>/dev/null | tail -50'
```

Section headers separate findings; one bash invocation = one tool
result to analyze.

### XI/XInput event inspection (X11 input bugs)

When debugging X11 input handling specifically (scroll, motion,
device routing), capture XI_Motion events with a side-channel
monitor process before triggering the input:

```bash
# In the VM, start a long-running XI monitor before kitty
systemd-run --user --unit=xi-monitor --working-directory=/tmp \
  /run/current-system/sw/bin/xi-scroll-monitor \
  > /tmp/xi-monitor.log 2>&1

# Then trigger input via xdotool / synthetic touchpad
xdotool ... # or send synthetic events

# Inspect
grep -nE "XI_Motion deviceid=|valuator|sourceid" /tmp/xi-monitor.log
xinput list-props <synthetic-touchpad-id>
```

Compare expected vs actual `deviceid` / `sourceid` flow to spot
classification or routing bugs. `xinput list-props` shows the
libinput properties the kernel/Xorg chain assigned, which is often
where "scroll detected as motion" or "wrong device class" bugs
hide.

## What this skill does NOT cover

- Booting / driving the feature-vm — that's `nixos-agent-testing`.
- Authoring the testScript or extending a `tests/<feature>.nix`
  lane — that's `nixos-automated-testing` (incl. the stderr-invisible
  callout in "Test-script gotchas").
- The push-gate checklist trailer — that's `nixos-config-dev`.
- General nixpkgs / overlay structure — read existing
  `overlays/<pkg>.nix` files in this repo for templates.

## Where this skill plugs into the pipeline

```
overlay patch edited
  │
  ├─ nix build .#... → produces /nix/store/<hash>-<pkg>
  │
  ├─ this skill: verify the patch reached the binary
  │     strings → nm → nm -D → ldd / /proc/<pid>/maps
  │
  ├─ nixos-agent-testing: boot feature-vm, drive runtime
  │     ssh + xdotool + xi-monitor + cat /tmp/<debug>.log
  │
  ├─ nixos-automated-testing: lane assertion captures the proof
  │
  ▼
commit + push (pre-push gate enforces Behavioural evidence claim)
```
