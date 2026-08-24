# dcg — Destructive Command Guard.
#
# https://github.com/Dicklesworthstone/destructive_command_guard
#
# A PreToolUse guard for AI coding agents: it reads a Claude Code hook
# payload on stdin (`{"tool_name":"Bash","tool_input":{"command":"…"}}`)
# and, when the command matches a destructive pattern, writes a decorated
# banner plus a JSON object carrying
# `hookSpecificOutput.permissionDecision = "deny"` to stdout. Allowed
# commands produce no output at all.
#
# The DECISION IS THE STDOUT JSON, NOT THE EXIT CODE. Measured against
# v0.12.5, invoking BARE `dcg` with no subcommand — the form
# ~/.claude/settings.json actually registers: it exits 0 on a deny, on an
# allow, on empty stdin and on garbage stdin alike. A consumer that reads
# the exit status instead of the payload sees every deny as an allow.
#
# DO NOT "FIX" THAT BY SWITCHING THE HOOK TO `dcg hook`. Its own --help
# claims that without `--batch` it "behaves identically to running `dcg`
# with no subcommand". Measured, that is false. On the same stdin:
#
#   dcg      < payload  →  {"hookSpecificOutput":{…"permissionDecision":"deny"…}}
#   dcg hook < payload  →  {"index":0,"decision":"deny","mode":"deny",…}
#
# `dcg hook` does exit 1 on a deny, but it speaks batch JSONL rather than
# the Claude Code PreToolUse document, and it prints on allows too (bare
# `dcg` prints nothing). Switching would buy a correct exit status and
# lose the protocol — Claude Code would never see a `permissionDecision`
# again, which is the same silent disarmament this package exists to
# prevent. The exit code is not the contract; the stdout document is.
#
# WHY THIS IS PACKAGED HERE RATHER THAN `cargo install`ed
#
# It used to be `cargo install`ed into ~/.local/bin on the old Linux Mint
# box. The Mint → NixOS migration dropped the binary and the
# ~/.config/dcg symlink with it, and the consumer (the safe-bash MCP's
# `_check_denied_by_dcg`) failed OPEN when the binary was absent — so the
# richest deny layer in the stack was silently inert for months and
# nobody noticed. An imperatively installed security dependency is a
# security dependency that an OS migration can delete without a trace.
# Declaring it here means the binary is part of the system closure: it
# cannot vanish without a diff.
#
# PINNING
#
# Pinned to the v0.12.5 release tag's commit rather than a branch: this
# is a deny-list evaluator whose behaviour IS the security boundary, so
# it must not move under the host without a PR. Bump by editing `rev` +
# `version`, running the build, and pasting the hashes nix reports.
#
# `version` and `rev` are two hand-edited strings that nothing forces to
# agree. Editing `version` alone leaves `src` — and therefore its hash —
# untouched, so the build stays green and ships the OLD binary under the
# NEW label; the closure, `dcg --version`, and any provenance check that
# trusts either would all report a version that was never built. postPatch
# asserts the fetched source's own Cargo.toml agrees with `version` (that
# is the assertion `rev` cannot dodge, because `rev` is what selects the
# Cargo.toml), and installCheckPhase asserts the built binary prints it.
#
# BUILD NOTES
#
#   - `.cargo/config.toml` upstream sets `rustflags = ["-Z","threads=4"]`,
#     a nightly-only flag; nixpkgs builds with stable rustc, which rejects
#     `-Z` outright. Removed in postPatch.
#   - `rust-toolchain.toml` pins a nightly channel. nixpkgs' cargo is not
#     a rustup shim so it ignores the file today; removed anyway so a
#     future rustup-aware cargo cannot silently try to download a
#     toolchain in the sandbox.
#   - aws-lc-sys (pulled in by self_update → reqwest → rustls) builds C
#     via cmake. `dontUseCmakeConfigure` keeps nixpkgs' cmake setup-hook
#     from hijacking the configure phase away from cargo.
#   - Upstream's own test suite is not run here (`doCheck = false`): it
#     includes proptest/insta/E2E lanes that look for an installed `dcg`
#     on PATH and are not a claim this repo needs to make. What IS
#     asserted, in installCheckPhase, is the contract this host actually
#     depends on — the Claude Code hook protocol on stdin/stdout — and
#     the same contract is re-asserted end-to-end against the deployed
#     binary in tests/base.nix.
final: prev:
let
  version = "0.12.5";
  # Commit that refs/tags/v0.12.5 peels to.
  rev = "d921fe84f7bbf56438e7b930047ab41e0dcb292d";

  # Config fixture for installCheckPhase. Written as a store file rather
  # than a heredoc inside the phase: a heredoc body would be re-indented
  # by the surrounding Nix `''` string and its terminator would stop
  # terminating.
  #
  # The reason string is bound to a Nix variable and interpolated into both
  # the fixture and the assertion, so the two cannot drift.
  dcgFixtureReason = "installCheck fixture rule, not a built-in pack";
  dcgFixtureConfig = prev.writeText "dcg-installcheck-config.toml" ''
    [general]
    verbose = false

    [overrides]
    allow = []
    block = [
        { pattern = "curl.*-X\\s+(DELETE|PUT|PATCH)", reason = "${dcgFixtureReason}" },
    ]
  '';
