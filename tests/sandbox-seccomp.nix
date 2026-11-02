# vm-sandbox-seccomp: srt's Unix-socket filter is real, not declared.
#
# `allowAllUnixSockets = false` is implemented by one helper binary,
# `apply-seccomp`, and nixpkgs' sandbox-runtime ships without it. When it is
# missing srt emits a single debug-level line —
#
#   [Sandbox Linux] apply-seccomp binary not available - unix socket blocking
#   disabled.
#
# — and runs with no filter at all. That state held on this host for weeks:
# `ssh-add -l` listed the ED25519 key from inside the sandbox in both arms of a
# deny/allow probe, byte for byte identical. overlays/sandbox-runtime.nix fixes
# it by building the helper from the package's own vendored C source.
#
# A green build cannot detect a return to that state, because the package
# builds either way. So this lane asserts behaviour, in two halves that need
# each other:
#
#   FILTER  — apply-seccomp, run directly, really does deny socket(AF_UNIX).
#   WIRING  — srt resolves THAT binary and says it is applying the filter.
#
# The halves are separate because an earlier version of this lane only had the
# first, and the first alone cannot fail for the reason the lane exists. srt's
# own resolution is what broke: getApplySeccompBinaryPath() searches
# vendor/seccomp/<arch>/apply-seccomp relative to its dist/ directory and then
# a global npm install, and returns null — fails open, one debug line — when it
# finds nothing. Invoking the helper by its store path proves the binary works
# while saying nothing about whether srt can find it, which is the question.
#
# Why WIRING reads srt's debug log rather than running a probe through srt:
# end-to-end, srt enters a user namespace via bwrap and apply-seccomp then
# creates a NESTED one. This test VM refuses that nesting —
# `apply-seccomp: write /proc/self/uid_map: Operation not permitted` — where
# the host permits it, so a probe driven through srt in here fails for an
# environmental reason in every arm, including the one where blocking is
# switched off. That is the same "cannot tell protection from a sandbox that
# never started" ambiguity that already keeps this lane out of a runCommand.
# The debug lines are emitted during setup, before the workload runs, so they
# survive it; the arms below therefore assert on log content and deliberately
# do not assert the exit status. End-to-end composition is verified on the
# host instead, and recorded in the PR that introduced these arms.
#
# Why a VM rather than a runCommand at all: a GitHub Actions runner refuses
# even the un-nested namespace (`write /proc/self/setgroups ... caller must
# provide CAP_SYS_ADMIN`), so the FILTER half cannot run there.
#
# Run: nix build .#checks.x86_64-linux.vm-sandbox-seccomp -L
{ pkgs, inputs }:
let
  applySeccomp =
    "${pkgs.sandbox-runtime}/lib/node_modules/@anthropic-ai/sandbox-runtime"
    + "/vendor/seccomp/x64/apply-seccomp";

  # The same package WITHOUT overlays/sandbox-runtime.nix applied — i.e. the
  # exact state this host shipped in for weeks. It is the negative control for
  # the WIRING arm: without it, "srt found the helper" could be asserted
  # against a log line that srt prints no matter what, and nobody would know.
  unpatched = inputs.nixpkgs.legacyPackages.${pkgs.stdenv.hostPlatform.system}.sandbox-runtime;

  probe = pkgs.writeText "af-unix-probe.py" ''
    import socket
    import sys

    try:
        socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    except OSError as exc:
        print(f"blocked: {exc}")
        sys.exit(3)
    print("allowed")
  '';

  # Deny-all egress, one writable temp dir, blocking ON. Shared by both WIRING
  # arms so the only difference between them is which package's srt reads it.
  srtSettings = pkgs.writeText "srt-settings.json" (builtins.toJSON {
    filesystem = {
      denyRead = [ ];
      allowWrite = [ "/tmp" ];
      denyWrite = [ ];
    };
    network = {
      allowedDomains = [ ];
      deniedDomains = [ "*" ];
      allowAllUnixSockets = false;
    };
  });
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-sandbox-seccomp";
  extraModules = [
    {
      # bubblewrap and socat are srt's own runtime dependencies: it builds a
      # bwrap command line and proxies egress through socat. Without them srt
      # fails before it reaches the seccomp stage, and the WIRING arms would
      # report nothing rather than a resolution.
      environment.systemPackages = [
        pkgs.sandbox-runtime
        pkgs.python3
        pkgs.bubblewrap
        pkgs.socat
      ];
    }
  ];
  testScript = ''
    workstation.wait_for_unit("multi-user.target")

    # The helper has to be at exactly this path. srt probes it and nothing
    # else before falling back to a global npm install that does not exist
    # here, so a move is as good as a removal.
    workstation.succeed("test -x ${applySeccomp}")

    # --- FILTER: the helper's filter is real -----------------------------
    #
    # Control. Without it the filtered arm proves nothing: a probe that
    # cannot run at all also fails to open a socket.
    bare = workstation.succeed("${pkgs.python3}/bin/python3 ${probe}").strip()
    assert bare == "allowed", bare

    rc, out = workstation.execute(
        "${applySeccomp} ${pkgs.python3}/bin/python3 ${probe} 2>&1"
    )
    out = out.strip()
    # Distinguish the filter working from the sandbox failing to start. Only
    # the probe's own `blocked:` line means socket(AF_UNIX, ...) was denied;
    # anything else is apply-seccomp failing before the filter applied, and
    # that must fail the lane rather than read as protection.
    assert out.startswith("blocked:"), (rc, out)
    assert rc == 3, (rc, out)

    # --- WIRING: srt resolves that same helper ---------------------------
    #
    # Negative control FIRST, so a mistake that makes both arms vacuous shows
    # up here. Un-overlaid nixpkgs srt must report the fail-open state, in the
    # words the real incident was found by.
    _, unpatched_log = workstation.execute(
        "${unpatched}/bin/srt -d -s ${srtSettings} -c true 2>&1"
    )
    assert "apply-seccomp binary not found in any expected location" in unpatched_log, (
        "un-overlaid sandbox-runtime did NOT report a missing apply-seccomp, so "
        "the assertion below cannot distinguish a resolved helper from an "
        f"unresolved one:\n{unpatched_log}"
    )
    assert "unix socket blocking disabled" in unpatched_log, unpatched_log

    # The assertion. Overlaid srt must resolve the helper at the path the
    # overlay installs it to, and say it is applying the filter. An overlay
    # that stops producing the binary, or installs it a directory over, lands
    # back in the negative control's log above and fails here.
    _, log = workstation.execute(
        "${pkgs.sandbox-runtime}/bin/srt -d -s ${srtSettings} -c true 2>&1"
    )
    assert "Found apply-seccomp binary: ${applySeccomp}" in log, log
    assert "Applying seccomp filter for Unix socket blocking" in log, log
    assert "unix socket blocking disabled" not in log, log
  '';
}
