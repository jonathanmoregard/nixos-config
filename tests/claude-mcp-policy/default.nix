# The module's own checks (eval.nix), then the real importer fed the primary
# host's generated list: the module and the importer must agree on its shape.
{ pkgs, hostConfig }:
let
  etc = hostConfig.environment.etc;
  names = pkgs.writeText "claude-mcp-names.json"
    (builtins.toJSON (builtins.attrNames hostConfig.claude.mcp.servers));
in
pkgs.runCommand "claude-mcp-policy" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  echo ${pkgs.lib.escapeShellArg (import ./eval.nix { inherit (pkgs) lib; })}
  python3 ${./importer_contract.py} ${../../scripts/claude-mcp-import.py} \
    ${etc."claude-code/mcp-servers.json".source} \
    ${etc."claude-code/managed-settings.d/50-mcp.json".source} \
    ${names}
  touch $out
''
