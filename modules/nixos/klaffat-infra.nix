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
#   klaffat-infra          `git archive` of deploy/ at main's tip into a
#                          fresh 0700 directory — the whole deploy tree,
#                          because hetzner.tf reads ../cloudflare-ips.json
#                          (measured: archiving deploy/terraform alone made
#                          every plan die on that file) — verified entry by
#                          entry against the commit (regular files only, blob
#                          shas equal) before `tofu` runs in deploy/terraform.
#                          Committed content only; nothing on disk in the
#                          founder's tree is ever read.
#
# That verification compares RAW BYTES to the blob, with
# `git hash-object --no-filters`. A committed `.gitattributes` is part of
# the reviewed tree, but it still gets a vote on what `git archive` writes
# to disk: `export-ignore` drops a file, `export-subst` and `ident`
# rewrite one, `text`/`eol` rewrite line endings, `filter` runs a smudge
# command. Measured with git 2.55.0 on 2026-09-06 in a scratch bare repo
# with `deploy/.gitattributes` = `* text=auto eol=crlf`: `git archive`
# wrote CRLF while the blob held LF, and hash-object — cwd in the
# extracted tree, `--git-dir` on the bare mirror — applied no inverse
# conversion (identical shas with and without `--no-filters`), so the
# refusal fired. `--no-filters` makes that independent of what a future
# git decides the cwd is, rather than a property observed once. The real
# klaffat tree has NO .gitattributes (checked the same day:
# `git ls-files | grep -i gitattributes` is empty), so this refuses
# nothing that exists today.
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
# `fmt` is not offered either: it rewrites files in a working directory
# this wrapper deletes on exit, so it would report changes and discard
# them. Formatting belongs in the dev shell, committed like any edit.
#
# The verbs that remain get credentials by what they can DO, never by
# what they are called: the two provider tokens go only to verbs that
# instantiate providers (plan, apply, refresh, import, destroy); the AWS
# key pair and the state passphrase go to every verb that touches state;
# validate and version get nothing. What this does NOT close, and is
# documented rather than pretended away: `show`, `output -json` and
# `state pull` print whatever the STATE holds (the demo host's read-only
# IAM key, for instance). That is what the state is for, and reading it
# costs the same sudo password as `apply`.
#
# `destroy` and `apply -destroy` are confirmed at /dev/tty. The destroy
# flag is recognised by PREFIX — any `-destroy…` or `--destroy…` argument
# counts — because OpenTofu parses booleans with Go's strconv.ParseBool,
# which also accepts `1`, `t`, `T`, `True` and `TRUE`; a list of spellings
# is exactly the kind of gate that leaks (`apply -destroy=1` walked past
# the first one). `-destroy=false` therefore asks for confirmation too,
# which costs a phrase and nothing else.
#
# ── What ARGUMENTS reach OpenTofu: an allowlist, per verb ─────────────
#
# The verb was the only word this wrapper used to read. Everything after
# it went to root's `tofu` unexamined, which made argv a second, unguarded
# input channel into the same credentialed process — reproduced 2026-09-06
# against the real generated wrapper:
#
#   - `plan -var github_repo=attacker/x` and
#     `-var-file=<a file the founder's user can write>` both override the
#     value the committed `demo.auto.tfvars` authored, and
#     `apply -auto-approve -var …` commits it. In the real klaffat tree
#     `github_repo` is the `sub` claim of the OIDC role allowed to read
#     the NAR signing key (deploy/terraform/aws.tf), i.e. the key that
#     decides what the demo host installs and runs as root.
#   - `state push <a founder-writable file>` is READ by root's tofu and
#     written over the encrypted remote state.
#   - `init -plugin-dir=<a founder-writable dir>` makes that directory the
#     ONLY place root's tofu looks for provider binaries, and
#     `init -from-module=<dir>` copies configuration from outside the
#     verified commit into the working directory.
#
# So argv after the verb is ALLOWLISTED, per verb, token by token, in the
# same place the verb is checked: before the mirror is fetched and before
# a single secret is read. Not a deny-list — round 6 watched `-destroy=1`
# walk past four literal spellings of one flag, and a list of bad
# spellings is only ever as long as the last review. Value flags are taken
# only in the one-token `-name=value` form (a value in its own argument
# cannot be checked against its flag), `--` is refused, and the only path
# a caller may name at all is a saved plan under ${plansDir} — one
# root-only directory, one name segment, no subdirectories (see "Where
# plan files live" below).
#
# What the allowlist leaves out is what the design never needed:
# variables come from the committed `*.auto.tfvars` and from the `TF_VAR_*`
# this wrapper exports out of /run/agenix; providers come from the
# committed `.terraform.lock.hcl`; state comes from the committed backend.
# `-var`, `-var-file`, `-plugin-dir`, `-from-module`, `-backend-config`,
# `-state`/`-state-out`/`-backup`, `-chdir`, `state push`,
# `state replace-provider`, `workspace new`/`delete` and `providers mirror`
# are therefore refused by construction, not by name-matching.
#
# `TF_CLI_ARGS` and `TF_CLI_ARGS_<verb>` cannot be used to smuggle flags
# past the allowlist: sudo's `env_reset` drops the caller's environment
# (the rules below carry no SETENV and keep only SSH_AUTH_SOCK, for the
# install command), and rootOnlyPreamble unsets every `TF_*` and `AWS_*`
# anyway, for the direct-root case too.
#
# ── Where plan files live, and what that closes ───────────────────────
#
# CLOSED as of round 8: the write-what-where and the read-what-where that
# `-out=`, `apply <path>` and `show <path>` used to be. Their shape was
# `[[ "$2" == /* ]]` — a leading slash and nothing more — so any absolute
# path the founder (or an agent holding one sudo password) typed was
# opened by root's tofu. Reproduced 2026-09-06 against the real generated
# wrapper: `plan -out=/etc/ssh/ssh_host_ed25519_key` exited 0 having
# replaced a 35-byte canary file with a 1526-byte plan zip, and
# `-out=/run/agenix/klaffat-cloudflare-api-token` replaced the wrapper's
# OWN secret the same way; `apply <file>` and `show <file>` opened
# whatever root could read (tofu's parser rejected a non-plan file without
# echoing it, but the open happened either way).
#
# Now those three values must match ${plansDir}/<name> — one root-only
# 0700 directory, one name segment starting with a letter, digit, `_` or
# `-`, continuing with those plus `.`. That refuses `..`, `.`, dotfiles, a
# further `/` (no subdirectories), a trailing `/`, whitespace, and every
# path outside the directory. The check is deliberately LEXICAL, with no
# realpath and no stat: the directory is root-only, so a symlink inside it
# could only have been planted by root, and a filesystem lookup at check
# time would just be a second thing to get wrong. Root writes and reads
# plan files nowhere else.
#
# THE RESIDUAL that remains, documented rather than pretended away:
#
#   1. `apply <plan>` still applies a plan file this wrapper cannot
#      inspect from argv. It can only ever be a plan ROOT ITSELF wrote:
#      plans are encrypted with the state passphrase (klaffat
#      deploy/terraform/versions.tf, `plan { enforced = true }`), which
#      lives in /run/agenix at 0400 root, so the founder cannot forge one
#      — but a saved DESTROY plan applies with neither the `destroy
#      klaffat` phrase nor OpenTofu's own approval prompt. The founder who
#      saved the plan is the founder applying it. Closing this means
#      reading the plan file, which is a bigger change than this round
#      takes on.
#   2. The wrapper never empties ${plansDir}. Plan files accumulate there
#      at 0600 root:root until the founder removes them. Deliberately no
#      cleanup here: a wrapper that deleted files by age or count would be
#      a second, unreviewed destructive path running under the same sudo
#      password, and `rm` is the founder's to type.
#
# ── The install wrapper's ssh identity ────────────────────────────────
#
# nixos-anywhere has to ssh to the fresh box as root, and root on the
# laptop has no key of its own: the server's authorized key is the
# founder's (`founder_public_key` in variables.tf). So the sudo rule for
# klaffat-infra-install — and ONLY that rule — keeps SSH_AUTH_SOCK, and
# root's ssh signs with whatever the founder has loaded in ssh-agent
# (`ssh-add ~/.ssh/klaffat-deploy`). This grants nothing new: a process
# running as the founder can already use that agent. It is scoped to the
# one command that needs it; the OpenTofu and publish wrappers run under
# a plain env_reset.
#
# "ONLY that rule" is a claim about the WHOLE sudoers file, not just the
# lines this module writes, and nixpkgs has a global
# `env_keep+=SSH_AUTH_SOCK` of its own — emitted by
# `security.pam.sshAgentAuth`, which dellan does not enable. Enabling it
# anywhere would widen the variable to every sudo command on the laptop
# and this header would quietly become false, so the lane no longer greps
# for the command-scoped line: it collects EVERY sudoers line containing
# both `env_keep` and `SSH_AUTH_SOCK` and asserts the list is exactly the
# one line below.
#
# ── The install wrapper's target is confirmed at the terminal ─────────
#
# klaffat-infra-install stages the demo host's PRIVATE ssh identity into
# an --extra-files directory and hands it, together with root on a fresh
# machine, to whatever answers at the address in argv. The IP validation
# proves the argument is an address; nothing can prove it is the RIGHT
# address. So the founder retypes it: after the mirror is refreshed and
# before the host key is read, the wrapper prints `root@<ip>`, the
# revision and the flakeref to /dev/tty and requires the literal phrase
# `install <ip>` back. Same mechanism as `destroy klaffat`, same reason —
# a pipe cannot answer /dev/tty, and no controlling terminal means the run
# is refused rather than confirmed by default. Nothing is read or staged
# before the answer, so a refusal leaves no key anywhere.
{ config, lib, pkgs, ... }:

