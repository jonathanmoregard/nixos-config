# vm-klaffat-infra: the sudo-gated OpenTofu wrapper end to end.
#
# Run: nix build .#checks.x86_64-linux.vm-klaffat-infra -L
#
# What this lane proves, and why each assertion is behavioural rather
# than a presence check:
#
#   1. The seven provisioning secrets DECRYPT inside the VM and land 0400
#      root:root, and jonathan cannot read them. Every other lane in this
#      repo asserts only the agenix *path*, because no test VM holds a
#      recipient key — such an assertion is green for the wrong reason.
#      Here the lane brings its own recipient (tests/lib/klaffat-fixtures.nix)
#      so "0400 root" is measured on a file that actually exists and
#      "jonathan cannot read it" is a real permission denial.
#
#   2. NO sudo works without a password for jonathan — neither the
#      wrappers nor `sudo -n true`. profiles/base.nix used to set
#      `wheelNeedsPassword = false`, which made the root-only secrets a
#      fiction (`sudo cat /run/agenix/klaffat-*` needed no password). The
#      lane asserts both halves so a revert of that line fails here rather
#      than silently reopening the hole, and so the per-command rules stay
#      honest if it is ever loosened again.
#
#   3. Every refusal branch of every wrapper, at the REAL fixed path
#      /home/jonathan/Repos/klaffat: absent, dirty, wrong branch, wrong
#      remote, HEAD not at the remote's tip, stray auto-loaded OpenTofu
#      files. No test-only path override (the contract forbids one), so
#      the lane builds a genuine jonathan-owned git repo at that exact
#      location — which also exercises the `-c safe.directory` handling
#      root needs to read another user's checkout at all.
#
#      THE PROVENANCE GATE IS THE POINT OF THIS LANE. The first draft of
#      the module decided provenance from two facts jonathan owns — a
#      clean tree and a branch named `main` — and an agent-authored commit
#      on a purely local `main`, ahead of and divergent from origin/main,
#      reached `tofu` as uid 0 with every credential exported. So the lane
#      brings a real remote (a root-owned bare repo, reached over
#      `file://`, pinned through services.klaffatInfra.repoRemoteUrl) and
#      drives exactly that scenario: local main one commit ahead, tree
#      clean, branch `main` — and asserts the refusal.
#
#   4. The happy path reaches `exec tofu`, printing the revision line
#      first. `tofu version` is offline-safe (OpenTofu has no checkpoint
#      call-home) and needs no init, so it is the cheapest argument that
#      still proves env reconstruction + cd + exec all fired.
#
#   5. Only allowlisted OpenTofu subcommands run at all, and `destroy`
#      (including `apply -destroy`) needs a confirmation typed at a
#      terminal. sudo's prompt names the wrapper, never the subcommand, so
#      without this `yes | sudo klaffat-infra destroy` is one password
#      away from an empty stack.
#
#   6. klaffat-publish's default target is the remote's main, not the
#      local one, and the temporary build worktree leaves nothing behind.
#
#   7. klaffat-infra-install stages and then SHREDS its --extra-files dir,
#      and the flakeref it hands `nix run` carries the verified `rev=` —
#      a bare path flakeref builds the working tree, uncommitted edits
#      included.
{ pkgs, inputs }:

let
  lib = pkgs.lib;
  common = import ./lib/common.nix { inherit pkgs inputs; };
  fixtures = import ./lib/klaffat-fixtures.nix { inherit pkgs; };

  secretNames = [
    "klaffat-hcloud-token"
    "klaffat-cloudflare-api-token"
    "klaffat-state-passphrase"
    "klaffat-aws-access-key-id"
    "klaffat-aws-secret-access-key"
    "klaffat-demo-host-key"
    "klaffat-nix-signing-key"
  ];

  git = "${pkgs.git}/bin/git";
  bin = "/run/current-system/sw/bin";
  repo = "/home/jonathan/Repos/klaffat";

  # The lane's stand-in for github.com: a bare repo that only ROOT can
  # write, reached over `file://`. That is the property the gate needs —
  # an authority outside the jonathan-owned checkout — and it is the one
  # part of the real setup a network-less VM cannot borrow.
  originDir = "/var/lib/klaffat-origin.git";
  originUrl = "file://${originDir}";

  # The literal `aws_secretsmanager_secret.nix_signing_key` creates in the
  # klaffat repo's deploy/terraform/aws.tf, and the one
  # .github/workflows/publish.yml reads. The module said
  # `klaffat/nix-signing-key` until 2026-09-05; `put-secret-value` does
  # not create a missing secret, so the upload failed with
  # ResourceNotFoundException, no closure was ever signed, and the demo
  # host could install nothing.
  signingKeySecretId = "klaffat-nix-signing-key";
