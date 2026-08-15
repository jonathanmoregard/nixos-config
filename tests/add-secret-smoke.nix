# add-secret-smoke — runtime-invocation harness for the add-secret
# wrapper (home/add-secret.nix; the exact derivation dellan puts on
# PATH is asserted below via deployedBin, not a rebuilt copy).
#
# What this exercises (fast — cheap runCommand, seconds):
#   - name validation rejects invalid shapes (uppercase, leading digit)
#   - preflight refuses when not in a nixos-config worktree root
#   - refuses when the secret is already declared in hosts/<host>/default.nix
#   - happy path (TEST_MODE=1):
#       - writes secrets/<name>.age (valid age file — starts with the
#         `age-encryption.org/v1` header)
#       - inserts age.secrets.<name> block above the marker in
#         hosts/dellan/default.nix
#       - refuses to overwrite an existing .age file on rerun
#
# What is NOT exercised here (requires real nix eval / real gh / real
# rekey — must be manually tested on dellan; see the PR body):
#   - `nix eval` sanity check
#   - `agenix-rekey rekey`
#   - git commit / push / gh pr create
#
# Run: nix build .#checks.x86_64-linux.add-secret-smoke -L
{ pkgs, addSecretPkg, deployedBin }:

pkgs.runCommand "add-secret-smoke"
  {
    inherit deployedBin;
    tool = "${addSecretPkg}/bin/add-secret";
    nativeBuildInputs = with pkgs; [ bash coreutils git gnugrep age ];
  } ''
    set -euo pipefail

    fail() {
      echo "FAIL: $*"
      for f in *.log; do
        [ -f "$f" ] && { echo "=== $f ==="; cat "$f"; }
      done
      exit 1
    }

    # --- drift gate ----------------------------------------------------
    # Whatever ends up on dellan's PATH must be the same store path we
    # just smoked.
    [ "$deployedBin" = "$tool" ] || \
      fail "dellan add-secret ($deployedBin) != tested tool ($tool)"

    # --- fixture: minimal worktree layout that satisfies preflight ------
    export HOME="$PWD/home"
    mkdir -p "$HOME"
    git config --global user.email "harness@example.invalid"
    git config --global user.name  "harness"
    git config --global init.defaultBranch main

    mkfixture() {
      local root="$1"
      mkdir -p "$root/hosts/dellan" "$root/secrets" "$root/modules/nixos"

      # flake.nix — presence-only; add-secret only checks the file exists
      # in TEST_MODE (no `nix eval` runs).
      : > "$root/flake.nix"

      # master pubkey extraction target — real shape, throwaway key.
      cat > "$root/modules/nixos/agenix-rekey-common.nix" <<'NIXFILE'
{ ... }:
{
  age.rekey = {
    masterIdentities = [
      {
        identity = "/home/jonathan/.ssh/id_ed25519";
        pubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINT9HeHhu82OoNsAHe/QAh116pSEANuZUr1h5m8R8kpp jonathan@dellan";
      }
    ];
  };
}
NIXFILE

      # host file — contains an existing secret AND the insertion marker.
      cat > "$root/hosts/dellan/default.nix" <<'NIXFILE'
{ config, ... }:
{
  age.secrets.pre-existing = {
    rekeyFile = ../../secrets/pre-existing.age;
    owner = "jonathan";
    group = "users";
    mode = "0400";
  };

  # add-secret:insert-here
}
NIXFILE

      ( cd "$root" && git init -q && git add -A && git commit -qm init )
    }

    # --- 1. name validation --------------------------------------------
    mkfixture "$PWD/f-badname"
    ( cd "$PWD/f-badname" && ADD_SECRET_TEST_MODE=1 "$tool" BadName --from-stdin ) \
      </dev/null >bad-uppercase.log 2>&1 && fail "accepted uppercase name" || true
    grep -q "invalid name" bad-uppercase.log \
      || fail "no invalid-name error for 'BadName'"

    ( cd "$PWD/f-badname" && ADD_SECRET_TEST_MODE=1 "$tool" 1leading --from-stdin ) \
      </dev/null >bad-leading-digit.log 2>&1 && fail "accepted leading-digit name" || true
    grep -q "invalid name" bad-leading-digit.log \
      || fail "no invalid-name error for '1leading'"

    # --- 2. preflight refuses outside a worktree root -------------------
    mkdir -p "$PWD/notarepo"
    ( cd "$PWD/notarepo" && ADD_SECRET_TEST_MODE=1 "$tool" foo --from-stdin ) \
      </dev/null >notarepo.log 2>&1 && fail "accepted non-worktree cwd" || true
    grep -q "not a nixos-config worktree root" notarepo.log \
      || fail "no preflight error message"

    # --- 3. refuse when secret already declared -------------------------
    mkfixture "$PWD/f-dup"
    ( cd "$PWD/f-dup" && ADD_SECRET_TEST_MODE=1 "$tool" pre-existing --from-stdin ) \
      </dev/null >dup.log 2>&1 && fail "accepted duplicate declaration" || true
    grep -q "already declared" dup.log \
      || fail "no already-declared error"

    # --- 4. happy path (TEST_MODE=1) ------------------------------------
    mkfixture "$PWD/f-ok"
    ( cd "$PWD/f-ok" && \
        printf 'sk_test_hunter2\n' | ADD_SECRET_TEST_MODE=1 "$tool" my-new-key --from-stdin ) \
      >ok.log 2>&1 || fail "happy path failed"

    # 4a. .age file exists and is a valid age v1 file (header is
    # 'age-encryption.org/v1\n' — 22 bytes)
    ageFile="$PWD/f-ok/secrets/my-new-key.age"
    [ -f "$ageFile" ] || fail "secrets/my-new-key.age was not created"
    head -c 22 "$ageFile" | grep -qF "age-encryption.org/v1" \
      || { echo "--- first 64 bytes of $ageFile ---"; head -c 64 "$ageFile" | od -c | head -4; fail ".age file lacks the age v1 header"; }

    # 4b. host file contains the new declaration block
    hostFile="$PWD/f-ok/hosts/dellan/default.nix"
    grep -q "age.secrets.my-new-key = {"          "$hostFile" || fail "host file missing 'age.secrets.my-new-key = {'"
    grep -q "rekeyFile = ../../secrets/my-new-key.age;" "$hostFile" || fail "host file missing rekeyFile line"
    grep -q "owner = \"jonathan\";"               "$hostFile" || fail "host file missing owner line"
    grep -q "group = \"users\";"                  "$hostFile" || fail "host file missing group line"
    grep -q "mode = \"0400\";"                    "$hostFile" || fail "host file missing mode line"

    # 4c. marker survives (still there for the next add-secret run)
    grep -q "# add-secret:insert-here" "$hostFile" || fail "insertion marker was consumed"

    # 4d. block is BEFORE the marker (i.e. inserted above it)
    block_line=$(grep -n "age.secrets.my-new-key = {" "$hostFile" | cut -d: -f1)
    marker_line=$(grep -n "# add-secret:insert-here" "$hostFile" | cut -d: -f1)
    [ "$block_line" -lt "$marker_line" ] \
      || fail "new block ($block_line) was inserted below marker ($marker_line)"

    # --- 5. custom owner/group/mode flow through ------------------------
    mkfixture "$PWD/f-custom"
    ( cd "$PWD/f-custom" && \
        printf 'val\n' | ADD_SECRET_TEST_MODE=1 "$tool" custom-secret \
          --from-stdin --owner root --group wheel --mode 0440 ) \
      >custom.log 2>&1 || fail "custom flags path failed"
    grep -q "owner = \"root\";"  "$PWD/f-custom/hosts/dellan/default.nix" || fail "custom owner not applied"
    grep -q "group = \"wheel\";" "$PWD/f-custom/hosts/dellan/default.nix" || fail "custom group not applied"
    grep -q "mode = \"0440\";"   "$PWD/f-custom/hosts/dellan/default.nix" || fail "custom mode not applied"

    # --- 6. rerun with same name in a fresh fixture must refuse ----------
    # (existing .age file guard — the .age file exists but the declaration
    # was manually removed to force the second code path.)
    mkfixture "$PWD/f-exists"
    printf 'x' | age -r "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINT9HeHhu82OoNsAHe/QAh116pSEANuZUr1h5m8R8kpp jonathan@dellan" \
      -o "$PWD/f-exists/secrets/orphan.age"
    ( cd "$PWD/f-exists" && printf 'v\n' | ADD_SECRET_TEST_MODE=1 "$tool" orphan --from-stdin ) \
      >exists.log 2>&1 && fail "accepted overwrite of pre-existing .age file" || true
    grep -q "already exists on disk" exists.log \
      || fail "no already-exists-on-disk error"

    # --- 7. KEY=VALUE sanitisation strips the prefix --------------------
    mkfixture "$PWD/f-strip"
    ( cd "$PWD/f-strip" && \
        printf 'FOO_API_KEY=abc123xyz\n' | ADD_SECRET_TEST_MODE=1 "$tool" stripme --from-stdin ) \
      >strip.log 2>&1 || fail "sanitise path failed"
    grep -q "stripping to just the value" strip.log \
      || fail "no strip log line — sanitiser did not fire on KEY=VALUE"
    # Decrypt back and verify only the value was stored. Use the master
    # identity file the harness dropped at a known throwaway path.
    # (We can't decrypt without the matching identity; instead assert
    # the ciphertext is longer than an empty payload and non-zero.)
    [ -s "$PWD/f-strip/secrets/stripme.age" ] || fail "stripme.age is empty"

    # --- 8. auto-detect: no source flag + piped stdin → read stdin ------
    # The nix sandbox always runs with a piped stdin (no controlling
    # tty), so calling the tool without --from-* and without an explicit
    # redirect must land in the stdin branch AND log the auto-detect
    # line to stderr. The TTY branch of auto-detect (should prompt) is
    # NOT covered here — a sandbox can't offer a controlling tty; that
    # branch is exercised by the manual test on the real host (see PR
    # body).
    mkfixture "$PWD/f-auto-stdin"
    ( cd "$PWD/f-auto-stdin" && \
        printf 'piped-value\n' | ADD_SECRET_TEST_MODE=1 "$tool" auto-stdin ) \
      >auto-stdin.log 2>&1 || fail "auto-detect stdin path failed"
    grep -q "reading value from stdin (piped)" auto-stdin.log \
      || fail "no auto-detect log line — stdin auto-detect did not fire"
    [ -f "$PWD/f-auto-stdin/secrets/auto-stdin.age" ] \
      || fail "auto-detect stdin path did not write the .age file"

    # --- 9. auto-detect: no source flag + no stdin (redirected to
    # /dev/null, simulating an interactive shell where stdin is a TTY
    # but has no data ready) → tool falls into prompt mode, then aborts
    # because no controlling tty is available in the sandbox. This
    # asserts the flag-absent branch does NOT silently consume
    # /dev/null as an empty stdin value (which would encrypt an empty
    # secret — the incident-class footgun this whole feature exists to
    # prevent).
    #
    # NOTE: /dev/null is NOT a tty (`[ -t 0 ]` is false), so
    # auto-detect resolves to "stdin". The prompt-branch tty guard is
    # therefore not what fires here — the empty-value guard is. Both
    # are acceptable; the invariant we care about is "does not
    # silently succeed".
    mkfixture "$PWD/f-auto-empty"
    ( cd "$PWD/f-auto-empty" && ADD_SECRET_TEST_MODE=1 "$tool" auto-empty </dev/null ) \
      >auto-empty.log 2>&1 && fail "auto-detect accepted empty piped value" || true
    grep -q "empty" auto-empty.log \
      || fail "no empty-value refusal on auto-detect + /dev/null"
    [ ! -f "$PWD/f-auto-empty/secrets/auto-empty.age" ] \
      || fail "auto-empty .age file was created despite empty input"

    # --- 10. explicit --prompt overrides auto-detect even with piped
    # stdin — must refuse (no controlling tty in the sandbox), not
    # silently fall through to reading stdin.
    mkfixture "$PWD/f-explicit-prompt"
    ( cd "$PWD/f-explicit-prompt" && \
        printf 'ignored-piped-value\n' | ADD_SECRET_TEST_MODE=1 "$tool" explicit-prompt --prompt ) \
      >explicit-prompt.log 2>&1 && fail "--prompt silently read piped stdin (override was ignored)" || true
    grep -q "controlling tty" explicit-prompt.log \
      || fail "no tty-required error when --prompt used non-interactively"
    [ ! -f "$PWD/f-explicit-prompt/secrets/explicit-prompt.age" ] \
      || fail "--prompt override was ignored — .age file created from piped stdin"

    echo "ok: name-validate, preflight, dup-refuse, happy-path, custom-attrs, exists-refuse, KEY= strip, auto-detect-stdin, auto-detect-empty-refuse, explicit-prompt-override"
    touch "$out"
  ''
