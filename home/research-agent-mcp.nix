{ pkgs, ... }:
# research-agent-mcp wrapper.
#
# Claude Code spawns `research-agent-mcp` as a stdio MCP subprocess
# (configured in ~/.claude.json). The MCP server has two key dependencies
# at startup:
#
#  1. The injection-scanner L3 honeypot calls Anthropic + OpenAI on every
#     scan. Without ANTHROPIC_API_KEY / OPENAI_API_KEY in the spawn env,
#     smoke fails closed and the server exits before binding stdio.
#  2. The research agent itself (inside the dev container) needs EXA +
#     TAVILY for search providers and a Claude Code OAuth token to drive
#     the headless `claude` CLI. Without these, `research()` calls fail
#     at the first tool invocation with `<provider>-api-key not in keyring`.
#
# The MCP server's secret loader prefers env vars before falling back to
# the GNOME keyring (see `_SECRET_ENV` in mcp_server/server.py). On NixOS
# the keyring isn't the source of truth — agenix is — so we always
# populate via env to keep behaviour fully declarative.
#
# Claude Code's `env` block in ~/.claude.json takes literal values, not
# file paths. The shell wrapper deliberately never reads the secrets: it
# starts uv with only non-secret configuration, and uv starts a generated
# Python bootstrap. The bootstrap first makes the final Python process
# non-dumpable, then reads the agenix files and runs the server module in
# process. This ordering keeps the twelve values out of the shell and uv
# environments and blocks same-UID reads through /proc before a value is
# present in memory. The bootstrap also strips them from Python subprocess
# environments, because execve would otherwise reset dumpability in each
# child and recreate the leak there.
#
# Post-microvm migration: the SSH transport reads `RESEARCH_SSH_KEY`
# (default: agenix-decrypted host-to-VM private key path). The MCP
# server's `_ssh_settings()` reads it lazily at call time so we just
# export it here.
#
# Wrapper name `research-agent-mcp` matches the ~/.claude.json command
# string so the config doesn't need to change. The wrapped binary lives
# inside the project venv at a different absolute path, so no PATH loop.
let
  # Lakera Guard tuned-policy pointer, single-sourced in home/lakera.nix.
  lakera = import ./lakera.nix;
  # Model Armor endpoint ids, single-sourced in home/model-armor.nix.
  modelArmor = import ./model-armor.nix;

  # Raw-value agenix files: each contains only the value, with no `NAME=`
  # prefix. Keep the environment-name -> decrypt-path relationship here so
  # the generated bootstrap and wrapper cannot drift apart.
  secretPaths = {
    ANTHROPIC_API_KEY = "/run/agenix/anthropic-api-key";
    OPENAI_API_KEY = "/run/agenix/openai-api-key";
    # injection-scanner L2 (Lakera Guard) is fail-closed — without this the
    # scanner rejects every report. This must be a real key.
    LAKERA_API_KEY = "/run/agenix/lakera-api-key";
    EXA_API_KEY = "/run/agenix/exa-api-key";
    TAVILY_API_KEY = "/run/agenix/tavily-api-key";
    CLAUDE_CODE_OAUTH_TOKEN = "/run/agenix/claude-token";

    # EUIPO OAuth2 client_credentials for the trademark_shim. Both files
    # start empty until the developer-portal subscription is approved. The
    # shim treats an empty value as unset and errors only when called, so an
    # empty but readable file is valid configuration.
    EUIPO_CLIENT_ID = "/run/agenix/euipo-client-id";
    EUIPO_CLIENT_SECRET = "/run/agenix/euipo-client-secret";

    # eBay + Tradera use the same placeholder model: empty until developer
    # keys are filled in, with an empty value meaning "not configured".
    EBAY_CLIENT_ID = "/run/agenix/ebay-client-id";
    EBAY_CLIENT_SECRET = "/run/agenix/ebay-client-secret";
    TRADERA_APP_ID = "/run/agenix/tradera-app-id";
    TRADERA_APP_KEY = "/run/agenix/tradera-app-key";
  };

  researchAgentMcpBootstrap = pkgs.writeText "research-agent-mcp-bootstrap.py" ''
    import ctypes
    import os
    from pathlib import Path
    import runpy
    import subprocess
    import sys

    PR_GET_DUMPABLE = 3
    PR_SET_DUMPABLE = 4

    libc = ctypes.CDLL(None, use_errno=True)
    libc.prctl.argtypes = [
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    libc.prctl.restype = ctypes.c_int


    def prctl(option: int, value: int, label: str) -> int:
        result = libc.prctl(option, value, 0, 0, 0)
        if result == -1:
            error = ctypes.get_errno()
            print(
                f"research-agent-mcp: prctl({label}) failed: "
                f"[Errno {error}] {os.strerror(error)}",
                file=sys.stderr,
            )
            raise SystemExit(1)
        return result


    # Same-UID processes may normally read /proc/<pid>/environ. Disable that
    # access before loading any secret. This must happen in the final Python
    # process because execve resets PR_SET_DUMPABLE to 1 for a normal binary.
    set_result = prctl(PR_SET_DUMPABLE, 0, "PR_SET_DUMPABLE")
    if set_result != 0:
        print(
            "research-agent-mcp: prctl(PR_SET_DUMPABLE) returned "
            f"unexpected result {set_result}",
            file=sys.stderr,
        )
        raise SystemExit(1)

    dumpable = prctl(PR_GET_DUMPABLE, 0, "PR_GET_DUMPABLE")
    if dumpable != 0:
        print(
            "research-agent-mcp: PR_SET_DUMPABLE verification failed: "
            f"PR_GET_DUMPABLE returned {dumpable}, expected 0",
            file=sys.stderr,
        )
        raise SystemExit(1)

    secret_paths = ${builtins.toJSON secretPaths}
    secrets = {}
    for name, path in secret_paths.items():
        try:
            # Command substitution removed every trailing newline in the old
            # shell wrapper. Preserve that behavior, including accepting a
            # deliberately empty placeholder as a configured empty value.
            secrets[name] = os.fsdecode(Path(path).read_bytes()).rstrip("\n")
        except OSError as error:
            print(
                f"research-agent-mcp: cannot read {path}: {error}",
                file=sys.stderr,
            )
            raise SystemExit(1)

    # Do not expose a partially populated environment if any read failed.
    os.environ.update(secrets)
    secrets.clear()

    # execve resets dumpability, so a subprocess that inherited os.environ
    # would recreate the same /proc leak in (for example) the server's git and
    # ssh children. Make Python's subprocess boundary copy the requested
    # environment and remove only these twelve secret variables. The server
    # already sends agent-side credentials to ssh over stdin, not its env.
    original_popen = subprocess.Popen


    class SecretStrippingPopen(original_popen):
        def __init__(self, *args, **kwargs):
            # `env` is Popen's eleventh positional parameter. Support both
            # spellings so a future caller cannot bypass the boundary merely
            # by passing an otherwise equivalent positional argument.
            env_position = 10
            requested_env = (
                args[env_position]
                if len(args) > env_position
                else kwargs.get("env")
            )
            child_env = dict(os.environ if requested_env is None else requested_env)
            for name in secret_paths:
                child_env.pop(name, None)
                child_env.pop(os.fsencode(name), None)
            if len(args) > env_position:
                positional_args = list(args)
                positional_args[env_position] = child_env
                args = tuple(positional_args)
            else:
                kwargs["env"] = child_env
            super().__init__(*args, **kwargs)


    subprocess.Popen = SecretStrippingPopen

    # Equivalent to `python3 -m mcp_server.server`: argv tail and inherited
    # stdio stay untouched while runpy supplies the module's __main__ context.
    runpy.run_module("mcp_server.server", run_name="__main__", alter_sys=True)
  '';
in
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "research-agent-mcp";
      # tesseract: the post-run artifact gate OCRs browser screenshots
      # (mcp_server/artifact_gate.py) before they reach reports/.
      runtimeInputs = [ pkgs.uv pkgs.tesseract ];
      text = ''
        # Lakera Guard tuned-policy project (not a secret — see
        # home/lakera.nix). injection_scanner/lakera.py sends
        # payload["project_id"] when this is set, selecting the tuned
        # L3 project policy instead of the account default.
        export LAKERA_PROJECT_ID=${lakera.lakeraProjectId}

        # Model Armor, the second L2 vendor (see home/model-armor.nix).
        # Path only: modelarmor.py reads the service-account key itself.
        export MODEL_ARMOR_CREDENTIALS_FILE=/run/agenix/model-armor-sa-key
        export MODEL_ARMOR_PROJECT=${modelArmor.project}
        export MODEL_ARMOR_LOCATION=${modelArmor.location}
        export MODEL_ARMOR_TEMPLATE=${modelArmor.template}

        # Host-to-VM SSH private key. The mcp_server reads this lazily
        # in _ssh_settings(); we only need to point it at the agenix
        # decrypt path. Override-friendly: a caller exporting
        # RESEARCH_SSH_KEY before us wins.
        export RESEARCH_SSH_KEY="''${RESEARCH_SSH_KEY:-/run/agenix/research-agent-host-key}"

        # injection-scanner L2 posts to Lakera Guard with stdlib urllib,
        # which verifies TLS against Python's default CA paths. The
        # uv-managed CPython finds no CA bundle on NixOS (no cafile;
        # the /etc/ssl/certs capath fallback needs hash-named symlinks
        # NixOS doesn't provide), so cert verify fails and the
        # fail-closed boot smoke rejects with lakera_unavailable:URLError
        # — server exits 2 before binding stdio. Point stdlib SSL at the
        # system bundle. The Anthropic/OpenAI SDKs bundle certifi and
        # never hit this, which is why only the urllib call breaks.
        export SSL_CERT_FILE="''${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}"

        # Liveness heartbeat the microvm watchdog reads to tell "busy" from
        # "dead". While a research call is dialing the VM the MCP touches
        # this file; the watchdog (research-agent-microvm-healthcheck.nix)
        # treats a fresh heartbeat as "busy, don't restart", so it no longer
        # kills a legitimately-running agent (2026-07-30: 93 mid-run
        # restarts in 2 days). The /run/research-agent dir is created
        # jonathan-owned by a tmpfiles rule in the healthcheck module;
        # writer (here) and reader (watchdog) agree on this exact path.
        export RESEARCH_ACTIVITY_FILE="''${RESEARCH_ACTIVITY_FILE:-/run/research-agent/active}"

        # The bootstrap is the final process. It disables dumpability before
        # reading agenix, then runs mcp_server.server in-process; neither this
        # shell nor the long-lived uv parent ever receives a secret value.
        exec uv run --project "$HOME/Repos/research-agent" \
            python3 ${researchAgentMcpBootstrap} "$@"
      '';
    })
  ];
}
