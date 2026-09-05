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
# ── Builds never run on the demo host ─────────────────────────────────
#
# Founder decision, 2026-09-05: the host substitutes, it does not build.
# `sudo klaffat-publish [rev]` builds the host's toplevel HERE, signs the
# closure with a root-only Nix signing key, and pushes it to the
# S3 binary cache; the host pulls with its own read-only IAM user and
# trusts the signing key's PUBLIC half.
#
# GitHub Actions publishes the same way on push:main, but authenticates by
# OIDC role assumption (no repository secrets — on a private Free repo a
# same-repo PR workflow can read those, so a long-lived credential there
# would be readable by anything that can open a PR) and fetches the
# signing key from AWS Secrets Manager. `sudo klaffat-publish
# --upload-signing-key` is the one path that puts the key there, from the
# root-only agenix copy, behind the same password. Terraform manages only
# the secret's existence, so the key never enters tofu state either.
#
# ── Why profiles/base.nix now requires a sudo password ────────────────
#
# It used to set `security.sudo.wheelNeedsPassword = false`, i.e.
# `%wheel ALL=(ALL:ALL) NOPASSWD: ALL`, and jonathan is in wheel. That
# rule let ANY process running as jonathan do
# `sudo cat /run/agenix/klaffat-hcloud-token` with no password — which
# defeated this module's entire premise, because the secrets are only as
# safe as the weakest path to root.
#
# The per-command rules below would still have prompted (sudoers is
# last-match-wins and these rules are emitted AFTER the wheel rule), but
# that only gates the wrappers, not the files. So `wheelNeedsPassword` is
# now `true` — founder-approved, 2026-09-05. The daily-driver consequence
# is real: every `sudo` on dellan now asks for a password. The lane
# asserts `sudo -n true` FAILS for jonathan, so a future revert cannot
# quietly reopen the hole.
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

  # CONTRACT v2 (2026-09-05): AWS, region eu-north-1. `klaffat-tofu-state`
  # is clickops-created with versioning ON (so it is never managed by the
  # state it holds, and its own history needs no wrapper support);
  # `klaffat-nix-cache` is Terraform-managed.
  awsRegion = "eu-north-1";
  bucket = "klaffat-tofu-state";

  # The Nix binary cache the demo host substitutes from. Builds never run on
  # the host (founder decision, 2026-09-05) — the laptop, or GitHub Actions
  # via OIDC, builds and signs; the host trusts the signing key's PUBLIC
  # half and reads with its own read-only IAM user.
  cacheBucket = "klaffat-nix-cache";
  cacheUrl = "s3://${cacheBucket}?region=${awsRegion}";

  # AWS Secrets Manager secret holding the signing key, so the Actions
  # publish workflow signs with the SAME key as the laptop. Terraform
  # manages the secret's existence; its value is written exactly once, by
  # `sudo klaffat-publish --upload-signing-key`, from the root-only agenix
  # copy — so the plaintext never passes through Terraform state or CI.
  signingKeySecretId = "klaffat/nix-signing-key";

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
  rootOnlyPreamble = name: usage: ''
    if [ "$(id -u)" -ne 0 ]; then
      echo "${name}: refusing to run as uid $(id -u) — this wrapper is root-only." >&2
      echo "${name}: use: sudo ${name} ${usage}" >&2
      exit 1
    fi

    umask 077

    for _v in "''${!TF_@}" "''${!AWS_@}"; do
      unset "$_v"
    done
  '';

  klaffat-infra = pkgs.writeShellApplication {
    name = "klaffat-infra";
    runtimeInputs = [ pkgs.opentofu pkgs.git pkgs.coreutils ];
    text = ''
      ${rootOnlyPreamble "klaffat-infra" "<tofu args...>"}

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
        "${secretPath "klaffat-aws-access-key-id"}" \
        "${secretPath "klaffat-aws-secret-access-key"}"; do
        if [ ! -r "$_s" ]; then
          echo "klaffat-infra: cannot read $_s — is the agenix secret provisioned?" >&2
          exit 3
        fi
      done

      TF_VAR_hcloud_token="$(< "${secretPath "klaffat-hcloud-token"}")"
      TF_VAR_cloudflare_api_token="$(< "${secretPath "klaffat-cloudflare-api-token"}")"
      TF_VAR_state_passphrase="$(< "${secretPath "klaffat-state-passphrase"}")"
      AWS_ACCESS_KEY_ID="$(< "${secretPath "klaffat-aws-access-key-id"}")"
      AWS_SECRET_ACCESS_KEY="$(< "${secretPath "klaffat-aws-secret-access-key"}")"
      export TF_VAR_hcloud_token TF_VAR_cloudflare_api_token TF_VAR_state_passphrase
      export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
      export AWS_DEFAULT_REGION="${awsRegion}"

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

      # No post-apply snapshot step: S3 bucket versioning on
      # ${bucket} IS the state history, so every apply already leaves a
      # restorable prior version behind with nothing for this wrapper to
      # do (and nothing for it to get wrong on the way).
      exec tofu "$@"
    '';
  };

  klaffat-infra-install = pkgs.writeShellApplication {
    name = "klaffat-infra-install";
    runtimeInputs = [ pkgs.openssh pkgs.coreutils config.nix.package pkgs.git ];
    text = ''
      ${rootOnlyPreamble "klaffat-infra-install" "<ip>"}

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

  klaffat-publish = pkgs.writeShellApplication {
    name = "klaffat-publish";
    runtimeInputs = [ config.nix.package pkgs.awscli2 pkgs.git pkgs.coreutils ];
    text = ''
      ${rootOnlyPreamble "klaffat-publish" "[rev | --upload-signing-key]"}

      repo="${repoRoot}"

      # Every AWS call below (and `nix copy`'s S3 store) authenticates with
      # the laptop IAM user, read straight out of /run/agenix.
      awsCreds() {
        for _s in \
          "${secretPath "klaffat-aws-access-key-id"}" \
          "${secretPath "klaffat-aws-secret-access-key"}"; do
          if [ ! -r "$_s" ]; then
            echo "klaffat-publish: cannot read $_s — is the agenix secret provisioned?" >&2
            exit 3
          fi
        done
        AWS_ACCESS_KEY_ID="$(< "${secretPath "klaffat-aws-access-key-id"}")"
        AWS_SECRET_ACCESS_KEY="$(< "${secretPath "klaffat-aws-secret-access-key"}")"
        export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        export AWS_DEFAULT_REGION="${awsRegion}"
      }

      signingPublicKey() {
        nix --extra-experimental-features 'nix-command flakes' \
          key convert-secret-to-public < "${secretPath "klaffat-nix-signing-key"}"
      }

      if [ ! -r "${secretPath "klaffat-nix-signing-key"}" ]; then
        echo "klaffat-publish: cannot read ${secretPath "klaffat-nix-signing-key"} — is the agenix secret provisioned?" >&2
        exit 3
      fi

      # --- --upload-signing-key: hand the SAME key to GitHub Actions.
      #
      # Terraform creates the Secrets Manager secret but deliberately never
      # holds its value (that would put the signing key in tofu state).
      # This mode is the one path that writes it, from the root-only agenix
      # copy, behind the same sudo password. `file://` makes awscli read the
      # value from the file rather than taking it on the command line, so
      # the key never appears in argv or in the process table.
      if [ "''${1-}" = "--upload-signing-key" ]; then
        if [ "$#" -ne 1 ]; then
          echo "klaffat-publish: --upload-signing-key takes no other arguments." >&2
          exit 2
        fi
        awsCreds
        aws secretsmanager put-secret-value \
          --secret-id "${signingKeySecretId}" \
          --secret-string "file://${secretPath "klaffat-nix-signing-key"}" \
          --output text --query VersionId
        echo
        echo "klaffat-publish: signing key uploaded to Secrets Manager ${signingKeySecretId} (${awsRegion})"
        printf '  public key: '
        signingPublicKey
        exit 0
      fi

      if [ "$#" -gt 1 ]; then
        echo "klaffat-publish: usage: sudo klaffat-publish [rev | --upload-signing-key]" >&2
        exit 2
      fi

      if [ ! -d "$repo" ]; then
        echo "klaffat-publish: no klaffat checkout at $repo — refusing." >&2
        echo "klaffat-publish: clone the klaffat repo to $repo first." >&2
        exit 2
      fi

      export GIT_OPTIONAL_LOCKS=0

      if ! git -C "$repo" -c safe.directory="$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "klaffat-publish: $repo is not a git worktree — refusing." >&2
        exit 2
      fi

      # A dirty tree means the founder has uncommitted work; publishing a
      # closure whose provenance is a commit that does not match what is on
      # disk is exactly the confusion this refuses to create.
      dirty="$(git -C "$repo" -c safe.directory="$repo" --no-optional-locks status --porcelain)"
      if [ -n "$dirty" ]; then
        echo "klaffat-publish: working tree at $repo is dirty — refusing." >&2
        printf '%s\n' "$dirty" >&2
        exit 2
      fi

      # Unlike klaffat-infra there is no "HEAD must be on main" check: the
      # commit to publish is chosen EXPLICITLY here (argument, else main's
      # tip), so whatever branch the founder happens to have checked out is
      # irrelevant and refusing on it would be noise.
      target="''${1-main}"
      if ! rev="$(git -C "$repo" -c safe.directory="$repo" rev-parse --verify "$target^{commit}" 2>/dev/null)"; then
        echo "klaffat-publish: '$target' is not a commit in $repo — refusing." >&2
        exit 2
      fi

      awsCreds

      # --- Build from a detached worktree under root-only state, never from
      #     the founder's tree.
      #
      #     `git worktree add` DOES write into $repo/.git/worktrees/, and as
      #     root that directory (and everything under it) is created
      #     root-owned — after which jonathan's own `git worktree add` fails
      #     with EACCES, the same class of breakage as root refreshing
      #     .git/index. So every path git creates there is chowned back to
      #     whoever owns $repo/.git, and the trap removes the dir entirely
      #     when it was ours to begin with. A SIGKILL mid-run can still
      #     leave an entry; `sudo git -C <repo> worktree prune` clears it.
      install -d -m 0700 "${stateDir}"
      work="${stateDir}/publish-$rev"
      rm -rf -- "$work"
      if ! git -C "$repo" -c safe.directory="$repo" worktree prune >/dev/null 2>&1; then
        echo "klaffat-publish: 'git worktree prune' failed in $repo — refusing." >&2
        exit 2
      fi

      # Anything git created under .git/worktrees goes back to the repo's
      # owner. Called after `worktree add` and again from the trap.
      unown() {
        if [ -d "$repo/.git/worktrees" ]; then
          chown -R --reference="$repo/.git" "$repo/.git/worktrees"
        fi
      }

      cleanup() {
        if ! git -C "$repo" -c safe.directory="$repo" \
             worktree remove --force "$work" >/dev/null 2>&1; then
          echo "klaffat-publish: could not remove the temporary worktree $work" >&2
        fi
        if ! git -C "$repo" -c safe.directory="$repo" worktree prune >/dev/null 2>&1; then
          echo "klaffat-publish: run 'sudo git -C $repo worktree prune' to clear leftovers" >&2
        fi
        rm -rf -- "$work"
        # rmdir only succeeds when we were the reason the dir existed; if the
        # founder has worktrees of his own it stays, chowned back to him.
        if [ -d "$repo/.git/worktrees" ] && ! rmdir "$repo/.git/worktrees" 2>/dev/null; then
          unown
        fi
      }
      trap cleanup EXIT

      git -C "$repo" -c safe.directory="$repo" worktree add --detach "$work" "$rev" >/dev/null
      unown
      echo "klaffat-publish: building klaffat-demo from $rev" >&2

      out="$(nix --extra-experimental-features 'nix-command flakes' build \
        --no-link --print-out-paths \
        "$work#nixosConfigurations.klaffat-demo.config.system.build.toplevel")"
      echo "klaffat-publish: built $out" >&2

      # --- Sign the whole closure with the root-only key. `nix store sign`
      #     reads the key client-side, so /run/agenix stays 0400 root.
      nix --extra-experimental-features 'nix-command flakes' store sign \
        --key-file "${secretPath "klaffat-nix-signing-key"}" \
        --recursive "$out"
      echo "klaffat-publish: signed closure of $out" >&2

      # --- Push to the S3-backed binary cache.
      #
      # Nix's S3 store takes its settings as URL QUERY PARAMETERS; `region`
      # is the documented one (verified against `nix help-stores` on nix
      # 2.34, which lists region/endpoint/scheme/addressing-style/profile).
      # Credentials come from the standard AWS env vars set by awsCreds.
      nix --extra-experimental-features 'nix-command flakes' copy \
        --to '${cacheUrl}' "$out"

      echo
      echo "klaffat-publish: published"
      echo "  revision:   $rev"
      echo "  store path: $out"
      echo "  cache:      ${cacheUrl}"
      printf '  public key: '
      signingPublicKey
      echo
      echo "  Put that public key in the klaffat host's nix.settings.trusted-public-keys."
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
    "${klaffat-publish}/bin/klaffat-publish"
    "/run/current-system/sw/bin/klaffat-infra"
    "/run/current-system/sw/bin/klaffat-infra-install"
    "/run/current-system/sw/bin/klaffat-publish"
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
      klaffat-demo-host-key = rootSecret ../../secrets/klaffat-demo-host-key.age;

      # One AWS identity for everything the laptop does: the IAM user
      # `klaffat-laptop` (state bucket RW, cache bucket RW, and IAM/OIDC/
      # SecretsManager admin for the Terraform-managed resources). The demo
      # host gets its OWN read-only user; that credential never lands here.
      klaffat-aws-access-key-id = rootSecret ../../secrets/klaffat-aws-access-key-id.age;
      klaffat-aws-secret-access-key = rootSecret ../../secrets/klaffat-aws-secret-access-key.age;

      # Nix binary-cache signing key — a real key, generated root-side
      # inside the encrypting pipeline and never written in the clear.
      klaffat-nix-signing-key = rootSecret ../../secrets/klaffat-nix-signing-key.age;
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
    environment.systemPackages = [ klaffat-infra klaffat-infra-install klaffat-publish ];

    # ── sudo ────────────────────────────────────────────────────────────
    # No NOPASSWD, no SETENV. Emitted after the sudo module's own wheel rule
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
