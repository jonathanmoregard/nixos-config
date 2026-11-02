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
# builds either way. So assert the behaviour: open an AF_UNIX socket with and
# without the helper, and require the first to succeed and the second to fail.
#
# Why a VM rather than a runCommand: apply-seccomp isolates its target in a
# nested user+PID+mount namespace before applying the filter, and a GitHub
# Actions runner refuses that (`write /proc/self/setgroups ... caller must
# provide CAP_SYS_ADMIN`). A cheap derivation lane therefore cannot distinguish
# "the filter blocked the socket" from "the sandbox never started", which is
# the exact ambiguity this test exists to remove.
#
# Run: nix build .#checks.x86_64-linux.vm-sandbox-seccomp -L
{ pkgs, inputs }:
let
  applySeccomp =
    "${pkgs.sandbox-runtime}/lib/node_modules/@anthropic-ai/sandbox-runtime"
    + "/vendor/seccomp/x64/apply-seccomp";

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
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-sandbox-seccomp";
  extraModules = [
    {
      environment.systemPackages = [ pkgs.sandbox-runtime pkgs.python3 ];
    }
  ];
  testScript = ''
    workstation.wait_for_unit("multi-user.target")

    # The helper has to be at exactly this path. srt probes it and nothing
    # else before falling back to a global npm install that does not exist
    # here, so a move is as good as a removal.
    workstation.succeed("test -x ${applySeccomp}")

    # Control. Without it the filtered arm proves nothing: a probe that
    # cannot run at all also fails to open a socket.
    control = workstation.succeed(
        "${pkgs.python3}/bin/python3 ${probe}"
    ).strip()
    assert control == "allowed", control

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
  '';
}
