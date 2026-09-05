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
# encryption passphrase, the AWS credentials) must therefore NOT be
# decryptable by jonathan. Every other secret in this repo is rekey-
# managed and encrypted to jonathan's USER key (see
# modules/nixos/agenix-rekey-common.nix) — i.e. to exactly the principal
# the agent runs as. That is fine for API keys the agent is meant to
# use; it is wrong for credentials that can create and destroy servers.
#
# So the eight secrets below deliberately do NOT go through agenix-rekey.
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
# ── What "provenance" means here: root builds from ITS OWN mirror ─────
#
# The credentials above are spent on code, and which code is the whole
# question. Two earlier designs answered it by looking at the founder's
# checkout at /home/jonathan/Repos/klaffat, and both were reproduced as
# bypassable on 2026-09-05:
#
#   1. LOCAL facts — `git status --porcelain` empty and HEAD on a branch
#      named `main`. Both are things the `jonathan` user (the agent)
#      arranges for itself; an unsigned local commit passed and reached
#      `tofu` as uid 0 with every TF_VAR_* exported.
#   2. SERVER facts about the local tree — root asked GitHub for main's
#      tip, required HEAD to equal it, then ran `tofu` IN THE CHECKOUT.
#      The sha matched; the FILES did not have to. `git status` reports
#      neither a `*.tf` hidden through `.git/info/exclude` nor a tracked
#      one edited under `update-index --skip-worktree`, and OpenTofu reads
#      the directory, not the commit.
#
# The deeper problem is common to both, and to every "read the founder's
# repository more carefully" fix that could follow: ROOT RUNNING GIT
# INSIDE A REPOSITORY ANOTHER USER OWNS. `-c safe.directory=<repo>`
# re-enables exactly what git's dubious-ownership check (CVE-2022-24765)
# exists to stop — loading that repository's own configuration — and that
# configuration executes code. Measured with git 2.55.0, each trigger a
# jonathan-writable file, each command running as the invoking user:
#
#   - `core.fsmonitor` in .git/config runs on `git status`, even under
#     GIT_OPTIONAL_LOCKS=0. The previous gate's clean-tree check was a
#     root-exec primitive.
#   - `filter.<x>.smudge` in .git/config plus `* filter=x` in
#     .git/info/attributes runs on `git archive` AND on `git worktree
#     add`, and the extracted files are whatever it printed.
#   - `export-ignore` in .git/info/attributes silently drops files from
#     `git archive`.
#   - `.git/hooks/post-checkout` runs on `git worktree add` — the
#     previous klaffat-publish.
#
# So root no longer opens the founder's checkout AT ALL. It keeps its own
# bare mirror at ${mirrorDir} (0700 root), refreshed from
# `services.klaffatInfra.repoRemoteUrl` — a URL only root can change —
# with the read-only token below, on EVERY privileged run:
#
#   klaffat-infra          `git archive` of deploy/terraform at main's tip
#                          into a fresh 0700 directory, `tofu` runs there.
#                          Committed content only; nothing on disk in the
#                          founder's tree is ever read.
#   klaffat-publish        `nix build git+file://<mirror>?rev=<sha>#…` —
#                          the exact commit. No worktree, no hooks, no
#                          ownership bookkeeping in the founder's .git.
#   klaffat-infra-install  the same flakeref shape, handed to
#                          nixos-anywhere.
#
# Every git that runs as root now runs with ROOT's configuration against
# ROOT's repository. The mirror's `.gitattributes` and
# `.terraform.lock.hcl` are the committed, reviewed ones. What the founder
# has checked out is irrelevant to all three wrappers: each prints the sha
# it is about to use and where it came from, and an unpushed commit simply
# does not run. There is no `-c safe.directory` anywhere in this file, and
# the lane asserts there is not.
#
# The fetch fails CLOSED. A mirror that cannot be refreshed is not used —
# no fallback to whatever it held last time — so an offline laptop or a
# revoked token refuses rather than applying a stale `main`.
#
# NEXT STEP, not done here: verify the COMMIT SIGNATURE. "the tip of main
# on the server" is only as good as the branch protection in front of it;
# a signed-commit requirement would make the gate independent of GitHub's
# access control too. The founder has no signing key configured, and
# inventing one on his behalf would be worse than the gap, so this is
# deliberately left for a follow-up.
#
# ── The credential the mirror fetch needs ─────────────────────────────
#
# The klaffat repository is PRIVATE, so an anonymous fetch gets 401.
# `services.klaffatInfra.remoteTokenFile` names a root-only file holding a
# read-only GitHub token; by default that is the eighth agenix secret,
# `klaffat-github-token`, which ships as an encrypted `REPLACE_ME`
# placeholder until the founder edits the real token in (see
# secrets/secrets.nix). The token reaches git through a credential
# helper — never argv, which the process table exposes — and is only ever
# offered to the pinned URL. Until it is real the fetch fails and every
# wrapper refuses: fail-closed by construction, never a fallback to local
# refs it cannot trust.
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
# ── Which credentials each OpenTofu verb sees ─────────────────────────
#
# `console` is not offered. It evaluates any expression with the
# variables bound, and `nonsensitive(var.hcloud_token)` prints the token
# — `sensitive = true` is a display hint, not a boundary. Reproduced
# 2026-09-05 against the real wrapper.
#
# The verbs that remain get credentials by what they can DO, never by
# what they are called: the two provider tokens go only to verbs that
# instantiate providers (plan, apply, refresh, import, destroy); the AWS
# key pair and the state passphrase go to every verb that touches state;
# validate, fmt and version get nothing. What this does NOT close, and
# is documented rather than pretended away: `show`, `output -json` and
# `state pull` print whatever the STATE holds (the demo host's read-only
# IAM key, for instance). That is what the state is for, and reading it
# costs the same sudo password as `apply`.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.klaffatInfra;

  # Root-only state. Holds the bare mirror, TF_DATA_DIR and the per-run
  # archive directories. Nothing here is readable by jonathan, and nothing
  # the wrappers write lands anywhere else.
  stateDir = "/var/lib/klaffat-infra";
  dataDir = "${stateDir}/terraform.d";
  mirrorDir = "${stateDir}/klaffat.git";

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

  # The read-only GitHub credential for the mirror fetch, as a git
  # credential helper.
  #
  # A helper rather than `-c http.<url>.extraHeader=…` or a
  # GIT_CONFIG_VALUE_n export: the `-c` form puts the token in argv, where
  # anything that can read /proc sees it. Here argv carries only a store
  # path; the token itself is read inside the helper, by a child of the
  # root-only process, and never lands in a variable that outlives the
  # lookup.
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

  fetchHint =
    if cfg.remoteTokenFile == null
    then "that repository is private and services.klaffatInfra.remoteTokenFile is null"
    else "the fetch needs the network and a valid read-only token in ${cfg.remoteTokenFile}";

  # The provenance gate, as shell functions shared by all three wrappers.
  # See "What provenance means here" in the header. Every refusal exits 2.
  #
  # Everything here addresses the mirror by `--git-dir`, never by `-C`:
  # git never discovers a repository from the cwd (the caller's cwd is
  # jonathan's), and the explicit form keeps working under
  # `safe.bareRepository = explicit` should root's git ever carry it.
  mirrorLib = name: ''
    gate_refuse() {
      echo "${name}: $1" >&2
      exit 2
    }

    # Refresh root's bare mirror of the pinned remote, or refuse. Every
    # branch head, pruned — so an explicit `klaffat-publish <rev>` can
    # name any commit the server has, and nothing the server does not.
    mirror_sync() {
      install -d -m 0700 "${stateDir}"
      if [ ! -d "${mirrorDir}" ]; then
        git init -q --bare "${mirrorDir}"
        chmod 0700 "${mirrorDir}"
        # nix resolves a flakeref through the repository's HEAD; root's
        # `git init` may leave that on an unborn `master`.
        git --git-dir="${mirrorDir}" symbolic-ref HEAD refs/heads/main
      fi
      # `-c credential.helper=` first EMPTIES the helper list, so the one
      # appended after it is the only helper that runs.
      if ! (
        cd "${stateDir}"
        export GIT_TERMINAL_PROMPT=0
        git --git-dir="${mirrorDir}" -c credential.helper= ${credentialArg}fetch --quiet --prune \
          "${cfg.repoRemoteUrl}" '+refs/heads/*:refs/heads/*'
      ); then
        echo "${name}: (${fetchHint})" >&2
        gate_refuse "could not fetch ${cfg.repoRemoteUrl} into the root-only mirror — refusing."
      fi
    }

    # main's tip in the mirror just refreshed, on stdout.
    mirror_main_tip() {
      local tip
      if ! tip="$(git --git-dir="${mirrorDir}" rev-parse --verify --quiet 'refs/heads/main^{commit}')"; then
        gate_refuse "${cfg.repoRemoteUrl} has no main branch — refusing."
      fi
      printf '%s\n' "$tip"
    }
  '';

  klaffat-infra = pkgs.writeShellApplication {
    name = "klaffat-infra";
    runtimeInputs = [ pkgs.opentofu pkgs.git pkgs.coreutils pkgs.gnutar ];
    text = ''
      ${rootOnlyPreamble "klaffat-infra" "<tofu subcommand> [args...]"}
      ${mirrorLib "klaffat-infra"}

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
        init|validate|fmt|plan|apply|refresh|show|output|providers|state|version|graph|import|taint|untaint|force-unlock|workspace|destroy)
          ;;
        "")
          echo "klaffat-infra: usage: sudo klaffat-infra <tofu subcommand> [args...]" >&2
          exit 2
          ;;
        console)
          echo "klaffat-infra: 'console' is not offered — it evaluates any expression with the provisioning credentials bound, and nonsensitive(var.hcloud_token) prints one. Refusing." >&2
          exit 2
          ;;
        *)
          echo "klaffat-infra: '$subcmd' is not an allowed OpenTofu subcommand — refusing." >&2
          echo "klaffat-infra: allowed: init validate fmt plan apply refresh show output" >&2
          echo "klaffat-infra:          providers state version graph import taint untaint" >&2
          echo "klaffat-infra:          force-unlock workspace destroy" >&2
          exit 2
          ;;
      esac

      # Which credentials this verb gets — see "Which credentials each
      # OpenTofu verb sees" in the header. Decided by what the verb can
      # DO: only verbs that instantiate providers see the provider tokens;
      # only verbs that touch state see the state credentials.
      provider_creds=0
      state_creds=0
      case "$subcmd" in
        plan|apply|refresh|import|destroy)
          provider_creds=1
          state_creds=1
          ;;
        init|taint|untaint|force-unlock|show|output|state|graph|workspace|providers)
          state_creds=1
          ;;
        *)
          ;;
      esac

      # `apply -destroy` IS `destroy`; the flag has to count as one.
      # (`apply <saved-destroy-plan>` cannot be recognised from argv — the
      # plan file has to be read to know. `plan -out` + `apply <file>` is
      # not a path this wrapper offers a shortcut for, and the founder
      # who saved the plan is the one applying it. Note the working
      # directory is a fresh archive every run, so a plan file has to be
      # saved by ABSOLUTE path to survive to the next invocation.)
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

      # --- provenance: refresh root's mirror from the pinned remote and
      #     take main's tip from THERE. No local checkout is consulted, so
      #     there is nothing local to refuse on: see the module header.
      mirror_sync
      rev="$(mirror_main_tip)"
      echo "klaffat-infra: ${cfg.repoRemoteUrl} main @ $rev" >&2

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
          echo "klaffat-infra: at ${cfg.repoRemoteUrl} main @ $rev"
          printf "klaffat-infra: type exactly 'destroy klaffat' to proceed: "
        } >&3
        IFS= read -r _confirm <&3 || _confirm=""
        exec 3>&-
        if [ "$_confirm" != "destroy klaffat" ]; then
          gate_refuse "destroy not confirmed — refusing."
        fi
      fi

      # --- secrets: read from /run/agenix (0400 root) into this process
      #     only, and only the ones this verb is entitled to. Nothing is
      #     written back to disk and nothing is echoed.
      require_secret() {
        if [ ! -r "$1" ]; then
          echo "klaffat-infra: cannot read $1 — is the agenix secret provisioned?" >&2
          exit 3
        fi
      }
      if [ "$state_creds" -eq 1 ]; then
        require_secret "${secretPath "klaffat-state-passphrase"}"
        require_secret "${secretPath "klaffat-aws-access-key-id"}"
        require_secret "${secretPath "klaffat-aws-secret-access-key"}"
        TF_VAR_state_passphrase="$(< "${secretPath "klaffat-state-passphrase"}")"
        AWS_ACCESS_KEY_ID="$(< "${secretPath "klaffat-aws-access-key-id"}")"
        AWS_SECRET_ACCESS_KEY="$(< "${secretPath "klaffat-aws-secret-access-key"}")"
        export TF_VAR_state_passphrase AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
        export AWS_DEFAULT_REGION="${awsRegion}"
      fi
      if [ "$provider_creds" -eq 1 ]; then
        require_secret "${secretPath "klaffat-hcloud-token"}"
        require_secret "${secretPath "klaffat-cloudflare-api-token"}"
        TF_VAR_hcloud_token="$(< "${secretPath "klaffat-hcloud-token"}")"
        TF_VAR_cloudflare_api_token="$(< "${secretPath "klaffat-cloudflare-api-token"}")"
        export TF_VAR_hcloud_token TF_VAR_cloudflare_api_token
      fi

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

      # --- run against an ARCHIVE of the verified commit, in a fresh
      #     root-only directory that the trap removes. `git archive` from
      #     root's own mirror: committed content only, root's own
      #     attributes and config, no hooks, no working-tree metadata. The
      #     committed .terraform.lock.hcl is what `init` verifies against;
      #     anything OpenTofu writes into the working directory (a
      #     re-locked lock file, a plan saved by relative path) dies with
      #     it, deliberately.
      work="$(mktemp -d "${stateDir}/infra-XXXXXXXX")"
      trap 'rm -rf -- "$work"' EXIT
      if ! git --git-dir="${mirrorDir}" archive --format=tar "$rev" -- deploy/terraform \
           | tar -x -C "$work"; then
        gate_refuse "commit $rev has no deploy/terraform to extract — refusing."
      fi
      cd "$work/deploy/terraform"

      # No post-apply snapshot step: S3 bucket versioning on
      # ${bucket} IS the state history, so every apply already leaves a
      # restorable prior version behind with nothing for this wrapper to
      # do (and nothing for it to get wrong on the way).
      #
      # No `exec`: the EXIT trap above must still fire to remove $work.
      rc=0
      tofu "$@" || rc=$?
      exit "$rc"
    '';
  };

  klaffat-infra-install = pkgs.writeShellApplication {
    name = "klaffat-infra-install";
    runtimeInputs = [ pkgs.openssh pkgs.coreutils config.nix.package pkgs.git ];
    text = ''
      ${rootOnlyPreamble "klaffat-infra-install" "<ip>"}
      ${mirrorLib "klaffat-infra-install"}

      if [ "$#" -ne 1 ]; then
        echo "klaffat-infra-install: usage: sudo klaffat-infra-install <ip>" >&2
        exit 2
      fi
      ip="$1"

      # An IP ADDRESS, strictly. The first draft accepted any string of
      # hex digits, dots and colons, which admits `cafe.beef` and `dead` —
      # resolvable hostnames — and this wrapper hands the target the demo
      # host's private SSH key via --extra-files. So: a dotted quad whose
      # octets are ≤ 255, or an IPv6 literal (hex and colons only, at
      # least two colons, no dots — a hostname cannot contain a colon).
      ip_ok=0
      if [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        ip_ok=1
        for _o in "''${BASH_REMATCH[@]:1}"; do
          if (( 10#$_o > 255 )); then
            ip_ok=0
          fi
        done
      elif [[ "$ip" =~ ^[0-9a-fA-F:]+$ && "$ip" == *:*:* ]]; then
        ip_ok=1
      fi
      if [ "$ip_ok" -ne 1 ]; then
        echo "klaffat-infra-install: '$ip' is not an IP address — refusing." >&2
        exit 2
      fi

      # --- the SAME provenance gate as klaffat-infra: root's mirror,
      #     main's tip as the server has it. This wrapper is the more
      #     dangerous of the two — it hands root on a fresh server, plus
      #     the demo host's private SSH identity, to whatever it builds.
      mirror_sync
      rev="$(mirror_main_tip)"
      echo "klaffat-infra-install: ${cfg.repoRemoteUrl} main @ $rev" >&2

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

      # THE FLAKEREF NAMES THE COMMIT, IN ROOT'S MIRROR.
      #
      # A bare path flakeref builds the WORKING TREE, uncommitted edits
      # included (measured on nix 2.34.8), and a `git+file://` flakeref
      # into the founder's checkout would have root's nix run git inside
      # a repository jonathan configures. `git+file://<mirror>?rev=<sha>`
      # is neither: both the app AND the system being installed come out
      # of root's own repository at the commit the server called main.
      flakeref="git+file://${mirrorDir}?rev=$rev&allRefs=1"
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
      ${mirrorLib "klaffat-publish"}

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

      # --- which commit. The DEFAULT is main's tip AS THE SERVER REPORTS
      #     IT: the local `main` was once the default, and the agent writes
      #     that ref freely — `sudo klaffat-publish` with no argument would
      #     sign and push a closure nothing had reviewed while the host kept
      #     asking for a different one.
      #
      #     An explicit rev stays explicit — naming a commit is a
      #     deliberate act by the founder (bisecting a bad deploy,
      #     publishing a hotfix before it merges) — but it has to be a
      #     commit the SERVER has, on any branch. The mirror holds exactly
      #     those, so a purely local commit is refused rather than
      #     resolved.
      mirror_sync
      if [ "$#" -eq 1 ]; then
        target="$1"
        if ! rev="$(git --git-dir="${mirrorDir}" rev-parse --verify --quiet --end-of-options "$target^{commit}")"; then
          echo "klaffat-publish: '$target' is not a commit on any branch of ${cfg.repoRemoteUrl} — refusing." >&2
          echo "klaffat-publish: push it first; only what the server has can be published." >&2
          exit 2
        fi
      else
        rev="$(mirror_main_tip)"
      fi

      awsCreds

      # --- Build the exact commit out of root's mirror. `git+file://…?rev=`
      #     names the commit and nothing else: nothing is checked out (the
      #     previous design checked a worktree out of the founder's repo, and
      #     that ran the repo's post-checkout hook and smudge filters as
      #     root), and nothing is written into the founder's .git.
      echo "klaffat-publish: building klaffat-demo from $rev" >&2
      echo "klaffat-publish: source ${cfg.repoRemoteUrl}, via the root-only mirror ${mirrorDir}" >&2
      flakeref="git+file://${mirrorDir}?rev=$rev&allRefs=1"
      out="$(nix --extra-experimental-features 'nix-command flakes' build \
        --no-link --print-out-paths \
        "$flakeref#nixosConfigurations.klaffat-demo.config.system.build.toplevel")"
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
      default = "https://github.com/jonathanmoregard/klaffat.git";
      description = ''
        The one URL root fetches the klaffat repository from, into its own
        bare mirror, before every privileged run. `main`'s tip in that
        mirror is what the wrappers build and apply.

        This must be a value only root can change, which is the whole
        reason it is a module option: a gate that read `origin` out of the
        founder's `.git/config` would be asking the agent where to look for
        the agent's own homework.

        The repository was renamed from `kablong` to `klaffat` on
        2026-09-05 and this default changed in the same commit. Should it
        ever move again, change the two together — the wrappers refuse,
        loudly, when the fetch fails.
      '';
    };

    remoteTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = config.age.secrets.klaffat-github-token.path;
      defaultText = lib.literalExpression "config.age.secrets.klaffat-github-token.path";
      description = ''
        Root-only file holding a GitHub token with read access to
        `repoRemoteUrl`, offered by a credential helper when the mirror
        fetch is asked to authenticate.

        The default is the eighth host-key-encrypted agenix secret,
        `klaffat-github-token`, which ships as a `REPLACE_ME` placeholder
        the founder replaces with a fine-grained token (this repository,
        Contents: read-only, nothing else). The klaffat repository is
        private, so until then — and with `null` here — the fetch fails
        and every wrapper refuses. The gate is fail-closed by construction
        and never falls back to local refs it cannot trust.

        Read access only. The token proves nothing and authorises nothing
        in this design: it is transport credentials for a question ("what
        is main?") whose answer comes from GitHub over TLS at a URL root
        pinned above.
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

      # The read-only GitHub token the mirror fetch authenticates with. Ships
      # as an encrypted `REPLACE_ME` placeholder; the founder edits the real
      # token in from secrets/ with
      # `sudo agenix -i /etc/ssh/ssh_host_ed25519_key -e klaffat-github-token.age`.
      # Until then GitHub answers 401 and every wrapper refuses — the
      # declared-but-unwired shape this replaced refused forever with no
      # secret to fill.
      klaffat-github-token = rootSecret ../../secrets/klaffat-github-token.age;
    };

    # The host key is the only identity that decrypts the above. dellan
    # already defaults to this via services.openssh.hostKeys, but the
    # feature VM overrides identityPaths to jonathan's user key, and an
    # implicit dependency on that default is exactly the kind of thing
    # that silently starts decrypting under the wrong principal.
    age.identityPaths = lib.mkDefault [ "/etc/ssh/ssh_host_ed25519_key" ];

    # ── State dir ───────────────────────────────────────────────────────
    # The mirror under it is created by the first privileged run.
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
