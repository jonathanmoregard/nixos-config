# klaffat-infra — sudo-gated OpenTofu provisioning for the Klaffat demo host.
#
# Contract: ~/.local/state/claude-tasks/kablong/klaffat-infra-contract.md
# Design:   ~/.local/state/claude-tasks/kablong/adopt-provisioning.md
# Gate:     nix build .#checks.x86_64-linux.vm-klaffat-infra
#
# ── The property this module exists to establish ──────────────────────
#
# An AI agent operates the klaffat repo as jonathan. The provisioning
# credentials (Hetzner + Cloudflare API tokens, the OpenTofu state
# encryption passphrase, the R2 S3 credentials) must therefore NOT be
# decryptable by jonathan. Every other secret in this repo is rekey-
# managed and encrypted to jonathan's USER key (see
# modules/nixos/agenix-rekey-common.nix) — i.e. to exactly the principal
# the agent runs as. That is fine for API keys the agent is meant to
# use; it is wrong for credentials that can create and destroy servers.
#
# So the seven secrets below deliberately do NOT go through agenix-rekey.
# They are plain `age.secrets.<n>.file` entries whose ciphertext is
# encrypted straight to dellan's HOST key
# (/etc/ssh/ssh_host_ed25519_key.pub, recipients in secrets/secrets.nix),
# decrypted at activation by root, and mounted 0400 root:root under
# /run/agenix. jonathan cannot read them; only a root process can.
#
# The only way to spend those credentials is `sudo klaffat-infra …`,
# whose sudoers rule carries no NOPASSWD and whose timestamp is not
# cached (timestamp_timeout=0, timestamp_type=tty). Every credentialed
# run is therefore one deliberate password entry by the founder.
#
# ── KNOWN GAP, must be closed for the above to be true ────────────────
#
# profiles/base.nix sets `security.sudo.wheelNeedsPassword = false`, so
# `%wheel ALL=(ALL:ALL) NOPASSWD: ALL` is in effect on dellan today.
# jonathan is in wheel. That rule lets ANY process running as jonathan
# do `sudo cat /run/agenix/klaffat-hcloud-token` with no password — which
# defeats this module's entire premise.
#
# The rules below still do their job for the two wrappers (sudoers is
# last-match-wins and the user rules here are emitted AFTER the wheel
# rule, so they force a password prompt for these two commands — asserted
# in tests/klaffat-infra.nix with `sudo -n`). But the SECRETS themselves
# are only as safe as the weakest path to root, and today that path is
# passwordless. Flipping wheelNeedsPassword to true is a separate,
# founder-visible change to the daily driver and is deliberately NOT
# bundled here.
#
# ── Why no KLAFFAT_INFRA_ALLOW_BRANCH escape hatch ────────────────────
#
# The contract permits a branch override only if sudo is granted
# `setenv`/`env_keep` for that one variable. The rule below has no SETENV
# tag (and must not have one — SETENV on a root-only wrapper is a
# straightforward privilege-escalation surface), sudo's env_reset drops
# the caller's environment, so the variable could never arrive. The
# escape hatch is therefore omitted entirely rather than shipped dead.
#
# ── Why root runs git with an explicit safe.directory ─────────────────
#
# The checkout is owned by jonathan and git refuses to operate on a
# repository owned by another user ("detected dubious ownership"). Each
# git invocation passes `-c safe.directory=<repo>` for exactly that path
# instead of mutating root's global gitconfig.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.klaffatInfra;

  # The main klaffat checkout. The directory is renamed from `kablong` to
  # `klaffat` once kablong PR #6 merges; this module targets the final
  # name, so the wrapper refuses (loudly, with the path) until it exists.
  repoRoot = "/home/jonathan/Repos/klaffat";
  tfDir = "${repoRoot}/deploy/terraform";

  # Root-only state. TF_DATA_DIR lives here rather than in the checkout so
  # the provider cache, the backend config and any lock artefacts are
  # never readable by jonathan and never dirty the tree the wrapper
  # itself refuses to run against.
  stateDir = "/var/lib/klaffat-infra";
  dataDir = "${stateDir}/terraform.d";

  bucket = "klaffat-tofu-state";
  stateKey = "demo/terraform.tfstate";

  secretPath = name: config.age.secrets.${name}.path;

  # Shared preamble: root-only, umask, and a full scrub of every TF_* /
  # AWS_* variable the caller might have set. sudo's env_reset already
  # drops them; this is the belt to that braces, and it also covers a
  # direct root invocation outside sudo.
  #
  # `${!PREFIX@}` rather than `compgen -v`: writeShellApplication runs on
  # `pkgs.bash` (non-interactive), which is built WITHOUT progcomp — the
  # first draft used compgen and died with "compgen: command not found"
  # in the VM lane. Prefix expansion is plain parameter expansion, always
  # present, and expands to zero words (not an error) under `set -u` when
  # nothing matches.
  rootOnlyPreamble = name: ''
    if [ "$(id -u)" -ne 0 ]; then
      echo "${name}: refusing to run as uid $(id -u) — this wrapper is root-only." >&2
      echo "${name}: use: sudo ${name} ${if name == "klaffat-infra" then "<tofu args...>" else "<ip>"}" >&2
      exit 1
    fi

    umask 077

    for _v in "''${!TF_@}" "''${!AWS_@}"; do
      unset "$_v"
    done
  '';

  klaffat-infra = pkgs.writeShellApplication {
    name = "klaffat-infra";
    runtimeInputs = [ pkgs.opentofu pkgs.awscli2 pkgs.git pkgs.coreutils ];
    text = ''
      ${rootOnlyPreamble "klaffat-infra"}

      repo="${repoRoot}"
      tfdir="${tfDir}"

      # --- preflight: the checkout must exist, be a clean git worktree,
      #     and be on main. No override: see the module header.
      if [ ! -d "$tfdir" ]; then
        echo "klaffat-infra: no OpenTofu checkout at $tfdir — refusing." >&2
        echo "klaffat-infra: clone the klaffat repo to $repo first (deploy/terraform must exist)." >&2
        exit 2
      fi

      # Root must not leave a trace in the founder's checkout. `git status`
      # normally REFRESHES .git/index, and doing that as root re-owns the
      # index — after which jonathan's next `git checkout` dies with
      # "index file open failed: Permission denied". Caught by the VM lane.
      # GIT_OPTIONAL_LOCKS=0 makes every git call below read-only on disk.
      export GIT_OPTIONAL_LOCKS=0

      if ! git -C "$repo" -c safe.directory="$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "klaffat-infra: $repo is not a git worktree — refusing." >&2
        exit 2
      fi

      dirty="$(git -C "$repo" -c safe.directory="$repo" --no-optional-locks status --porcelain)"
      if [ -n "$dirty" ]; then
        echo "klaffat-infra: working tree at $repo is dirty — refusing." >&2
        printf '%s\n' "$dirty" >&2
        exit 2
      fi

      branch="$(git -C "$repo" -c safe.directory="$repo" rev-parse --abbrev-ref HEAD)"
      if [ "$branch" != "main" ]; then
        echo "klaffat-infra: HEAD is on '$branch', not 'main' — refusing." >&2
        exit 2
      fi

      rev="$(git -C "$repo" -c safe.directory="$repo" rev-parse HEAD)"
      echo "klaffat-infra: $repo @ $rev (branch $branch)" >&2

      # --- secrets: read from /run/agenix (0400 root) into this process
      #     only. Nothing is written back to disk and nothing is echoed.
      for _s in \
        "${secretPath "klaffat-hcloud-token"}" \
        "${secretPath "klaffat-cloudflare-api-token"}" \
        "${secretPath "klaffat-state-passphrase"}" \
        "${secretPath "klaffat-r2-access-key-id"}" \
        "${secretPath "klaffat-r2-secret-access-key"}" \
        "${secretPath "klaffat-r2-account-id"}"; do
        if [ ! -r "$_s" ]; then
          echo "klaffat-infra: cannot read $_s — is the agenix secret provisioned?" >&2
          exit 3
        fi
      done

      TF_VAR_hcloud_token="$(< "${secretPath "klaffat-hcloud-token"}")"
      TF_VAR_cloudflare_api_token="$(< "${secretPath "klaffat-cloudflare-api-token"}")"
      TF_VAR_state_passphrase="$(< "${secretPath "klaffat-state-passphrase"}")"
      AWS_ACCESS_KEY_ID="$(< "${secretPath "klaffat-r2-access-key-id"}")"
      AWS_SECRET_ACCESS_KEY="$(< "${secretPath "klaffat-r2-secret-access-key"}")"
      account_id="$(< "${secretPath "klaffat-r2-account-id"}")"
      AWS_ENDPOINT_URL_S3="https://$account_id.r2.cloudflarestorage.com"
      export TF_VAR_hcloud_token TF_VAR_cloudflare_api_token TF_VAR_state_passphrase
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_ENDPOINT_URL_S3

      # --- environment. TF_IN_AUTOMATION is deliberately NOT set: its only
      #     effect is to suppress the "next step" hints, and this is an
      #     interactive, founder-driven tool.
      #
      #     TF_INPUT=0 refuses VARIABLE prompts — every credential arrives
      #     from /run/agenix, so a terminal prompt for one means something
      #     is misconfigured and should fail rather than be typed around.
      #     It does NOT suppress the apply approval: verified against
      #     opentofu 1.12.5, `TF_INPUT=0 tofu apply` still asks "Do you
      #     want to perform these actions?" and errors on EOF. So
      #     `sudo klaffat-infra apply` remains a real yes/no prompt.
      export TF_DATA_DIR="${dataDir}"
      export TF_INPUT=0

      install -d -m 0700 "${stateDir}" "${dataDir}"
      cd "$tfdir"

      # --- apply gets a post-run, server-side copy of the (already
      #     client-side encrypted) state object into history/. Everything
      #     else execs straight through.
      if [ "''${1-}" != "apply" ]; then
        exec tofu "$@"
      fi

      rc=0
      tofu "$@" || rc=$?
      if [ "$rc" -ne 0 ]; then
        exit "$rc"
      fi

      ts="$(date -u +%Y%m%dT%H%M%SZ)"
      key="history/$ts-demo.tfstate"
      echo "klaffat-infra: copying encrypted state to $key" >&2
      crc=0
      aws s3api copy-object \
        --endpoint-url "$AWS_ENDPOINT_URL_S3" \
        --bucket "${bucket}" \
        --copy-source "${bucket}/${stateKey}" \
        --key "$key" >/dev/null || crc=$?
      if [ "$crc" -ne 0 ]; then
        echo "klaffat-infra: !! APPLY SUCCEEDED, HISTORY COPY FAILED (aws exit $crc)." >&2
        echo "klaffat-infra: !! infrastructure is changed; only the dated snapshot is missing." >&2
        echo "klaffat-infra: !! re-run the copy before the next apply, or accept the gap." >&2
        exit 4
      fi
      echo "klaffat-infra: history copy ok -> $key" >&2
    '';
  };

  klaffat-infra-install = pkgs.writeShellApplication {
    name = "klaffat-infra-install";
    runtimeInputs = [ pkgs.openssh pkgs.coreutils config.nix.package pkgs.git ];
    text = ''
      ${rootOnlyPreamble "klaffat-infra-install"}

      if [ "$#" -ne 1 ]; then
        echo "klaffat-infra-install: usage: sudo klaffat-infra-install <ip>" >&2
        exit 2
      fi
      ip="$1"
      case "$ip" in
        ""|*[!0-9a-fA-F.:]*)
          echo "klaffat-infra-install: '$ip' is not an IP address — refusing." >&2
          exit 2
          ;;
        *) ;;
      esac

      if [ ! -d "${repoRoot}" ]; then
        echo "klaffat-infra-install: no klaffat checkout at ${repoRoot} — refusing." >&2
        exit 2
      fi

      hostkey="${secretPath "klaffat-demo-host-key"}"
      if [ ! -r "$hostkey" ]; then
        echo "klaffat-infra-install: cannot read $hostkey — is the agenix secret provisioned?" >&2
        exit 3
      fi

      # --extra-files staging dir. /run/user/0 (tmpfs) when root has a
      # runtime dir, otherwise the root-only state dir. Never /tmp: the
      # private half of the demo host's SSH identity passes through here.
      install -d -m 0700 "${stateDir}"
      base="/run/user/0"
      if [ ! -d "$base" ]; then
        base="${stateDir}"
      fi
      EXTRA="$(mktemp -d "$base/klaffat-extra-files.XXXXXXXX")"
      trap 'rm -rf -- "$EXTRA"' EXIT

      install -d -m 0755 "$EXTRA/etc" "$EXTRA/etc/ssh"
      install -m 0600 "$hostkey" "$EXTRA/etc/ssh/ssh_host_ed25519_key"
      ssh-keygen -y -f "$EXTRA/etc/ssh/ssh_host_ed25519_key" \
        > "$EXTRA/etc/ssh/ssh_host_ed25519_key.pub"
      chmod 0644 "$EXTRA/etc/ssh/ssh_host_ed25519_key.pub"

      # nix resolves a local path flakeref through git; the checkout is
      # jonathan-owned, so hand root's git the one safe.directory it needs
      # without touching any gitconfig on disk.
      export GIT_CONFIG_COUNT=1
      export GIT_CONFIG_KEY_0="safe.directory"
      export GIT_CONFIG_VALUE_0="${repoRoot}"

      echo "klaffat-infra-install: installing klaffat-demo onto root@$ip" >&2
      # No `exec`: the EXIT trap above must still fire to shred $EXTRA.
      rc=0
      nix run "${repoRoot}#nixos-anywhere" -- \
        --extra-files "$EXTRA" \
        --flake "${repoRoot}#klaffat-demo" \
        "root@$ip" || rc=$?
      exit "$rc"
    '';
  };

  # The command list the sudo rule and the command-scoped Defaults share.
  # Store paths pin the exact binaries; the /run/current-system spellings
  # are what `sudo klaffat-infra` actually resolves to through PATH and
  # sudo does not follow the symlink back to the store (see the comment on
  # security.sudo.extraRules below).
  sudoCommands = [
    "${klaffat-infra}/bin/klaffat-infra"
    "${klaffat-infra-install}/bin/klaffat-infra-install"
    "/run/current-system/sw/bin/klaffat-infra"
    "/run/current-system/sw/bin/klaffat-infra-install"
  ];

  # Every secret here shares one shape: encrypted to dellan's host key,
  # decrypted by root at activation, unreadable by jonathan.
  rootSecret = file: {
    inherit file;
    owner = "root";
    group = "root";
    mode = "0400";
  };
