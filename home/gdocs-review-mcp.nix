{ pkgs, ... }:
# gdocs-review-mcp wrapper.
#
# Claude Code spawns `gdocs-review-mcp` as a stdio MCP subprocess
# (configured in ~/.claude.json). The server is a fork of the Google
# Workspace MCP checked out at ~/Repos/gdocs-review-mcp; it talks to the
# Google Docs / Drive / Forms REST APIs on behalf of a single user.
#
# Why a wrapper instead of the raw `uv run …` argv that used to live in
# ~/.claude.json: the server can only mint NEW OAuth grants when
# GOOGLE_OAUTH_CLIENT_ID / GOOGLE_OAUTH_CLIENT_SECRET are present in the
# process env (auth/oauth_config.py + auth/google_auth.py read exactly
# those two names; the fallback is a client-secrets JSON file we don't
# ship). The already-stored token in WORKSPACE_MCP_CREDENTIALS_DIR
# carries a refresh_token and therefore keeps working for the scopes it
# was granted — but adding a service (here: Forms) needs a fresh consent
# round-trip, which without those two env vars fails with "OAuth client
# credentials not found". Claude Code's `env` block takes literal values
# only, never file paths, so the values would have to be pasted in
# plaintext into ~/.claude.json. Wrapping instead keeps them in agenix
# and reads them at exec time — same pattern as research-agent-mcp.nix
# and futuresearch-gate-mcp.nix.
#
# `--tools docs docs_preview forms drive` is the enabled service set
# (keys from main.py's service map). `forms` is the addition this module
# exists for; `drive` comes along because the Forms/Docs tools resolve
# and list files through Drive.
#
# Wrapper name `gdocs-review-mcp` is what ~/.claude.json invokes as its
# `command`, with empty args and no env block — everything the server
# needs is set here.
{
  home.packages = [
    (pkgs.writeShellApplication {
      name = "gdocs-review-mcp";
      runtimeInputs = [ pkgs.uv ];
      text = ''
        # The enabled service set is FIXED, and nothing a caller passes
        # may widen it. `--tools` in main.py is argparse `nargs="*"`
        # over `choices=VALID_SERVICES`, and the parser declares no
        # positionals — so any argument that reaches it is greedily
        # folded into the service list. Forwarding `"$@"` here meant
        # `gdocs-review-mcp gmail` registered the Gmail tools too
        # (measured on dellan: 50 tools -> 64, including
        # send_gmail_message). Claude Code invokes this wrapper with an
        # empty args list, so refusing arguments costs nothing and
        # closes the hole; silently dropping them would hide misuse.
        if [ "$#" -gt 0 ]; then
          echo "gdocs-review-mcp: refusing caller-supplied arguments ($*)." >&2
          echo "gdocs-review-mcp: the service set is fixed at 'docs docs_preview forms drive'." >&2
          exit 64
        fi

        # Read raw-value secrets from agenix decrypt paths. The `.age`
        # files contain ONLY the value (no `GOOGLE_OAUTH_CLIENT_ID=`
        # prefix), so `source` would mis-interpret line 1 as a shell
        # command. `$(< file)` reads the file body and strips the
        # trailing newline — exactly what we want as an env var value.
        GOOGLE_OAUTH_CLIENT_ID=$(< /run/agenix/google-oauth-client-id)
        GOOGLE_OAUTH_CLIENT_SECRET=$(< /run/agenix/google-oauth-client-secret)
        export GOOGLE_OAUTH_CLIENT_ID GOOGLE_OAUTH_CLIENT_SECRET

        # Single-user mode: every tool call defaults to this account
        # instead of requiring an explicit user_google_email argument.
        export USER_GOOGLE_EMAIL="jonathan@klaffat.com"

        # Where the refresh-token JSON lives. Must stay stable across
        # deploys — a different path means a fresh consent flow.
        export WORKSPACE_MCP_CREDENTIALS_DIR="''${WORKSPACE_MCP_CREDENTIALS_DIR:-$HOME/.google_workspace_mcp/credentials}"

        # The uv-managed CPython finds no CA bundle on NixOS (no cafile;
        # the /etc/ssl/certs capath fallback needs hash-named symlinks
        # NixOS doesn't provide), so any stdlib-TLS call fails cert
        # verification. This server does nothing BUT HTTPS calls to
        # googleapis.com, so point stdlib SSL at the system bundle.
        # Full rationale in research-agent-mcp.nix.
        export SSL_CERT_FILE="''${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}"

        # Project dir for `uv run`. Override-friendly for pre-deploy
        # testing (mirrors FUTURESEARCH_GATE_PROJECT in
        # futuresearch-gate-mcp.nix): a caller exporting
        # GDOCS_REVIEW_PROJECT before us wins.
        GDOCS_PROJECT="''${GDOCS_REVIEW_PROJECT:-$HOME/Repos/gdocs-review-mcp}"

        # `--directory` (not `--project`) because main.py is resolved
        # relative to the working directory.
        exec uv run --directory "$GDOCS_PROJECT" \
            python main.py --transport stdio --single-user \
            --tools docs docs_preview forms drive
      '';
    })
  ];
}