in
{
  dcg = prev.rustPlatform.buildRustPackage {
    pname = "dcg";
    inherit version;

    src = prev.fetchFromGitHub {
      owner = "Dicklesworthstone";
      repo = "destructive_command_guard";
      inherit rev;
      hash = "sha256-cBi1b4/OEzkaiPC40y3rr1nM++eLUOHyYCy/hpt3gGg=";
    };

    cargoHash = "sha256-0mde/kHnw/owTyp5KSq+ybf3o0o253rW6jhtj0hWFes=";

    postPatch = ''
      rm -f .cargo/config.toml rust-toolchain.toml

      # `version` vs `rev` drift guard. `[package]` is the first table in
      # upstream's Cargo.toml, so the first column-0 `version = ` line is
      # the crate version. Fails the build before a single crate compiles.
      srcVersion=$(sed -n 's/^version = "\(.*\)"$/\1/p' Cargo.toml | head -n 1)
      if [ "$srcVersion" != "${version}" ]; then
        echo "dcg: overlay version/rev disagree." >&2
        echo "  overlays/dcg.nix version = ${version}" >&2
        echo "  overlays/dcg.nix rev     = ${rev}" >&2
        echo "  Cargo.toml at that rev   = $srcVersion" >&2
        echo "Bump BOTH, or the closure ships $srcVersion labelled ${version}." >&2
        exit 1
      fi
    '';

    nativeBuildInputs = with prev; [ cmake pkg-config ];
    dontUseCmakeConfigure = true;

    doCheck = false;

    # The one behaviour this host depends on, proven against the binary
    # that is about to be installed: a destructive HTTP verb must produce
    # a `deny` decision on stdout, and a benign command must produce no
    # decision at all. Both run against a config written here, so the
    # assertion does not depend on which built-in packs ship by default.
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck

      # The BUILT binary agrees with the label. postPatch already tied
      # `version` to the source; this ties it to the artifact, so the two
      # together mean `pkgs.dcg.version` cannot be a claim about a binary
      # that was never produced. The machine-readable string is on stdout;
      # the decorated banner goes to stderr, hence the redirect.
      binVersion=$($out/bin/dcg --version 2>/dev/null | head -n 1 | tr -d '[:space:]')
      if [ "$binVersion" != "${version}" ]; then
        echo "dcg installCheck: --version printed '$binVersion', pinned version is '${version}'" >&2
        exit 1
      fi

      export HOME="$TMPDIR/dcg-installcheck"
      mkdir -p "$HOME/.config/dcg"
      cp ${dcgFixtureConfig} "$HOME/.config/dcg/config.toml"

      deny_out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"curl -X DELETE https://example.com/x"}}' \
        | $out/bin/dcg || true)
      case "$deny_out" in
        *'"permissionDecision"'*'"deny"'*) : ;;
        *)
          echo "dcg installCheck: destructive command was NOT denied" >&2
          echo "$deny_out" >&2
          exit 1
          ;;
      esac

      # A `deny` alone proves too little. dcg ships built-in packs, and a
      # future pack that happens to cover destructive HTTP verbs would
      # satisfy the check above on a build where the fixture config was
      # never opened — which is precisely the "guard looks alive while its
      # config is unread" shape this package exists to detect. So the deny
      # has to be ATTRIBUTED to the fixture, two ways:
      #
      #   - it carries the fixture's own reason string, and
      #   - it carries neither ruleId nor packId. dcg tags a pack match
      #     with those and an `[overrides]` match with neither, so their
      #     absence is the positive marker of a user-config decision.
      #
      # Same pair of assertions the vm-base lane makes against the deployed
      # binary (tests/base.nix, dcg_assert_denied_by_user_config).
      case "$deny_out" in
        *'${dcgFixtureReason}'*) : ;;
        *)
          echo "dcg installCheck: the deny does not carry the fixture's reason" >&2
          echo "  expected to find: ${dcgFixtureReason}" >&2
          echo "$deny_out" >&2
          exit 1
          ;;
      esac
      case "$deny_out" in
        *'"packId"'* | *'"ruleId"'*)
          echo "dcg installCheck: the deny came from a built-in pack, not from" >&2
          echo "  the fixture config - so it proves nothing about the config" >&2
          echo "  path being read at all" >&2
          echo "$deny_out" >&2
          exit 1
          ;;
      esac

      allow_out=$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls -la"}}' \
        | $out/bin/dcg || true)
      case "$allow_out" in
        *permissionDecision*)
          echo "dcg installCheck: benign command produced a permission decision" >&2
          echo "$allow_out" >&2
          exit 1
          ;;
      esac

      runHook postInstallCheck
    '';

    meta = {
      description = "Blocks destructive shell commands from AI coding agents (PreToolUse hook)";
      homepage = "https://github.com/Dicklesworthstone/destructive_command_guard";
      # NOT plain MIT. Upstream ships "MIT License (with OpenAI/Anthropic
      # Rider)": an additional condition denying all rights to OpenAI,
      # Anthropic, their affiliates, and anyone acting on their behalf.
      # That discriminates against specific persons/entities, so it is not
      # a free licence by the FSF/OSI/DFSG reading, whatever the file is
      # titled — declaring `licenses.mit` here would be a false claim in
      # the closure metadata. Marked unfree-but-redistributable; this
      # flake sets `config.allowUnfree = true`, so nothing else changes.
      # Personal use on a personal machine is squarely inside the grant.
      license = {
        shortName = "MIT-with-OpenAI-Anthropic-rider";
        fullName = "MIT License (with OpenAI/Anthropic Rider)";
        url = "https://github.com/Dicklesworthstone/destructive_command_guard/blob/${rev}/LICENSE";
        free = false;
        redistributable = true;
      };
      mainProgram = "dcg";
      platforms = prev.lib.platforms.linux;
    };
  };
}
