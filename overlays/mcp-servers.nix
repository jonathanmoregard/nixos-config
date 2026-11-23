{ pyproject-nix, uv2nix, pyproject-build-systems }:
final: prev:
let
  inherit (prev) lib;
  python = prev.python313;

  mkEnv = name:
    let
      workspace = uv2nix.lib.workspace.loadWorkspace {
        workspaceRoot = ../pkgs/mcp-servers + "/${name}";
      };
      pythonSet =
        (prev.callPackage pyproject-nix.build.packages { inherit python; })
          .overrideScope (lib.composeManyExtensions [
            pyproject-build-systems.overlays.default
            (workspace.mkPyprojectOverlay { sourcePreference = "wheel"; })
          ]);
    in
    pythonSet.mkVirtualEnv "${name}-env" workspace.deps.default;

  linkBin = pname: version: venv: bin:
    prev.runCommand "${pname}-${version}" { passthru = { inherit venv; }; } ''
      mkdir -p $out/bin
      ln -s ${venv}/bin/${bin} $out/bin/${bin}
    '';
in
{
  mcp-server-reddit = linkBin "mcp-server-reddit" "0.2.1" (mkEnv "reddit") "mcp-server-reddit";

  ha-mcp-unwrapped = linkBin "ha-mcp" "8.6.0" (mkEnv "ha-mcp") "ha-mcp";
  ha-mcp = final.callPackage ./ha-mcp.nix { };
}
