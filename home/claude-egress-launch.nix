# claude-egress-launch — the one way Claude Code gets launched into
# claude-egress.slice.
#
# Two call sites need identical launch behaviour:
#
#   1. home/claude-egress-slice.nix — the interactive zsh `_claude_slice`
#   2. home/vscodium.nix — `claudeCode.claudeProcessWrapper`, which the
#      extension spawns INSTEAD of the claude binary (verified in the
#      extension bundle: when that setting is set, resolveClaudeBinary()
#      returns it as `pathToClaudeCodeExecutable` with empty
#      `executableArgs`, so the wrapper must exec the real CLI itself)
#
# The GUI call site is the reason this file exists. The zsh function
# cannot cover it: a shell function is not inherited by a process the
# editor spawns, so before this wrapper every extension-launched session
# ran OUTSIDE the slice — unobserved by the nftables rule bound to that
# cgroup, and unconstrained by whatever phase 2 enforces on it. Two
# transcriptions of "the same" systemd-run invocation would drift, and
# the drift would be silent in exactly the direction that matters. So
# both sites call THIS script and neither one spells the logic out.
#
# Behaviour is carried over verbatim from the zsh function it replaces,
# including the parts that look redundant:
#
#   - `claude` is resolved from PATH AT RUN TIME, never pinned to a store
#     path: the native installer under ~/.local/bin self-updates, and
#     pinning would mean phase 1 observed a different build than phase 2
#     constrains. (No recursion: this script is not named `claude`.)
#   - observation degrades, the tool never fails to start. Every path
#     below still runs Claude Code and says so on stderr, because an
#     unobserved session that looks observed is the failure this design
#     exists to prevent.
#   - the no-op probe runs before the real invocation, because once
#     systemd-run owns the session there is no way back to a fallback.
#
# One deviation from the zsh original, stated rather than hidden:
# systemd is in `runtimeInputs`, so `command -v systemd-run` cannot fail
# here the way `whence -p systemd-run` could in a user's PATH. That
# branch is kept as a guard but is unreachable by design; the degrade
# path that actually fires is the missing user bus, which is the case a
# GUI-spawned process really hits (no session bus in the environment the
# editor hands down). Pinning the runner is deliberate: a security
# control should not depend on what PATH a desktop launcher inherited.
#
# `exec` is correct here and was forbidden in the zsh function: there it
# would have replaced the interactive login shell, so quitting Claude
# Code would close the terminal. This is a child process, so exec only
# saves a wasted shell in the middle of the tree.
{ pkgs }:
pkgs.writeShellApplication {
  name = "claude-egress-launch";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.systemd
  ];
  text = ''
    bin="$(command -v claude || true)"
    if [ -z "$bin" ]; then
      echo "claude-egress: no 'claude' binary on PATH" >&2
      exit 127
    fi

    runner="$(command -v systemd-run || true)"
    nop="$(command -v true || true)"
    export XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

    if [ -z "$runner" ] || [ ! -S "$XDG_RUNTIME_DIR/bus" ]; then
      echo "claude-egress: UNOBSERVED (no systemd-run, or no user bus at $XDG_RUNTIME_DIR/bus)" >&2
      exec "$bin" "$@"
    fi

    if [ -n "$nop" ] \
       && ! "$runner" --user --scope --quiet --slice=claude-egress.slice -- "$nop" >/dev/null 2>&1; then
      echo "claude-egress: UNOBSERVED (a scope in claude-egress.slice would not start)" >&2
      exec "$bin" "$@"
    fi

    exec "$runner" --user --scope --quiet --slice=claude-egress.slice -- "$bin" "$@"
  '';
}
