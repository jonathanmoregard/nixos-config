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
# ── What "provenance" means here, and why a local check is not one ────
#
# The credentials above are spent on whatever code the checkout at
# ${repoRoot} holds. The first draft of this module decided that with two
# LOCAL facts: `git status --porcelain` is empty, and `git rev-parse
# --abbrev-ref HEAD` says `main`. Both are things the `jonathan` user —
# i.e. the agent — can arrange for itself. Reproduced 2026-09-05: an
# agent-authored, unsigned commit on a purely local `main`, with HEAD both
# ahead of and divergent from `origin/main`, passed the gate and reached
# `tofu` as uid 0 with every TF_VAR_* exported.
#
# `refs/remotes/origin/main` is no better: it is a file inside the
# jonathan-owned `.git`, and so is `origin`'s URL in `.git/config`.
#
# So the gate now asks the SERVER, as root:
#
#   1. `remote.origin.url` must equal `services.klaffatInfra.repoRemoteUrl`
#      — a value only root can change, so the next step cannot be pointed
#      at a repository the agent controls.
#   2. root runs `git ls-remote <that pinned URL> refs/heads/main` from
#      OUTSIDE the checkout (inside it, a `url.<evil>.insteadOf` line in
#      the jonathan-owned `.git/config` would redirect the lookup), and
#   3. HEAD must equal the sha the server just reported.
#
# `ls-remote` rather than `fetch`: it reaches the same authority and
# returns the same tip, but writes nothing — no objects, no FETCH_HEAD, no
# `refs/remotes/*` — into the founder's `.git`. Root creating paths there
# is a breakage this module already goes out of its way to avoid (see the
# `.git/index` note below), and the VM lane asserts it never happens.
#
# NEXT STEP, not done here: verify the COMMIT SIGNATURE. "the tip of main
# on the server" is only as good as the branch protection in front of it;
# a signed-commit requirement would make the gate independent of GitHub's
# access control too. The founder has no signing key configured, and
# inventing one on his behalf would be worse than the gap, so this is
# deliberately left for a follow-up.
#
# ── The credential the gate needs ─────────────────────────────────────
#
# The klaffat repository is PRIVATE, so an anonymous `ls-remote` gets
# nothing. `services.klaffatInfra.remoteTokenFile` points at a root-only
# file holding a read-only GitHub token; it is injected as an HTTP
# Authorization header through GIT_CONFIG_* environment variables (never
# argv, which the process table exposes). Until it is set the gate fails
# CLOSED — the wrapper refuses rather than falling back to the local
# facts it cannot trust. That is not a regression: ${repoRoot} does not
# exist yet either, so the wrapper already refuses everything.
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
  #
  # THE SPELLING IS LOAD-BEARING and must match, exactly, three things in
  # the klaffat repo: the `name` of `aws_secretsmanager_secret.nix_signing_key`
  # in deploy/terraform/aws.tf (which is the only thing that CREATES it),
  # the `--secret-id` in .github/workflows/publish.yml, and the agenix
  # secret name. It was `klaffat/nix-signing-key` here until 2026-09-05 —
  # a spelling nothing else used. Reproduced against an inert Secrets
  # Manager model: `put-secret-value` answered ResourceNotFoundException
  # and exited 254, because that call does NOT create a missing secret. So
  # the key never reached Actions, no closure was ever signed, and the demo
  # host — which only substitutes — could install nothing.
  signingKeySecretId = "klaffat-nix-signing-key";

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

  # The read-only GitHub credential for the ls-remote below, as a git
  # credential helper.
  #
  # A helper rather than `-c http.<url>.extraHeader=…` or a
  # GIT_CONFIG_VALUE_n export: the `-c` form puts the token in argv, where
  # anything that can read /proc sees it, and the env form collides with
  # the `safe.directory` GIT_CONFIG_* the install wrapper needs later.
  # Here argv carries only a store path; the token itself is read inside
  # the helper, by a child of the root-only process, and never lands in a
  # variable that outlives the lookup.
  #
  # git only runs this when the server answers 401, and only for the URL
  # it was asked about — which is the pinned one.
  remoteCredentialHelper =
    if cfg.remoteTokenFile == null then null
    else pkgs.writeShellScript "klaffat-git-credential" ''
      if [ ! -r "${cfg.remoteTokenFile}" ]; then
        echo "klaffat-git-credential: cannot read ${cfg.remoteTokenFile} (services.klaffatInfra.remoteTokenFile)" >&2
        exit 1
      fi
      printf 'username=x-access-token\npassword=%s\n' "$(${pkgs.coreutils}/bin/cat ${cfg.remoteTokenFile})"
    '';

  credentialArg =
    lib.optionalString (remoteCredentialHelper != null)
      "-c credential.helper=${remoteCredentialHelper} ";

  # The provenance gate, as shell functions shared by all three wrappers.
  # See "What provenance means here" in the header. Every refusal exits 2.
  #
  # `autoloads` is opt-in because writeShellApplication runs shellcheck,
  # and shellcheck fails the build on a function no caller invokes
  # (SC2329) — which is a fair complaint: dead code in a security gate
  # reads like a check that runs when it does not.
  provenanceLib = { name, autoloads ? false }: ''
    gate_refuse() {
      echo "${name}: $1" >&2
      exit 2
    }

    gate_require_worktree() {
      if ! git -C "$1" -c safe.directory="$1" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        gate_refuse "$1 is not a git worktree — refusing."
      fi
    }

    gate_require_clean() {
      local dirty
      dirty="$(git -C "$1" -c safe.directory="$1" --no-optional-locks status --porcelain)"
      if [ -n "$dirty" ]; then
        printf '%s\n' "$dirty" >&2
        gate_refuse "working tree at $1 is dirty — refusing."
      fi
    }

    ${lib.optionalString autoloads ''
      # OpenTofu AUTO-LOADS override files and variable files from its
      # working directory, so an untracked `override.tf` silently replaces
      # resource blocks in a tree `git status --porcelain` calls clean —
      # porcelain does not report ignored files, and `.gitignore` is itself
      # jonathan-writable. Anything matching those names has to be part of
      # the reviewed commit or the run is refused.
      gate_require_no_stray_autoloads() {
        local repo="$1" tfdir="$2" f
        [ -d "$tfdir" ] || return 0
        # `[ -e ]` and not just nullglob: nullglob only drops words that
        # CONTAIN a wildcard, so the two literal `override.tf` spellings
        # below survive it and would be tested whether they exist or not.
        # Caught by re-running the U1 repro against this very gate, which
        # refused a checkout that had no override.tf at all.
        shopt -s nullglob
        for f in \
          "$tfdir"/override.tf "$tfdir"/override.tf.json \
          "$tfdir"/*_override.tf "$tfdir"/*_override.tf.json \
          "$tfdir"/*.tfvars "$tfdir"/*.tfvars.json; do
          [ -e "$f" ] || continue
          if ! git -C "$repo" -c safe.directory="$repo" \
               ls-files --error-unmatch -- "$f" >/dev/null 2>&1; then
            gate_refuse "$f is not tracked, and OpenTofu auto-loads it — refusing."
          fi
        done
        shopt -u nullglob
      }
    ''}
    gate_require_origin_url() {
      local url
      url="$(git -C "$1" -c safe.directory="$1" config --get remote.origin.url || true)"
      if [ "$url" != "${cfg.repoRemoteUrl}" ]; then
        echo "${name}:   origin  = ''${url:-<unset>}" >&2
        echo "${name}:   expected= ${cfg.repoRemoteUrl}" >&2
        gate_refuse "$1 does not point at the pinned remote — refusing."
      fi
    }

    # main's tip AS THE SERVER REPORTS IT, printed on stdout.
    gate_remote_main_tip() {
      local out tip sha ref
      # `cd` out of the checkout first: run this inside it and git reads
      # the jonathan-owned .git/config, where one `url.<evil>.insteadOf`
      # line would redirect the very lookup that is supposed to be
      # authoritative. ${stateDir} is root-only and is not a work tree.
      install -d -m 0700 "${stateDir}"
      if ! out="$(
        cd "${stateDir}"
        export GIT_TERMINAL_PROMPT=0
        git ${credentialArg}ls-remote "${cfg.repoRemoteUrl}" refs/heads/main
      )"; then
        gate_refuse "could not ask ${cfg.repoRemoteUrl} for main's tip${
          lib.optionalString (cfg.remoteTokenFile == null)
            " (that repository is private and services.klaffatInfra.remoteTokenFile is not set)"
        } — refusing."
      fi
      tip=""
      while read -r sha ref; do
        if [ "$ref" = "refs/heads/main" ]; then tip="$sha"; fi
      done <<< "$out"
      if [ -z "$tip" ]; then
        gate_refuse "${cfg.repoRemoteUrl} reports no refs/heads/main — refusing."
      fi
      printf '%s\n' "$tip"
    }
  '';

  klaffat-infra = pkgs.writeShellApplication {
    name = "klaffat-infra";
    runtimeInputs = [ pkgs.opentofu pkgs.git pkgs.coreutils ];
    text = ''
      ${rootOnlyPreamble "klaffat-infra" "<tofu subcommand> [args...]"}
      ${provenanceLib { name = "klaffat-infra"; autoloads = true; }}

      repo="${repoRoot}"
      tfdir="${tfDir}"

      # --- argv first, before anything expensive or credentialed.
      #
      # `exec tofu "$@"` used to pass ANY subcommand through. sudo's
      # password prompt names the wrapper, never the subcommand, so
      # `sudo klaffat-infra destroy` and `sudo klaffat-infra plan` are
      # indistinguishable to the founder at the moment he types the
      # password — and `tofu destroy` reads its own approval from STDIN,
      # so `yes | sudo klaffat-infra destroy` needs exactly one password
      # and takes the whole stack down.
      #
      # So: an explicit allowlist, and destruction confirmed at the
      # TERMINAL, which no pipe can supply.
      subcmd="''${1-}"
      case "$subcmd" in
        init|validate|fmt|plan|apply|refresh|show|output|providers|state|version|graph|console|import|taint|untaint|force-unlock|workspace|destroy)
          ;;
        "")
          echo "klaffat-infra: usage: sudo klaffat-infra <tofu subcommand> [args...]" >&2
          exit 2
          ;;
        *)
          echo "klaffat-infra: '$subcmd' is not an allowed OpenTofu subcommand — refusing." >&2
          echo "klaffat-infra: allowed: init validate fmt plan apply refresh show output" >&2
          echo "klaffat-infra:          providers state version graph console import taint" >&2
          echo "klaffat-infra:          untaint force-unlock workspace destroy" >&2
          exit 2
          ;;
      esac

      # `apply -destroy` IS `destroy`; the flag has to count as one.
      # (`apply <saved-destroy-plan>` cannot be recognised from argv — the
      # plan file has to be read to know. `plan -out` + `apply <file>` is
      # not a path this wrapper offers a shortcut for, and the founder
      # who saved the plan is the one applying it.)
      destroying=0
      if [ "$subcmd" = "destroy" ]; then
        destroying=1
      fi
      for _a in "$@"; do
        case "$_a" in
          -destroy|--destroy|-destroy=true|--destroy=true) destroying=1 ;;
          *) ;;
        esac
      done

      # --- preflight: the checkout must exist, be a clean git worktree,
      #     on main, and at the tip main has ON THE SERVER. No override:
      #     see the module header.
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

      gate_require_worktree "$repo"
      gate_require_clean "$repo"
      gate_require_no_stray_autoloads "$repo" "$tfdir"

      branch="$(git -C "$repo" -c safe.directory="$repo" rev-parse --abbrev-ref HEAD)"
      if [ "$branch" != "main" ]; then
        gate_refuse "HEAD is on '$branch', not 'main' — refusing."
      fi

      # The two checks that make the three above mean something: the
      # remote is the one root pinned, and HEAD is what that remote says
      # main is. Everything before this point is a fact the agent can
      # manufacture locally.
      gate_require_origin_url "$repo"
      tip="$(gate_remote_main_tip)"

      rev="$(git -C "$repo" -c safe.directory="$repo" rev-parse HEAD)"
      if [ "$rev" != "$tip" ]; then
        echo "klaffat-infra:   HEAD           = $rev" >&2
        echo "klaffat-infra:   ${cfg.repoRemoteUrl} main = $tip" >&2
        gate_refuse "HEAD is not the tip of main on the remote — refusing."
      fi
      echo "klaffat-infra: $repo @ $rev (branch $branch, = ${cfg.repoRemoteUrl} main)" >&2

      # --- destruction needs a second, deliberate gesture.
      #
      # Read from /dev/tty, NOT stdin: `yes | sudo klaffat-infra destroy`
      # feeds stdin, and the whole point is that a pipe cannot answer
      # this. No controlling terminal means no confirmation is possible,
      # so the run is refused.
      if [ "$destroying" -eq 1 ]; then
        if ! { exec 3<>/dev/tty; } 2>/dev/null; then
          gate_refuse "'$subcmd' destroys the Klaffat stack and there is no terminal to confirm at — refusing."
        fi
        {
          echo
          echo "klaffat-infra: '$subcmd' DESTROYS the Klaffat demo stack (servers, DNS, state)."
          echo "klaffat-infra: at $repo @ $rev"
          printf "klaffat-infra: type exactly 'destroy klaffat' to proceed: "
        } >&3
        IFS= read -r _confirm <&3 || _confirm=""
        exec 3>&-
        if [ "$_confirm" != "destroy klaffat" ]; then
          gate_refuse "destroy not confirmed — refusing."
        fi
      fi

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
      ${provenanceLib { name = "klaffat-infra-install"; }}

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

      repo="${repoRoot}"
      if [ ! -d "$repo" ]; then
        echo "klaffat-infra-install: no klaffat checkout at $repo — refusing." >&2
        exit 2
      fi

      # --- the SAME provenance gate as klaffat-infra.
      #
      # This wrapper had none at all: it made exactly one git call
      # (`safe.directory`) and then handed root on a fresh server, plus
      # the demo host's private SSH identity, to whatever the checkout
      # happened to contain. It is the more dangerous of the two — the
      # OpenTofu wrapper at least stops at a plan.
      #
      # (No stray-autoload check here: `override.tf` / `*.tfvars` are an
      # OpenTofu working-directory concern, and this wrapper never runs
      # OpenTofu. The nix flakeref below is pinned to a rev instead.)
      export GIT_OPTIONAL_LOCKS=0
      gate_require_worktree "$repo"
      gate_require_clean "$repo"
      branch="$(git -C "$repo" -c safe.directory="$repo" rev-parse --abbrev-ref HEAD)"
      if [ "$branch" != "main" ]; then
        gate_refuse "HEAD is on '$branch', not 'main' — refusing."
      fi
      gate_require_origin_url "$repo"
      tip="$(gate_remote_main_tip)"
      rev="$(git -C "$repo" -c safe.directory="$repo" rev-parse HEAD)"
      if [ "$rev" != "$tip" ]; then
        echo "klaffat-infra-install:   HEAD           = $rev" >&2
        echo "klaffat-infra-install:   ${cfg.repoRemoteUrl} main = $tip" >&2
        gate_refuse "HEAD is not the tip of main on the remote — refusing."
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
      export GIT_CONFIG_VALUE_0="$repo"

      # A BARE PATH FLAKEREF BUILDS THE WORKING TREE, NOT THE COMMIT.
      #
      # `nix run /path#attr` copies the tracked files as they are ON DISK,
      # uncommitted edits included — measured on nix 2.34.8: editing a
      # tracked file without committing changed what `nix run <path>#…`
      # built, while `git+file://<dir>?rev=<sha>` kept building the commit.
      # The clean-tree check above narrows that window but does not close
      # it (git can call a tree clean that the flake still reads
      # differently — skip-worktree, assume-unchanged, a racy mtime), and
      # a gate that is only correct because a second gate held is not one.
      #
      # So both the app AND the system being installed are addressed by
      # the verified rev. root can only ever build a committed object that
      # the server agreed is main.
      flakeref="git+file://$repo?rev=$rev"
      echo "klaffat-infra-install: installing klaffat-demo onto root@$ip" >&2
      echo "klaffat-infra-install: flakeref $flakeref" >&2
      # No `exec`: the EXIT trap above must still fire to shred $EXTRA.
      rc=0
      nix run "$flakeref#nixos-anywhere" -- \
        --extra-files "$EXTRA" \
        --flake "$flakeref#klaffat-demo" \
        "root@$ip" || rc=$?
      exit "$rc"
    '';
  };

  klaffat-publish = pkgs.writeShellApplication {
    name = "klaffat-publish";
    runtimeInputs = [ config.nix.package pkgs.awscli2 pkgs.git pkgs.coreutils ];
    text = ''
      ${rootOnlyPreamble "klaffat-publish" "[rev | --upload-signing-key]"}
      ${provenanceLib { name = "klaffat-publish"; }}

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

      gate_require_worktree "$repo"

      # A dirty tree means the founder has uncommitted work; publishing a
      # closure whose provenance is a commit that does not match what is on
      # disk is exactly the confusion this refuses to create.
      gate_require_clean "$repo"

      # Unlike klaffat-infra there is no "HEAD must be on main" check: the
      # commit to publish is chosen EXPLICITLY here (argument, else main's
      # tip), so whatever branch the founder happens to have checked out is
      # irrelevant and refusing on it would be noise.
      #
      # The DEFAULT, though, used to be the LOCAL `main` — the same ref
      # klaffat-infra's gate could be walked past, and one the agent
      # writes freely. `sudo klaffat-publish` with no argument would then
      # sign and push a closure nothing had reviewed, while the host kept
      # asking for a different one and the deploy kept failing. So the
      # default is now main's tip AS THE SERVER REPORTS IT, under the same
      # pinned-URL rule as klaffat-infra.
      #
      # An explicit rev stays explicit: naming a commit is a deliberate
      # act by the founder (bisecting a bad deploy, publishing a hotfix
      # before it merges), and it is not the silent default that made this
      # a defect.
      if [ "$#" -eq 1 ]; then
        target="$1"
      else
        gate_require_origin_url "$repo"
        target="$(gate_remote_main_tip)"
      fi
      if ! rev="$(git -C "$repo" -c safe.directory="$repo" rev-parse --verify "$target^{commit}" 2>/dev/null)"; then
        echo "klaffat-publish: '$target' is not a commit in $repo — refusing." >&2
        if [ "$#" -ne 1 ]; then
          echo "klaffat-publish: that is ${cfg.repoRemoteUrl}'s main; run 'git -C $repo fetch origin main' first." >&2
        fi
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

      # A path flakeref, deliberately, and NOT the `git+file://…?rev=`
      # shape klaffat-infra-install had to adopt. That fix exists because
      # a path flakeref builds the WORKING TREE; here the working tree is
      # $work, which `git worktree add --detach … "$rev"` just created
      # from the verified commit inside a 0700 root-only directory. There
      # is no window in which it holds anything but $rev, and no
      # unprivileged process can open it.
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
  options.services.klaffatInfra = {
    enable = lib.mkEnableOption
      "the sudo-gated klaffat-infra OpenTofu wrapper and its root-only provisioning secrets";

    repoRemoteUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://github.com/jonathanmoregard/kablong.git";
      description = ''
        The one remote the klaffat checkout is allowed to have, and the
        only URL the wrappers will ask for `main`'s tip.

        This must be a value only root can change, which is the whole
        reason it is a module option: `origin`'s URL lives in
        `.git/config` inside the jonathan-owned checkout, so a gate that
        trusted `git remote get-url origin` would be asking the agent
        where to look for the agent's own homework.

        Still spelled `kablong` because that is what the GitHub repository
        is still called; only the local directory is being renamed to
        `klaffat`. Rename the repository and this default changes in the
        same commit — the wrappers compare the string and refuse a
        mismatch, loudly, printing both sides.
      '';
    };

    remoteTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "/run/agenix/klaffat-github-token";
      description = ''
        Root-only file holding a GitHub token with read access to
        `repoRemoteUrl`, used for one `git ls-remote` per privileged run.

        The klaffat repository is private, so with this unset the lookup
        goes out unauthenticated, fails, and every wrapper refuses — the
        gate is fail-closed by construction and never falls back to the
        local refs it cannot trust.

        Read access only. The token proves nothing and authorises
        nothing in this design: it is transport credentials for a
        question ("what is main's tip?") whose answer comes from GitHub
        over TLS at a URL root pinned above.
      '';
    };
  };

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
