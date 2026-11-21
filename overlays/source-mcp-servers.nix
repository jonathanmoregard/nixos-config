# MCP servers that used to run from a writable checkout through `uv run`,
# built from pinned source inputs with uv2nix from each repo's own uv.lock.
# Rationale (uv2nix, wheels, bump procedure): overlays/aggregator.nix.
# Interpreters follow each repo's .python-version, which is what uv ran.
{ pyproject-nix, uv2nix, pyproject-build-systems, research-agent-src, gdocs-review-mcp-src }:
final: prev:
let
  inherit (prev) lib;

  mkVenv = { name, src, python, overrides ? (_: _: { }) }:
    let
      workspace = uv2nix.lib.workspace.loadWorkspace { workspaceRoot = src; };
      pythonSet =
        (prev.callPackage pyproject-nix.build.packages { inherit python; })
          .overrideScope (lib.composeManyExtensions [
            pyproject-build-systems.overlays.default
            (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
            overrides
          ]);
    in
    pythonSet.mkVirtualEnv name workspace.deps.default;

  researchAgentVenv = mkVenv {
    name = "research-agent-env";
    src = research-agent-src;
    python = prev.python312;
    # uv.lock records no build backend for a git source; this is the one
    # injection-scanner's own pyproject declares.
    overrides = pyFinal: pyPrev: {
      injection-scanner = pyPrev.injection-scanner.overrideAttrs (old: {
        nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ pyFinal.resolveBuildSystem { setuptools = [ ]; };
      });
    };
  };

  gdocsVenv = mkVenv {
    name = "gdocs-review-mcp-env";
    src = gdocs-review-mcp-src;
    python = prev.python311;
  };
in
{
  research-agent-mcp = final.callPackage ./research-agent-mcp.nix { venv = researchAgentVenv; };

  # Tools are fixed here so the registered argv is the bare store path.
  # load_dotenv(override=False) keeps uv --env-file's precedence: a variable
  # already in the environment wins over the file.
  gdocs-review-mcp = prev.writeTextFile {
    name = "gdocs-review-mcp";
    destination = "/bin/gdocs-review-mcp";
    executable = true;
    text = ''
      #!${gdocsVenv}/bin/python3
      import os
      import sys

      from dotenv import load_dotenv

      env_file = os.path.expanduser("~/.config/gdocs-review-mcp/env")
      if not os.path.isfile(env_file):
          print(f"gdocs-review-mcp: no environment file at {env_file}", file=sys.stderr)
          raise SystemExit(2)
      load_dotenv(env_file, override=False)

      server = "${gdocsVenv}/bin/workspace-mcp"
      os.execv(
          server,
          [server, "--transport", "stdio", "--single-user", "--tools", "docs", "docs_preview", *sys.argv[1:]],
      )
    '';
    derivationArgs.passthru.venv = gdocsVenv;
    meta.mainProgram = "gdocs-review-mcp";
  };
}