let
  cfg = config.services.klaffatInfra;

  # Root-only state. Holds the bare mirror, TF_DATA_DIR and the per-run
  # archive directories. Nothing here is readable by jonathan, and nothing
  # the wrappers write lands anywhere else.
  stateDir = "/var/lib/klaffat-infra";
  dataDir = "${stateDir}/terraform.d";
  mirrorDir = "${stateDir}/klaffat.git";

  # THE ONLY DIRECTORY ROOT WRITES OR READS A PLAN FILE IN. 0700 root, so
  # nothing jonathan can write is reachable through it, and — because the
  # `PLAN` shape below is the literal prefix plus a single name segment —
  # `-out=`, `apply <plan>` and `show <plan>` cannot name anything else.
  # Round 8 measured what the previous shape (leading slash only) allowed:
  # `plan -out=/etc/ssh/ssh_host_ed25519_key` had root's tofu open that
  # path O_TRUNC and replace it with a 1526-byte plan zip, and the
  # wrapper's own /run/agenix secret went the same way.
  plansDir = "${stateDir}/plans";

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
    runtimeInputs = [ pkgs.opentofu pkgs.git pkgs.coreutils pkgs.gnutar pkgs.gawk ];
    text = ''
      ${rootOnlyPreamble "klaffat-infra" "<tofu subcommand> [allowed args...]"}
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
        init|validate|plan|apply|refresh|show|output|providers|state|version|graph|import|taint|untaint|force-unlock|workspace|destroy)
          ;;
        "")
          echo "klaffat-infra: usage: sudo klaffat-infra <tofu subcommand> [allowed args...]" >&2
          exit 2
          ;;
        console)
          echo "klaffat-infra: 'console' is not offered — it evaluates any expression with the provisioning credentials bound, and nonsensitive(var.hcloud_token) prints one. Refusing." >&2
          exit 2
          ;;
        fmt)
          echo "klaffat-infra: 'fmt' is not offered — it rewrites files in a working directory this wrapper deletes on exit. Run 'tofu fmt' in the dev shell and commit the result. Refusing." >&2
          exit 2
          ;;
        *)
          echo "klaffat-infra: '$subcmd' is not an allowed OpenTofu subcommand — refusing." >&2
          echo "klaffat-infra: allowed: init validate plan apply refresh show output providers" >&2
          echo "klaffat-infra:          state version graph import taint untaint force-unlock" >&2
          echo "klaffat-infra:          workspace destroy" >&2
          echo "klaffat-infra: the arguments after the subcommand are allowlisted per verb too;" >&2
          echo "klaffat-infra: a refused one prints the forms that verb accepts." >&2
          exit 2
          ;;
      esac

      # --- argv AFTER the verb: an ALLOWLIST, per verb, token by token.
      #
      # `tofu "$@"` used to hand root's OpenTofu every argument after the
      # verb, unread. Reproduced 2026-09-06 against the real generated
      # wrapper: `plan -var github_repo=attacker/x` and
      # `-var-file=<a file the founder's user can write>` both override the
      # value the committed demo.auto.tfvars authored; `apply -auto-approve
      # -var …` commits it and removes the approval prompt in the same
      # breath; `state push <a founder-writable file>` is READ by root's
      # tofu; `init -plugin-dir=<a founder-writable dir>` becomes the ONLY
      # place root's tofu looks for provider binaries; and
      # `init -from-module=<dir>` copies code from outside the verified
      # commit into the working directory. In the real klaffat tree
      # `github_repo` is the `sub` claim of the OIDC role that may read the
      # NAR signing key, so one argv word repointed the trust policy of the
      # role that signs what the demo host installs as root.
      #
      # A DENY-list of spellings was not an option: round 6 watched
      # `-destroy=1` walk past four literal spellings of the same flag. So
      # every token is matched against what THIS verb may take, and anything
      # unrecognised refuses — here, BEFORE mirror_sync touches the network
      # and before a single secret is read, so a refusal costs nothing and
      # says nothing. ARGV refusals specifically — and no others — print no
      # `main @` line, because they are the only ones that run before
      # mirror_sync. Every refusal LATER in the run (destroy unconfirmed, a
      # symlink in the commit, an extracted tree that differs) prints the
      # provenance line first and then its own; see the
      # `-detailed-exitcode` note below for the rule that covers both.
      #
      # Value flags are accepted ONLY as one token, `-name=value`. A value
      # in its own argument (`-target ADDR`) cannot be checked against its
      # flag without re-implementing OpenTofu's parser, so it is refused
      # with a hint naming the `=` form. `--` is refused for the same
      # reason: nothing after it could be checked.
      #
      # TF_CLI_ARGS / TF_CLI_ARGS_<verb> cannot smuggle flags around this:
      # sudo's env_reset drops the caller's environment and the preamble
      # above unsets every TF_* anyway.
      #
      # `-detailed-exitcode` is allowed on `plan`, and it makes tofu exit 2
      # for "there are changes" — the same code every refusal uses. The rule
      # stated here until round 8 ("a refusal never prints the `main @`
      # line") was FALSE, and measured false on 2026-09-06: `plan -no-color
      # -destroy` with no controlling terminal printed
      # `<url> main @ <sha>` and THEN refused with exit 2, because the
      # provenance line is printed before the destroy confirmation, the
      # symlink check and the archive comparison. The true rule is about the
      # COUNT of `klaffat-infra:` lines, not the presence of one:
      #
      #   A successful run prints exactly one `klaffat-infra:` line — the
      #   provenance line `<url> main @ <sha>`. Every refusal prints at
      #   least one more `klaffat-infra:` line naming what was refused, and
      #   exits 2. So `plan -detailed-exitcode` exit 2 means "changes
      #   present" only when the provenance line is the ONLY
      #   `klaffat-infra:` line in the output; the presence of `main @`
      #   proves nothing by itself.
      #
      # The lane pins both halves: exactly one such line after a successful
      # plan, at least two (provenance included) after a refusal that
      # happens past mirror_sync.
      argv_bools=()
      argv_values=()
      argv_summary=""
      case "$subcmd" in
        init)
          argv_bools=(-upgrade -reconfigure -migrate-state -input=false -lockfile=readonly)
          argv_summary="-upgrade -reconfigure -migrate-state -input=false -lockfile=readonly; no operands"
          ;;
        validate)
          argv_bools=(-json)
          argv_summary="-json; no operands"
          ;;
        plan)
          argv_bools=(-input=false -refresh-only -refresh=false -compact-warnings -detailed-exitcode -json)
          argv_values=(-target:ADDR -replace:ADDR -parallelism:N -lock-timeout:DUR -out:PLAN)
          argv_summary="-input=false -refresh-only -refresh=false -compact-warnings -detailed-exitcode -json -destroy[=BOOL] -target=ADDR -replace=ADDR -parallelism=N -lock-timeout=DUR -out=${plansDir}/NAME; no operands"
          ;;
        apply)
          argv_bools=(-auto-approve -input=false -refresh-only -refresh=false -compact-warnings -json)
          argv_values=(-target:ADDR -replace:ADDR -parallelism:N -lock-timeout:DUR)
          argv_summary="-auto-approve -input=false -refresh-only -refresh=false -compact-warnings -json -destroy[=BOOL] -target=ADDR -replace=ADDR -parallelism=N -lock-timeout=DUR; at most one operand, a saved plan under ${plansDir}/"
          ;;
        refresh)
          argv_bools=(-input=false -compact-warnings)
          argv_values=(-target:ADDR -parallelism:N -lock-timeout:DUR)
          argv_summary="-input=false -compact-warnings -target=ADDR -parallelism=N -lock-timeout=DUR; no operands"
          ;;
        show)
          argv_bools=(-json)
          argv_summary="-json; at most one operand, a saved plan under ${plansDir}/"
          ;;
        output)
          argv_bools=(-json -raw)
          argv_summary="-json -raw; at most one operand, an output NAME"
          ;;
        providers)
          argv_summary="no flags; at most one operand, and only 'lock'"
          ;;
        state)
          argv_bools=(-dry-run)
          argv_values=(-lock-timeout:DUR)
          argv_summary="list [ADDR...] | show ADDR | pull | rm ADDR... | mv ADDR ADDR; -dry-run and -lock-timeout=DUR on rm/mv only"
          ;;
        version)
          argv_bools=(-json)
          argv_summary="-json; no operands"
          ;;
        graph)
          argv_bools=(-draw-cycles)
          argv_values=(-type:NAME)
          argv_summary="-draw-cycles -type=NAME; no operands"
          ;;
        import)
          argv_bools=(-input=false)
          argv_values=(-lock-timeout:DUR)
          argv_summary="-input=false -lock-timeout=DUR; exactly two operands, ADDR and ID"
          ;;
        taint|untaint)
          argv_values=(-lock-timeout:DUR)
          argv_summary="-lock-timeout=DUR; exactly one operand, ADDR"
          ;;
        force-unlock)
          argv_bools=(-force)
          argv_summary="-force; exactly one operand, the LOCK_ID"
          ;;
        workspace)
          argv_summary="no flags; list | show | select NAME"
          ;;
        destroy)
          argv_bools=(-auto-approve -input=false -compact-warnings)
          argv_values=(-target:ADDR -parallelism:N -lock-timeout:DUR)
          argv_summary="-auto-approve -input=false -compact-warnings -target=ADDR -parallelism=N -lock-timeout=DUR; no operands"
          ;;
        *)
          argv_summary="nothing"
          ;;
      esac

      # Refusals name the verb's own forms first, then — once — the classes
      # that are refused on EVERY verb, so the founder learns the rule
      # rather than the symptom.
      argv_refuse() {
        echo "klaffat-infra: $1" >&2
        echo "klaffat-infra: '$subcmd' accepts: $argv_summary" >&2
        echo "klaffat-infra: plus -help and -no-color, on every verb." >&2
        echo "klaffat-infra: refused on every verb, by design: -var, -var-file, -plugin-dir," >&2
        echo "klaffat-infra:   -backend-config, -backend=, -from-module, -state, -state-out," >&2
        echo "klaffat-infra:   -backup, -chdir, 'state push', 'state replace-provider'," >&2
        echo "klaffat-infra:   'workspace new|delete', 'providers mirror', '--', every path" >&2
        echo "klaffat-infra:   except a saved plan under ${plansDir}/ (relative ones included)," >&2
        echo "klaffat-infra:   and two-token value forms such as '-target ADDR'." >&2
        echo "klaffat-infra:   Every variable comes from the committed *.auto.tfvars and from the" >&2
        echo "klaffat-infra:   TF_VAR_* this wrapper exports out of /run/agenix; providers come" >&2
        echo "klaffat-infra:   from the committed .terraform.lock.hcl; state comes from the" >&2
        echo "klaffat-infra:   committed backend. Nothing outside the verified commit is read." >&2
        exit 2
      }

      # The value shapes the contract names. ADDR is a resource address
      # (`module.x.aws_instance.y["a"]`), so anything without whitespace.
      #
      # PLAN is the ONLY shape that admits a filesystem path, and it admits
      # exactly ${plansDir}/<name>: one root-only 0700 directory, one name
      # segment starting with a letter, digit, `_` or `-` and continuing
      # with those plus `.`. So `..`, `.`, dotfiles, a further `/`, a
      # trailing `/`, whitespace and everything outside the directory are
      # all refused by the same regex, with no realpath and no stat — see
      # "Where plan files live" in the header for why lexical is enough.
      # There is deliberately NO general `PATH` shape any more: the one it
      # replaced tested for a leading slash, and round 8 reproduced root's
      # tofu truncating /etc/ssh/ssh_host_ed25519_key through it. A shape
      # that does not exist cannot be reused by the next flag.
      argv_shape_ok() {
        case "$1" in
          ADDR) [[ "$2" =~ ^[^[:space:]]+$ ]] ;;
          N) [[ "$2" =~ ^[0-9]+$ ]] ;;
          DUR) [[ "$2" =~ ^[0-9]+(ms|s|m|h)$ ]] ;;
          NAME) [[ "$2" =~ ^[A-Za-z0-9_-]+$ ]] ;;
          LOCK_ID) [[ "$2" =~ ^[A-Za-z0-9-]+$ ]] ;;
          ID) [[ "$2" =~ ^[^-] ]] ;;
          PLAN) [[ "$2" =~ ^${plansDir}/[A-Za-z0-9_-][A-Za-z0-9._-]*$ ]] ;;
          *) false ;;
        esac
      }

      # Defined here, above the token loop, because BOTH users need it: the
      # `-out=` value on `plan` and the single operand of `apply` and
      # `show`. The generic value-shape refusal ("takes a value of the form
      # PLAN") would name the shape and not the rule, and the rule is the
      # part the founder has to learn.
      argv_plan_path() {
        if ! argv_shape_ok PLAN "$1"; then
          argv_refuse "$1 is not a plan path. Saved plans live only in ${plansDir}/<name> (name: letters, digits, '.', '_', '-'; no subdirectories) — root writes and reads plan files nowhere else."
        fi
      }

      argv_pos=()
      argv_help=0
      for _t in "''${@:2}"; do
        if [ "$_t" = "--" ]; then
          argv_refuse "'--' is refused: nothing after it can be checked."
        fi
        case "$_t" in
          -help) argv_help=1; continue ;;
          -no-color) continue ;;
        esac
        # The destroy prefix rule from round 6, unchanged: any -destroy…
        # token counts as destruction and is confirmed at /dev/tty below.
        # It is a documented form of `plan` and `apply` and of nothing else.
        case "$_t" in
          -destroy*|--destroy*)
            if [ "$subcmd" = "plan" ] || [ "$subcmd" = "apply" ]; then
              continue
            fi
            argv_refuse "'$_t' is not an allowed argument to '$subcmd'."
            ;;
        esac
        case "$_t" in
          -*)
            _hit=0
            for _b in "''${argv_bools[@]}"; do
              if [ "$_t" = "$_b" ]; then
                _hit=1
                break
              fi
            done
            if [ "$_hit" -eq 0 ]; then
              _name="''${_t%%=*}"
              _val="''${_t#*=}"
              for _v in "''${argv_values[@]}"; do
                _vname="''${_v%%:*}"
                _vshape="''${_v#*:}"
                if [ "$_name" != "$_vname" ]; then
                  continue
                fi
                if [ "$_name" = "$_t" ]; then
                  argv_refuse "$_name needs its value in the SAME token: write $_name=<$_vshape>. A value in its own argument cannot be checked against its flag."
                fi
                if [ "$_vshape" = PLAN ]; then
                  # Refuses with the plans-directory rule rather than with
                  # the shape's name.
                  argv_plan_path "$_val"
                  _hit=1
                elif argv_shape_ok "$_vshape" "$_val"; then
                  _hit=1
                else
                  argv_refuse "$_name takes a value of the form $_vshape, and $_val is not one."
                fi
                break
              done
            fi
            if [ "$_hit" -eq 0 ]; then
              argv_refuse "'$_t' is not an allowed argument to '$subcmd'."
            fi
            ;;
          *)
            argv_pos+=("$_t")
            ;;
        esac
      done

      # Operands. `-help` short-circuits OpenTofu's own parsing, so it also
      # waives the MINIMUM operand counts here (never the maximums, never a
      # refusal by name, never a shape).
      _np="''${#argv_pos[@]}"
      _p1=""
      _p2=""
      if [ "$_np" -ge 1 ]; then _p1="''${argv_pos[0]}"; fi
      if [ "$_np" -ge 2 ]; then _p2="''${argv_pos[1]}"; fi
      argv_arity=1
      if [ "$argv_help" -eq 1 ] && [ "$_np" -eq 0 ]; then
        argv_arity=0
      fi

      argv_check_addrs() {
        local _i="$1"
        local _a
        while [ "$_i" -lt "$_np" ]; do
          _a="''${argv_pos[$_i]}"
          if ! argv_shape_ok ADDR "$_a"; then
            argv_refuse "$_a is not a resource address."
          fi
          _i=$(( _i + 1 ))
        done
      }

      case "$subcmd" in
        init|validate|plan|refresh|version|graph|destroy)
          if [ "$_np" -ne 0 ]; then
            argv_refuse "'$subcmd' takes no operands, and $_p1 is one."
          fi
          ;;
        apply|show)
          if [ "$_np" -gt 1 ]; then
            argv_refuse "'$subcmd' takes at most one operand, a saved plan under ${plansDir}/."
          fi
          if [ "$_np" -eq 1 ]; then
            argv_plan_path "$_p1"
          fi
          ;;
        output)
          if [ "$_np" -gt 1 ]; then
            argv_refuse "'output' takes at most one operand, an output NAME."
          fi
          if [ "$_np" -eq 1 ] && ! argv_shape_ok NAME "$_p1"; then
            argv_refuse "$_p1 is not an output name."
          fi
          ;;
        providers)
          if [ "$_np" -ge 1 ] && [ "$_p1" != "lock" ]; then
            argv_refuse "'providers $_p1' is not offered — 'providers' and 'providers lock' are. 'providers mirror' writes a provider directory the CALLER names, and 'providers schema' is not needed here."
          fi
          if [ "$_np" -gt 1 ]; then
            argv_refuse "'providers lock' takes no further operand."
          fi
          ;;
        state)
          if [ "$_np" -eq 0 ]; then
            if [ "$argv_arity" -eq 1 ]; then
              argv_refuse "'state' needs one of: list, show, pull, rm, mv."
            fi
          else
            # The refusal BY NAME comes first, so `state push -dry-run …`
            # is answered with the reason that matters rather than with a
            # complaint about the flag.
            #
            # No literal "OpenTofu" in any refusal text: the lane proves a
            # refusal never reached tofu by asserting that word is absent
            # from the output, and a message that says it would make the
            # assertion green for the wrong reason.
            case "$_p1" in
              push|replace-provider)
                argv_refuse "'state $_p1' is refused by design: it makes root's tofu read a file the CALLER names and write it over the encrypted remote state."
                ;;
            esac
            # -dry-run and -lock-timeout mean nothing to the read-only
            # state verbs; accepting them there would be a silent no-op.
            if [ "$_p1" != "rm" ] && [ "$_p1" != "mv" ]; then
              for _t in "''${@:2}"; do
                case "$_t" in
                  -dry-run|-lock-timeout=*)
                    argv_refuse "$_t applies only to 'state rm' and 'state mv'."
                    ;;
                esac
              done
            fi
            case "$_p1" in
              list)
                argv_check_addrs 1
                ;;
              show)
                if [ "$_np" -ne 2 ]; then
                  argv_refuse "'state show' takes exactly one resource address."
                fi
                argv_check_addrs 1
                ;;
              pull)
                if [ "$_np" -ne 1 ]; then
                  argv_refuse "'state pull' takes no operand."
                fi
                ;;
              rm)
                if [ "$_np" -lt 2 ]; then
                  argv_refuse "'state rm' takes at least one resource address."
                fi
                argv_check_addrs 1
                ;;
              mv)
                if [ "$_np" -ne 3 ]; then
                  argv_refuse "'state mv' takes exactly two resource addresses."
                fi
                argv_check_addrs 1
                ;;
              *)
                argv_refuse "'state $_p1' is not offered — allowed: list, show, pull, rm, mv."
                ;;
            esac
          fi
          ;;
        import)
          if [ "$argv_arity" -eq 1 ]; then
            if [ "$_np" -ne 2 ]; then
              argv_refuse "'import' takes exactly two operands: ADDR then ID."
            fi
            if ! argv_shape_ok ADDR "$_p1"; then
              argv_refuse "$_p1 is not a resource address."
            fi
            if ! argv_shape_ok ID "$_p2"; then
              argv_refuse "$_p2 is not an import id."
            fi
          fi
          ;;
        taint|untaint)
          if [ "$argv_arity" -eq 1 ]; then
            if [ "$_np" -ne 1 ]; then
              argv_refuse "'$subcmd' takes exactly one resource address."
            fi
            if ! argv_shape_ok ADDR "$_p1"; then
              argv_refuse "$_p1 is not a resource address."
            fi
          fi
          ;;
        force-unlock)
          if [ "$argv_arity" -eq 1 ]; then
            if [ "$_np" -ne 1 ]; then
              argv_refuse "'force-unlock' takes exactly one operand, the LOCK_ID tofu printed."
            fi
            if ! argv_shape_ok LOCK_ID "$_p1"; then
              argv_refuse "$_p1 is not a lock id."
            fi
          fi
          ;;
        workspace)
          if [ "$_np" -eq 0 ]; then
            if [ "$argv_arity" -eq 1 ]; then
              argv_refuse "'workspace' needs one of: list, show, select NAME."
            fi
          else
            case "$_p1" in
              new|delete)
                argv_refuse "'workspace $_p1' is not offered: this design has exactly one workspace, the one the committed backend names."
                ;;
              list|show)
                if [ "$_np" -ne 1 ]; then
                  argv_refuse "'workspace $_p1' takes no further operand."
                fi
                ;;
              select)
                if [ "$_np" -ne 2 ]; then
                  argv_refuse "'workspace select' takes exactly one workspace NAME."
                fi
                if ! argv_shape_ok NAME "$_p2"; then
                  argv_refuse "$_p2 is not a workspace name."
                fi
                ;;
              *)
                argv_refuse "'workspace $_p1' is not offered — allowed: list, show, select NAME."
                ;;
            esac
          fi
          ;;
        *)
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

      # `apply -destroy` IS `destroy`; the flag has to count as one — in
      # EVERY spelling. Matched by prefix, not by a list of values: Go's
      # strconv.ParseBool takes 1/t/T/True/TRUE as well as true, and
      # `apply -destroy=1 -auto-approve` walked straight past the list this
      # used to be. `-destroy=false` is caught too and merely asks for a
      # phrase. (`apply <saved-destroy-plan>` cannot be recognised from
      # argv — the plan file has to be read to know. `plan -out` +
      # `apply <file>` is not a path this wrapper offers a shortcut for, and
      # the founder who saved the plan is the one applying it. Note the
      # working directory is a fresh archive every run, so a plan file only
      # survives to the next invocation by being saved under ${plansDir},
      # which is the one place `-out=` may name.)
      destroying=0
      if [ "$subcmd" = "destroy" ]; then
        destroying=1
      fi
      for _a in "$@"; do
        case "$_a" in
          -destroy*|--destroy*) destroying=1 ;;
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
      # ${plansDir} is created here, 0700 root, for the same reason the
      # other two are: a `plan -out=` naming a file in it must find the
      # directory. It is the only place `-out=`, `apply <plan>` and
      # `show <plan>` may name, and the wrapper never empties it.
      install -d -m 0700 "${stateDir}" "${dataDir}" "${plansDir}"

      # --- run against an ARCHIVE of the verified commit, in a fresh
      #     root-only directory that the trap removes. `git archive` from
      #     root's own mirror: committed content only, root's own
      #     attributes and config, no hooks, no working-tree metadata. The
      #     committed .terraform.lock.hcl is what `init` verifies against;
      #     anything OpenTofu writes into the working directory — a
      #     re-locked lock file, say — dies with it, deliberately. (A plan
      #     cannot land here: `-out=` may only name ${plansDir}/<name>.)
      #
      #     The WHOLE deploy/ tree, not deploy/terraform: hetzner.tf reads
      #     `file("''${path.module}/../cloudflare-ips.json")`, and archiving
      #     the terraform directory alone made every validate/plan/apply die
      #     on that file (reproduced against the real repo). deploy/ is the
      #     provisioning surface; a reference outside it fails loudly here.
      archive_paths="deploy"
      work="$(mktemp -d "${stateDir}/infra-XXXXXXXX")"
      trap 'rm -rf -- "$work"' EXIT

      # Regular files only. A committed symlink would make root's tofu
      # read — or, at deploy/terraform itself, run inside — whatever it
      # points at; a submodule is a tree the mirror does not hold. Both
      # are refused before anything is extracted.
      if git --git-dir="${mirrorDir}" ls-tree -r "$rev" -- "$archive_paths" \
           | awk '$1 != "100644" && $1 != "100755" { found = 1 } END { exit !found }'; then
        gate_refuse "commit $rev has a symlink or submodule under $archive_paths — refusing."
      fi
      if ! git --git-dir="${mirrorDir}" archive --format=tar "$rev" -- "$archive_paths" \
           | tar -x -C "$work"; then
        gate_refuse "commit $rev has no $archive_paths to extract — refusing."
      fi

      # What tofu will read must be, byte for byte, what the commit holds.
      # `git archive` honours a committed .gitattributes, and FIVE attribute
      # classes change what lands on disk: export-ignore drops a file,
      # export-subst rewrites `$Format:…$`, `text`/`eol` rewrite line
      # endings, `ident` substitutes the blob sha, and `filter` runs a
      # smudge command. Hash every extracted path in tree order and compare
      # with the tree's own blob ids; a missing file fails hash-object, a
      # rewritten one fails the compare.
      #
      # `--no-filters` is load-bearing: without it hash-object is entitled
      # to apply the INVERSE (clean) conversion, which would re-normalise a
      # file `git archive` had just mangled and hand back the original blob
      # sha — a check that passes while the bytes on disk differ. Measured
      # with git 2.55.0 on 2026-09-06, in a scratch bare repo with
      # `deploy/.gitattributes` = `* text=auto eol=crlf`: `git archive`
      # DID write CRLF, and hash-object with `--git-dir` pointing at the
      # bare mirror applied no conversion either way (identical shas with
      # and without `--no-filters`), so the refusal fired. `--no-filters`
      # states the intent rather than relying on that: the comparison is of
      # raw bytes to blob, whatever git's future work-tree bookkeeping
      # decides the cwd is.
      #
      # The real klaffat tree has no .gitattributes at all (checked
      # 2026-09-06: `git ls-files | grep -i gitattributes` is empty), so no
      # committed attribute is standing between the founder and a run
      # today; this is the check that keeps it that way.
      expected_shas="$(git --git-dir="${mirrorDir}" ls-tree -r "$rev" -- "$archive_paths" | awk '{ print $3 }')"
      if ! actual_shas="$(git --git-dir="${mirrorDir}" ls-tree -r --name-only "$rev" -- "$archive_paths" \
             | (cd "$work" && git --git-dir="${mirrorDir}" hash-object --no-filters --stdin-paths))" \
         || [ "$expected_shas" != "$actual_shas" ]; then
        echo "klaffat-infra: a committed .gitattributes under $archive_paths can do this: export-ignore drops a file, export-subst and ident rewrite one, text/eol rewrite line endings, filter runs a smudge command." >&2
        gate_refuse "the extracted tree differs from commit $rev — refusing."
      fi
      if [ ! -d "$work/deploy/terraform" ]; then
        gate_refuse "commit $rev has no deploy/terraform — refusing."
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
      ${rootOnlyPreamble "klaffat-infra-install" "<ip>   (then type 'install <ip>' at the terminal to confirm)"}
      ${mirrorLib "klaffat-infra-install"}

      if [ "$#" -ne 1 ]; then
        echo "klaffat-infra-install: usage: sudo klaffat-infra-install <ip>" >&2
        echo "klaffat-infra-install: the install is confirmed at the terminal by typing 'install <ip>'." >&2
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

      # THE FLAKEREF NAMES THE COMMIT, IN ROOT'S MIRROR.
      #
      # A bare path flakeref builds the WORKING TREE, uncommitted edits
      # included (measured on nix 2.34.8), and a `git+file://` flakeref
      # into the founder's checkout would have root's nix run git inside
      # a repository jonathan configures. `git+file://<mirror>?rev=<sha>`
      # is neither: both the app AND the system being installed come out
      # of root's own repository at the commit the server called main.
      #
      # Computed HERE, before the confirmation below, because the founder
      # is asked to approve exactly what is about to be built and where.
      flakeref="git+file://${mirrorDir}?rev=$rev&allRefs=1"

      # --- the TARGET is confirmed at the terminal, the way destroy is.
      #
      # This wrapper stages the demo host's PRIVATE ssh identity and hands
      # it, with root on a fresh machine, to whatever answers at the
      # address in argv. The IP validation above proves the argument is an
      # address; it cannot prove it is the RIGHT address, and until round 7
      # nothing else asked. One sudo password plus one wrong octet — or one
      # address an agent chose — shipped the demo host's key to a machine
      # of someone else's choosing, silently.
      #
      # So: /dev/tty, which no pipe can supply (`yes | sudo
      # klaffat-infra-install …` cannot answer it), the literal IP retyped,
      # and nothing read or staged before the answer. No controlling
      # terminal — a cron job, a systemd unit, an agent-spawned shell —
      # means no confirmation is possible, so the run is refused.
      if ! { exec 3<>/dev/tty; } 2>/dev/null; then
        gate_refuse "installing ships the demo host's private SSH key to root@$ip and there is no terminal to confirm at — refusing."
      fi
      {
        echo
        echo "klaffat-infra-install: this INSTALLS klaffat-demo onto root@$ip,"
        echo "klaffat-infra-install: and ships the demo host's PRIVATE ssh identity to it."
        echo "klaffat-infra-install: ${cfg.repoRemoteUrl} main @ $rev"
        echo "klaffat-infra-install: flakeref $flakeref"
        printf "klaffat-infra-install: type exactly 'install %s' to proceed: " "$ip"
      } >&3
      IFS= read -r _confirm <&3 || _confirm=""
      exec 3>&-
      if [ "$_confirm" != "install $ip" ]; then
        gate_refuse "install not confirmed — refusing."
      fi

      hostkey="${secretPath "klaffat-demo-host-key"}"
      if [ ! -r "$hostkey" ]; then
        echo "klaffat-infra-install: cannot read $hostkey — is the agenix secret provisioned?" >&2
        exit 3
      fi

      # --extra-files staging dir, on tmpfs. /run is root-writable tmpfs
      # on NixOS whether or not root has a runtime dir (sudo does not
      # create /run/user/0), so the private half of the demo host's SSH
      # identity never touches a disk and the trap's rm is the whole
      # cleanup — nothing to shred, nothing left in a journal. Never
      # /tmp, never the on-disk state dir.
      EXTRA="$(mktemp -d /run/klaffat-extra-files.XXXXXXXX)"
      trap 'rm -rf -- "$EXTRA"' EXIT

      install -d -m 0755 "$EXTRA/etc" "$EXTRA/etc/ssh"
      install -m 0600 "$hostkey" "$EXTRA/etc/ssh/ssh_host_ed25519_key"
      ssh-keygen -y -f "$EXTRA/etc/ssh/ssh_host_ed25519_key" \
        > "$EXTRA/etc/ssh/ssh_host_ed25519_key.pub"
      chmod 0644 "$EXTRA/etc/ssh/ssh_host_ed25519_key.pub"

      echo "klaffat-infra-install: installing klaffat-demo onto root@$ip" >&2
      echo "klaffat-infra-install: flakeref $flakeref" >&2
      if [ -z "''${SSH_AUTH_SOCK-}" ]; then
        echo "klaffat-infra-install: SSH_AUTH_SOCK is not set — root has no key of its own; run ssh-add for the key the server authorises (see the sudo rule: it keeps SSH_AUTH_SOCK for this command)." >&2
      fi
      # No `exec`: the EXIT trap above must still fire to remove $EXTRA.
      #
      # `--extra-experimental-features 'nix-command flakes'` for the same
      # reason klaffat-publish passes it on every one of its four nix
      # calls: a flakeref only resolves with those features on, and taking
      # them from the system-wide nix.settings would make the most
      # privileged step in this module — root installing a fresh machine —
      # depend on configuration nothing here declares.
      rc=0
      nix --extra-experimental-features 'nix-command flakes' \
        run "$flakeref#nixos-anywhere" -- \
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
        # Resolving proves the OBJECT is in the mirror; `fetch --prune`
        # drops refs, not objects, so a force-pushed or deleted branch's
        # commits linger until gc. Publishable means reachable from a
        # branch the server has NOW.
        if [ -z "$(git --git-dir="${mirrorDir}" for-each-ref --contains "$rev" refs/heads)" ]; then
          echo "klaffat-publish: '$target' ($rev) is not reachable from any current branch of ${cfg.repoRemoteUrl} — refusing." >&2
          echo "klaffat-publish: a force-pushed or deleted branch leaves its objects in the mirror; only what a live branch reaches can be published." >&2
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
  installCommands = [
    "${klaffat-infra-install}/bin/klaffat-infra-install"
    "/run/current-system/sw/bin/klaffat-infra-install"
  ];
  sudoCommands = [
    "${klaffat-infra}/bin/klaffat-infra"
    "${klaffat-publish}/bin/klaffat-publish"
    "/run/current-system/sw/bin/klaffat-infra"
    "/run/current-system/sw/bin/klaffat-publish"
  ] ++ installCommands;

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
    #
    # SSH_AUTH_SOCK survives env_reset for klaffat-infra-install ONLY: root
    # has no ssh key, the fresh server authorises the founder's, and the
    # founder's agent is where that key lives (header, "The install
    # wrapper's ssh identity"). Not SETENV — the founder cannot set
    # arbitrary variables; sudo passes this one through, for this command.
    security.sudo.extraConfig = ''
      Cmnd_Alias KLAFFAT_INFRA_CMNDS = ${lib.concatStringsSep ", " sudoCommands}
      Cmnd_Alias KLAFFAT_INSTALL_CMNDS = ${lib.concatStringsSep ", " installCommands}
      Defaults!KLAFFAT_INFRA_CMNDS timestamp_timeout=0
      Defaults!KLAFFAT_INFRA_CMNDS timestamp_type=tty
      Defaults!KLAFFAT_INSTALL_CMNDS env_keep += "SSH_AUTH_SOCK"
    '';
  };
}