in
{
  options.services.klaffatInfra.enable = lib.mkEnableOption
    "the sudo-gated klaffat-infra OpenTofu wrapper and its root-only provisioning secrets";

  config = lib.mkIf cfg.enable {
    # ── Secrets ─────────────────────────────────────────────────────────
    # `file`, not `rekeyFile`: these must NOT be encrypted to the
    # agenix-rekey master identity (jonathan's user key). See header.
    age.secrets = {
      klaffat-hcloud-token = rootSecret ../../secrets/klaffat-hcloud-token.age;
      klaffat-cloudflare-api-token = rootSecret ../../secrets/klaffat-cloudflare-api-token.age;
      klaffat-state-passphrase = rootSecret ../../secrets/klaffat-state-passphrase.age;
      klaffat-r2-access-key-id = rootSecret ../../secrets/klaffat-r2-access-key-id.age;
      klaffat-r2-secret-access-key = rootSecret ../../secrets/klaffat-r2-secret-access-key.age;
      klaffat-r2-account-id = rootSecret ../../secrets/klaffat-r2-account-id.age;
      klaffat-demo-host-key = rootSecret ../../secrets/klaffat-demo-host-key.age;
    };

    # The host key is the only identity that decrypts the above. dellan
    # already defaults to this via services.openssh.hostKeys, but the
    # feature VM overrides identityPaths to jonathan's user key, and an
    # implicit dependency on that default is exactly the kind of thing
    # that silently starts decrypting under the wrong principal.
    age.identityPaths = lib.mkDefault [ "/etc/ssh/ssh_host_ed25519_key" ];

    # ── State dir ───────────────────────────────────────────────────────
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 root root -"
      "d ${dataDir} 0700 root root -"
    ];

    # ── Wrappers on PATH ────────────────────────────────────────────────
    # On PATH system-wide so `sudo klaffat-infra` resolves; both refuse
    # outright unless euid is 0, so being on jonathan's PATH grants
    # nothing.
    environment.systemPackages = [ klaffat-infra klaffat-infra-install ];

    # ── sudo ────────────────────────────────────────────────────────────
    # No NOPASSWD, no SETENV. Emitted after the module's own wheel rule
    # (mkOrder 600 in nixpkgs' security/sudo.nix), and sudoers is
    # last-match-wins, so these commands are password-gated even while
    # wheel is NOPASSWD.
    #
    # BOTH spellings of each wrapper are listed, and that is load-bearing.
    # sudo 1.9.17p2 matches a sudoers command against the path the user
    # actually invoked, WITHOUT resolving symlinks — measured, not
    # assumed: with only the store paths listed, `sudo klaffat-infra`
    # (which PATH resolves to /run/current-system/sw/bin/klaffat-infra, a
    # symlink into that very store path) fell through to the wheel rule
    # and RAN WITH NO PASSWORD. The lane now asserts both forms prompt,
    # so this cannot silently regress.
    security.sudo.extraRules = [
      {
        users = [ "jonathan" ];
        runAs = "root:root";
        commands = map (command: { inherit command; options = [ ]; }) sudoCommands;
      }
    ];

    # Command-scoped, not global: sudoers applies command Defaults after
    # the command is matched and before authentication, so the timestamp
    # rules bite for these commands only and no other sudo use on the
    # laptop changes behaviour.
    security.sudo.extraConfig = ''
      Cmnd_Alias KLAFFAT_INFRA_CMNDS = ${lib.concatStringsSep ", " sudoCommands}
      Defaults!KLAFFAT_INFRA_CMNDS timestamp_timeout=0
      Defaults!KLAFFAT_INFRA_CMNDS timestamp_type=tty
    '';
  };
}
