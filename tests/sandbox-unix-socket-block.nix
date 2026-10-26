# apply-seccomp is the whole mechanism behind srt's `allowAllUnixSockets =
# false`. nixpkgs' sandbox-runtime ships without it, and when it is absent srt
# emits one debug line and runs with no socket filter at all — a policy that
# claims to block sockets while blocking nothing. overlays/sandbox-runtime.nix
# builds the helper, but a green build cannot tell the two worlds apart: the
# package builds either way.
#
# So assert the behaviour. The probe opens an AF_UNIX socket, which must
# succeed unfiltered and fail under the helper. Both arms run, because an arm
# that fails for an unrelated reason (no python, no namespaces) would otherwise
# read as "blocked" and pass.
{ pkgs }:
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
pkgs.runCommand "sandbox-unix-socket-block"
{
  nativeBuildInputs = [ pkgs.python3 ];
} ''
  if [ ! -x ${applySeccomp} ]; then
    echo "apply-seccomp missing from the sandbox-runtime package." >&2
    echo "srt looks for it at exactly this path and silently runs without a" >&2
    echo "socket filter when it is not there. See overlays/sandbox-runtime.nix." >&2
    exit 1
  fi

  control=$(python3 ${probe})
  if [ "$control" != "allowed" ]; then
    echo "control arm did not open an AF_UNIX socket: $control" >&2
    echo "the filtered arm below proves nothing unless this one succeeds." >&2
    exit 1
  fi

  set +e
  filtered=$(${applySeccomp} python3 ${probe} 2>&1)
  rc=$?
  set -e
  case "$filtered" in
    blocked:*) ;;
    *)
      echo "AF_UNIX socket was NOT blocked under apply-seccomp (rc=$rc):" >&2
      echo "$filtered" >&2
      exit 1
      ;;
  esac

  echo "control: $control" > $out
  echo "filtered: $filtered" >> $out
''
