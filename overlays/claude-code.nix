# Bump claude-code past what the locked nixpkgs ships.
#
# The system `claude` (modules/common.nix, the research-agent microvm guest,
# the klaffat dependabot caretaker) is the nixpkgs build. Model availability
# is gated by CLI version, not just by the API: 2.1.222 refuses
# `claude-opus-5-5` (needs >= 2.1.280) and `claude-fable-5-1` (>= 2.1.251)
# with "Claude Code 2.1.222 does not support this model", so every headless
# caller pinned to a current model fails in seconds.
#
# Only `version` and `src` change; the nixpkgs wrapper (DISABLE_AUTOUPDATER,
# bubblewrap/socat/ripgrep on PATH) and its versionCheckHook are kept. The
# version check is what guards against editing `version` without `src`:
# the built binary must print the version declared here.
#
# Bump: change `version`, then
#   nix store prefetch-file https://downloads.claude.ai/claude-code-releases/<v>/linux-x64/claude
# and paste the reported hash. Drop this overlay once nixpkgs catches up.
final: prev: {
  claude-code = prev.claude-code.overrideAttrs (old: rec {
    version = "2.1.288";
    src = prev.fetchurl {
      url = "https://downloads.claude.ai/claude-code-releases/${version}/linux-x64/claude";
      hash = "sha256-ApgGi2huf9uvlAKnpYe7f0nAsOCE3gn2kUWgcZIHZAw="; # pragma: allowlist secret
    };
  });
}