in
common.mkMinimalTest {
  name = "klaffat-infra";

  extraModules = [
    ../modules/nixos/klaffat-infra.nix
    (_: {
      services.klaffatInfra.enable = true;

      # The pinned remote. In production this is the GitHub HTTPS URL and
      # a token file goes with it; here it is a root-owned bare repo, so
      # the gate's logic is exercised end to end with no network.
      services.klaffatInfra.repoRemoteUrl = originUrl;

      # Swap dellan's host-key-encrypted ciphertexts for fixtures this VM
      # can actually open. `file` (not `rekeyFile`) on both sides, so the
      # only thing that changes is the recipient.
      age.identityPaths = lib.mkForce [ "${fixtures}/id_ed25519" ];
      age.secrets = lib.genAttrs secretNames (n: {
        file = lib.mkForce "${fixtures}/${n}.age";
      });
    })
  ];

  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")

    def run(cmd):
        rc, out = machine.execute(cmd + " 2>&1")
        return rc, out.strip()

    # ---------------------------------------------------------------
    # 1. All three wrappers reached PATH.
    # ---------------------------------------------------------------
    machine.succeed("test -x ${bin}/klaffat-infra")
    machine.succeed("test -x ${bin}/klaffat-infra-install")
    machine.succeed("test -x ${bin}/klaffat-publish")

    # ---------------------------------------------------------------
    # 2. Secrets decrypted, 0400 root:root, unreadable by jonathan.
    # ---------------------------------------------------------------
    for name in ${builtins.toJSON secretNames}:
        mode = machine.succeed(f"stat -Lc '%a %U %G' /run/agenix/{name}").strip()
        assert mode == "400 root root", (
            f"{name}: expected '400 root root' in /run/agenix, got '{mode}'"
        )

    token = machine.succeed("cat /run/agenix/klaffat-hcloud-token").strip()
    assert token == "TEST-hcloud-token", (
        f"klaffat-hcloud-token did not decrypt to the seeded value: {token!r}"
    )

    # The whole design rests on this one being a denial.
    rc, out = run("runuser -u jonathan -- cat /run/agenix/klaffat-hcloud-token")
    assert rc != 0, "jonathan could read a root-only provisioning secret"
    assert "Permission denied" in out, f"unexpected refusal for jonathan: {out!r}"

    # ---------------------------------------------------------------
    # 3. Non-root invocation is refused.
    # ---------------------------------------------------------------
    rc, out = run("runuser -u jonathan -- ${bin}/klaffat-infra plan")
    assert rc == 1, f"non-root klaffat-infra should exit 1, got {rc}: {out!r}"
    assert "this wrapper is root-only" in out, f"unexpected non-root refusal: {out!r}"
    assert "sudo klaffat-infra" in out, f"refusal must name the sudo form: {out!r}"

    rc, out = run("runuser -u jonathan -- ${bin}/klaffat-infra-install 10.0.0.1")
    assert rc == 1, f"non-root klaffat-infra-install should exit 1, got {rc}"
    assert "this wrapper is root-only" in out, f"unexpected non-root refusal: {out!r}"

    rc, out = run("runuser -u jonathan -- ${bin}/klaffat-publish")
    assert rc == 1, f"non-root klaffat-publish should exit 1, got {rc}"
    assert "this wrapper is root-only" in out, f"unexpected non-root refusal: {out!r}"
    assert "sudo klaffat-publish [rev | --upload-signing-key]" in out, (
        f"refusal must name the sudo form: {out!r}"
    )

    # ---------------------------------------------------------------
    # 4. What the BUILT scripts render.
    #
    #    Two of the round-4 defects were pure string faults that no
    #    runtime path in a network-less VM can reach, so they are
    #    asserted on the artifact the founder actually runs.
    # ---------------------------------------------------------------
    publish_src = machine.succeed("cat $(readlink -f ${bin}/klaffat-publish)")
    assert '--secret-id "${signingKeySecretId}"' in publish_src, (
        "klaffat-publish does not pass the Secrets Manager id Terraform creates "
        "(${signingKeySecretId}); put-secret-value does NOT create a missing "
        "secret, so the signing key never reaches Actions and no closure is signed"
    )
    assert "klaffat/nix-signing-key" not in publish_src, (
        "the old slash-spelled Secrets Manager id is still in klaffat-publish"
    )

    install_src = machine.succeed("cat $(readlink -f ${bin}/klaffat-infra-install)")
    assert 'flakeref="git+file://$repo?rev=$rev"' in install_src, (
        "klaffat-infra-install must address the repo by a rev-pinned git flakeref; "
        "a bare path flakeref builds uncommitted working-tree content"
    )
    for bad in ['nix run "${repo}#', '--flake "${repo}#']:
        assert bad not in install_src, (
            f"klaffat-infra-install still passes a bare path flakeref: {bad!r}"
        )

    # ---------------------------------------------------------------
    # 5. As root, with the checkout absent: the exact refusals.
    # ---------------------------------------------------------------
    rc, out = run("${bin}/klaffat-infra version")
    assert rc == 2, f"absent-checkout refusal should exit 2, got {rc}: {out!r}"
    expected = (
        "klaffat-infra: no OpenTofu checkout at "
        "${repo}/deploy/terraform — refusing."
    )
    assert expected in out, f"expected {expected!r}, got {out!r}"

    # argv is validated before anything else, so these need no checkout.
    rc, out = run("${bin}/klaffat-infra")
    assert rc == 2 and "usage: sudo klaffat-infra <tofu subcommand>" in out, (
        f"no-subcommand refusal wrong: {rc} {out!r}"
    )

    for bogus in ["frobnicate", "shell", "-chdir=/tmp"]:
        rc, out = run(f"${bin}/klaffat-infra {bogus}")
        assert rc == 2, f"'{bogus}' should be refused with exit 2, got {rc}: {out!r}"
        assert "is not an allowed OpenTofu subcommand" in out, (
            f"unexpected refusal for '{bogus}': {out!r}"
        )

    rc, out = run("${bin}/klaffat-publish")
    assert rc == 2, f"absent-checkout refusal should exit 2, got {rc}: {out!r}"
    assert "klaffat-publish: no klaffat checkout at ${repo} — refusing." in out, (
        f"unexpected klaffat-publish refusal: {out!r}"
    )

    rc, out = run("${bin}/klaffat-publish aaaa bbbb")
    assert rc == 2 and "usage: sudo klaffat-publish [rev | --upload-signing-key]" in out, (
        f"too-many-args refusal wrong: {rc} {out!r}"
    )

    # --upload-signing-key validates its arity BEFORE touching AWS, which is
    # the only part of that mode a network-less VM can reach.
    rc, out = run("${bin}/klaffat-publish --upload-signing-key extra")
    assert rc == 2 and "--upload-signing-key takes no other arguments" in out, (
        f"upload-signing-key arity refusal wrong: {rc} {out!r}"
    )

    # ---------------------------------------------------------------
    # 6. sudo: password required for the wrapper, NOT for everything else.
    # ---------------------------------------------------------------
    # wheel is no longer NOPASSWD: nothing jonathan sudoes runs unprompted,
    # which is what makes /run/agenix/klaffat-* actually root-only.
    rc, out = run("runuser -u jonathan -- sudo -n true")
    assert rc != 0, "wheel still has NOPASSWD — the agenix secrets are reachable"
    assert "password is required" in out, f"expected a password demand, got {out!r}"

    # Both spellings must prompt. The PATH-resolved one is what the founder
    # types; the store path is what the sudoers rule pins. sudo does not
    # resolve the symlink between them, so listing only one leaves the
    # other falling through to wheel's NOPASSWD — the exact fail-open this
    # lane caught during development.
    for form in [
        "${bin}/klaffat-infra version",
        "$(readlink -f ${bin}/klaffat-infra) version",
        "${bin}/klaffat-infra-install 10.0.0.1",
        "$(readlink -f ${bin}/klaffat-infra-install) 10.0.0.1",
        "${bin}/klaffat-publish",
        "$(readlink -f ${bin}/klaffat-publish)",
    ]:
        rc, out = run(f"runuser -u jonathan -- sudo -n {form}")
        assert rc != 0, f"sudo ran '{form}' without a password"
        assert "password is required" in out, (
            f"expected sudo to demand a password for '{form}', got {out!r}"
        )

    sudoers = machine.succeed("cat /etc/sudoers")
    rule_lines = [
        ln for ln in sudoers.splitlines()
        if "klaffat-infra" in ln and ln.strip().startswith("jonathan")
    ]
    assert len(rule_lines) == 1, f"expected one jonathan rule, got {rule_lines!r}"
    assert "NOPASSWD" not in rule_lines[0], f"rule carries NOPASSWD: {rule_lines[0]!r}"
    assert "SETENV" not in rule_lines[0], f"rule carries SETENV: {rule_lines[0]!r}"
    assert "Defaults!KLAFFAT_INFRA_CMNDS timestamp_timeout=0" in sudoers
    assert "Defaults!KLAFFAT_INFRA_CMNDS timestamp_type=tty" in sudoers

    # ---------------------------------------------------------------
    # 7. A real jonathan-owned checkout at the fixed path, plus a
    #    root-owned "remote" it is pinned to.
    # ---------------------------------------------------------------
    machine.succeed("install -d -o jonathan -g users /home/jonathan/Repos ${repo}")
    machine.succeed(
        "install -d -o jonathan -g users ${repo}/deploy ${repo}/deploy/terraform"
    )
    machine.succeed("install -o jonathan -g users /dev/null ${repo}/deploy/terraform/main.tf")

    def as_jonathan_git(args):
        return machine.succeed(
            "runuser -u jonathan -- env HOME=/home/jonathan "
            f"${git} -C ${repo} -c user.email=t@example.invalid -c user.name=t {args}"
        )

    machine.succeed(
        "runuser -u jonathan -- env HOME=/home/jonathan ${git} init -q -b main ${repo}"
    )
    as_jonathan_git("add -A")
    as_jonathan_git("commit -q -m init")
    as_jonathan_git("remote add origin ${originUrl}")

    # The "remote". --no-hardlinks so its objects are root-owned copies,
    # not links into a directory jonathan writes.
    #
    # BOTH safe.directory entries: a local clone resolves the source to
    # its .git directory and checks ownership on THAT path, so listing
    # only the worktree gets "detected dubious ownership in repository at
    # '<repo>/.git'". (Production never does this — the real remote is
    # https and the wrappers only ever read the checkout in place.)
    def clone_bare(dest):
        machine.succeed(
            "${git} -c safe.directory=${repo} -c safe.directory=${repo}/.git "
            f"clone --bare --no-hardlinks -q ${repo} {dest}"
        )

    clone_bare("${originDir}")
    rev_a = as_jonathan_git("rev-parse HEAD").strip()

    # 7a. Dirty tree.
    machine.succeed("install -o jonathan -g users /dev/null ${repo}/deploy/terraform/scratch")
    rc, out = run("${bin}/klaffat-infra version")
    assert rc == 2, f"dirty-tree refusal should exit 2, got {rc}: {out!r}"
    assert "working tree at ${repo} is dirty — refusing." in out, (
        f"unexpected dirty-tree refusal: {out!r}"
    )
    rc, out = run("${bin}/klaffat-infra-install 10.0.0.1")
    assert rc == 2 and "working tree at ${repo} is dirty — refusing." in out, (
        f"klaffat-infra-install accepted a dirty tree: {rc} {out!r}"
    )
    machine.succeed("rm ${repo}/deploy/terraform/scratch")

    # Root just ran git in jonathan's checkout. It must not have taken
    # ownership of anything: an index refreshed as root leaves the founder
    # unable to `git checkout` his own repo afterwards.
    owner = machine.succeed("stat -c '%U' ${repo}/.git/index").strip()
    assert owner == "jonathan", (
        f".git/index is owned by {owner!r} after a root wrapper run"
    )

    # 7b. Wrong branch.
    as_jonathan_git("checkout -q -b feature")
    rc, out = run("${bin}/klaffat-infra version")
    assert rc == 2, f"branch refusal should exit 2, got {rc}: {out!r}"
    assert "HEAD is on 'feature', not 'main' — refusing." in out, (
        f"unexpected branch refusal: {out!r}"
    )
    rc, out = run("${bin}/klaffat-infra-install 10.0.0.1")
    assert rc == 2 and "HEAD is on 'feature', not 'main' — refusing." in out, (
        f"klaffat-infra-install accepted a non-main branch: {rc} {out!r}"
    )
    as_jonathan_git("checkout -q main")

    # 7c. An untracked OpenTofu auto-load file. `git status --porcelain`
    #     calls the tree clean (the fixture .gitignore hides it, and
    #     .gitignore is jonathan's to write), but `tofu plan` would read
    #     it and it would replace resource blocks wholesale.
    machine.succeed(
        "runuser -u jonathan -- env HOME=/home/jonathan "
        "sh -c 'printf \"deploy/terraform/override.tf\\n\" > ${repo}/.gitignore'"
    )
    as_jonathan_git("add -A")
    as_jonathan_git("commit -q -m gitignore")
    machine.succeed(
        "runuser -u jonathan -- env HOME=/home/jonathan "
        "sh -c 'printf \"# canary\\n\" > ${repo}/deploy/terraform/override.tf'"
    )
    clean = as_jonathan_git("status --porcelain").strip()
    assert clean == "", f"the fixture must be porcelain-clean for this case: {clean!r}"
    rc, out = run("${bin}/klaffat-infra version")
    assert rc == 2, f"stray override.tf should be refused, got {rc}: {out!r}"
    assert "OpenTofu auto-loads it" in out, (
        f"unexpected stray-autoload refusal: {out!r}"
    )
    machine.succeed("rm ${repo}/deploy/terraform/override.tf")

    # The .gitignore commit put local main ahead of the remote; catch the
    # remote up so the next cases start from equality.
    machine.succeed("rm -rf ${originDir}")
    clone_bare("${originDir}")
    rev_a = as_jonathan_git("rev-parse HEAD").strip()

    # 7d. Clean, on main, at the remote's tip: prints the revision and
    #     execs tofu.
    rc, out = run("${bin}/klaffat-infra version")
    assert rc == 0, f"clean run should succeed, got {rc}: {out!r}"
    assert f"klaffat-infra: ${repo} @ {rev_a} (branch main, = ${originUrl} main)" in out, (
        f"revision line missing or wrong: {out!r}"
    )
    assert "OpenTofu v" in out, f"tofu was not exec'd: {out!r}"

    # TF_DATA_DIR is root-only state, created by the wrapper.
    mode = machine.succeed(
        "stat -c '%a %U' /var/lib/klaffat-infra/terraform.d"
    ).strip()
    assert mode == "700 root", f"TF_DATA_DIR should be 700 root, got '{mode}'"

    # ---------------------------------------------------------------
    # 8. destroy needs a terminal, and a pipe is not one.
    #
    #    `tofu destroy` reads its own approval from stdin, and sudo's
    #    prompt names only the wrapper — so before this, one password plus
    #    a piped `yes` emptied the stack.
    # ---------------------------------------------------------------
    # `setsid --wait` puts the wrapper in a session with NO controlling
    # terminal — which is also what a cron job, a systemd unit or an
    # agent-spawned shell looks like. (Not optional here: the test
    # driver's own backdoor shell DOES have one, on /dev/hvc0, and a
    # prompt written straight to it desynchronises the driver protocol.
    # Measured — the first run of this lane died on
    # `ValueError: invalid literal for int()` with the prompt as the
    # payload.)
    #
    # `timeout` is a tripwire, not part of the contract: a wrapper that
    # blocked on a read nobody can answer would hang the lane, and a hang
    # reads like an infrastructure problem rather than the assertion
    # failure it is. rc 124 says exactly that.
    for cmd in ["destroy", "destroy -auto-approve", "apply -destroy"]:
        rc, out = run(f"yes | setsid --wait timeout 30 ${bin}/klaffat-infra {cmd}")
        assert rc != 124, (
            f"'{cmd}' blocked on a terminal read instead of refusing: {out!r}"
        )
        assert rc == 2, f"'{cmd}' should be refused without a terminal, got {rc}: {out!r}"
        assert "no terminal to confirm at" in out, (
            f"unexpected destroy refusal for '{cmd}': {out!r}"
        )
        assert "OpenTofu v" not in out, f"'{cmd}' reached tofu: {out!r}"

    # 8a. WITH a real terminal and `yes` on stdin — the shape of the
    #     original attack. The pipe feeds stdin; the confirmation is read
    #     from /dev/tty, so the pipe never touches it and the typed answer
    #     (here deliberately wrong) is what decides.
    rc, out = run(
        "printf 'no\\n' | timeout 30 script -qec "
        "'yes | ${bin}/klaffat-infra destroy' /dev/null"
    )
    assert rc != 124, f"destroy hung on a pty instead of reading the answer: {out!r}"
    assert "type exactly 'destroy klaffat' to proceed" in out, (
        f"the confirmation prompt never reached the terminal: {out!r}"
    )
    assert "destroy not confirmed — refusing." in out, (
        f"a wrong answer must refuse — the piped `yes` must not count: {out!r}"
    )
    assert "OpenTofu v" not in out, f"destroy reached tofu anyway: {out!r}"

    # 8b. …and the right answer, typed, gets through. `apply -destroy
    #     -help` is destroy-flagged (so it must be confirmed) but writes
    #     no state, so the fixture tree stays clean for the cases below.
    rc, out = run(
        "printf 'destroy klaffat\\n' | timeout 60 script -qec "
        "'${bin}/klaffat-infra apply -destroy -help' /dev/null"
    )
    assert rc != 124, f"the confirmed destroy hung: {out!r}"
    assert "destroy not confirmed" not in out and "no terminal to confirm at" not in out, (
        f"a correctly typed confirmation was still refused: {out!r}"
    )
    dirt = as_jonathan_git("status --porcelain").strip()
    assert dirt == "", (
        f"a wrapper run left artefacts in the founder's tree: {dirt!r}"
    )

    # ---------------------------------------------------------------
    # 9. THE PROVENANCE GATE. Clean tree, branch literally `main`, one
    #    agent-authored commit that the remote has never seen.
    # ---------------------------------------------------------------
    machine.succeed(
        "runuser -u jonathan -- env HOME=/home/jonathan "
        "sh -c 'printf \"# CANARY unreviewed\\n\" >> ${repo}/deploy/terraform/main.tf'"
    )
    as_jonathan_git("add -A")
    as_jonathan_git("commit -q -m 'agent: unreviewed local commit'")
    rev_b = as_jonathan_git("rev-parse HEAD").strip()
    assert rev_b != rev_a

    branch = as_jonathan_git("rev-parse --abbrev-ref HEAD").strip()
    dirt = as_jonathan_git("status --porcelain").strip()
    assert branch == "main" and dirt == "", (
        "the local facts the old gate trusted must both still hold here: "
        f"branch={branch!r} dirty={dirt!r}"
    )

    for wrapper, args in [
        ("klaffat-infra", "version"),
        ("klaffat-infra-install", "10.0.0.1"),
    ]:
        rc, out = run(f"${bin}/{wrapper} {args}")
        assert rc == 2, (
            f"{wrapper} ran on a commit the remote never saw (exit {rc}): {out!r}"
        )
        assert "HEAD is not the tip of main on the remote" in out, (
            f"unexpected provenance refusal from {wrapper}: {out!r}"
        )
        assert rev_b in out and rev_a in out, (
            f"{wrapper} must print both shas so the founder can see the gap: {out!r}"
        )
        assert "OpenTofu v" not in out, f"{wrapper} reached tofu anyway: {out!r}"

    # 9a. klaffat-publish's DEFAULT target is the remote's main, not the
    #     local one — otherwise it signs and pushes a closure nothing
    #     asked for while the deploy keeps failing on the real revision.
    rc, out = run("${bin}/klaffat-publish")
    assert rc != 0, "klaffat-publish should fail against a flake-less checkout"
    assert f"klaffat-publish: building klaffat-demo from {rev_a}" in out, (
        f"klaffat-publish did not default to the REMOTE tip {rev_a}: {out!r}"
    )
    assert rev_b not in out, (
        f"klaffat-publish targeted the local main {rev_b}: {out!r}"
    )

    # 9b. …but an explicitly named commit stays explicit.
    rc, out = run(f"${bin}/klaffat-publish {rev_b}")
    assert rc != 0
    assert f"klaffat-publish: building klaffat-demo from {rev_b}" in out, (
        f"an explicit rev must be honoured: {out!r}"
    )

    as_jonathan_git(f"reset -q --hard {rev_a}")

    # 9c. The pinned remote URL. `origin` lives in the jonathan-owned
    #     .git/config, so a gate that fetched whatever it points at would
    #     be no gate at all.
    as_jonathan_git("remote set-url origin file:///var/lib/klaffat-evil.git")
    clone_bare("/var/lib/klaffat-evil.git")
    for wrapper, args in [
        ("klaffat-infra", "version"),
        ("klaffat-infra-install", "10.0.0.1"),
        ("klaffat-publish", ""),
    ]:
        rc, out = run(f"${bin}/{wrapper} {args}")
        assert rc == 2, f"{wrapper} accepted a repointed origin (exit {rc}): {out!r}"
        assert "does not point at the pinned remote" in out, (
            f"unexpected remote-url refusal from {wrapper}: {out!r}"
        )
    # Literal fixture path inside the throwaway test VM; removing the decoy
    # repo is what lets a later case re-create it.
    # arftl-allow: destructive-rm
    machine.succeed("rm -rf /var/lib/klaffat-evil.git")
    as_jonathan_git("remote set-url origin ${originUrl}")

    # ---------------------------------------------------------------
    # 10. klaffat-publish against the real checkout.
    #
    # The build cannot succeed (the fixture repo has no flake and no
    # klaffat-demo host), which is precisely the failure the worktree
    # bookkeeping has to survive: root must leave nothing behind that
    # jonathan can no longer write.
    # ---------------------------------------------------------------
    rc, out = run("${bin}/klaffat-publish")
    assert rc != 0, "klaffat-publish should fail against a flake-less checkout"
    assert f"klaffat-publish: building klaffat-demo from {rev_a}" in out, (
        f"publish did not reach the build with the remote's tip: {out!r}"
    )

    rc, out = run("${bin}/klaffat-publish no-such-rev")
    assert rc == 2 and "is not a commit in ${repo}" in out, (
        f"unknown-rev refusal wrong: {rc} {out!r}"
    )

    _, root_owned = machine.execute("find ${repo}/.git -user root")
    assert root_owned.strip() == "", (
        f"klaffat-publish left root-owned paths in the founder's .git: {root_owned!r}"
    )
    _, leftovers = machine.execute("ls -A /var/lib/klaffat-infra")
    assert "publish-" not in leftovers, (
        f"temporary publish worktree survived: {leftovers!r}"
    )
    # And the founder can still use his own worktrees afterwards.
    machine.succeed(
        "runuser -u jonathan -- env HOME=/home/jonathan "
        "${git} -C ${repo} worktree add --detach /home/jonathan/wt HEAD"
    )

    # ---------------------------------------------------------------
    # 11. klaffat-infra-install: argument handling, the rev-pinned
    #     flakeref, and the cleanup trap.
    # ---------------------------------------------------------------
    rc, out = run("${bin}/klaffat-infra-install")
    assert rc == 2 and "usage:" in out, f"missing-arg refusal wrong: {rc} {out!r}"

    rc, out = run("${bin}/klaffat-infra-install not-an-ip")
    assert rc == 2 and "is not an IP address" in out, (
        f"bad-address refusal wrong: {rc} {out!r}"
    )

    # Real staging run. `nix run` cannot succeed here (the fixture repo has
    # no flake), which is exactly the failure the trap has to survive.
    rc, out = run("${bin}/klaffat-infra-install 10.0.0.1")
    assert rc != 0, "install against a flake-less checkout should fail"
    assert "installing klaffat-demo onto root@10.0.0.1" in out, (
        f"install did not reach the nixos-anywhere call: {out!r}"
    )
    assert f"flakeref git+file://${repo}?rev={rev_a}" in out, (
        "the flakeref handed to nix run must pin the verified rev — a bare path "
        f"flakeref builds the working tree, uncommitted edits included: {out!r}"
    )
    _, leftovers = machine.execute("ls -A /var/lib/klaffat-infra /run/user/0 2>/dev/null")
    assert "klaffat-extra-files" not in leftovers, (
        f"--extra-files staging dir survived a failed install: {leftovers!r}"
    )
  '';
}
