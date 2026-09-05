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
#   3. Every refusal branch of the wrapper, at the REAL fixed path
#      /home/jonathan/Repos/klaffat: absent, dirty, wrong branch. No
#      test-only path override (the contract forbids one), so the lane
#      builds a genuine jonathan-owned git repo at that exact location —
#      which also exercises the `-c safe.directory` handling root needs to
#      read another user's checkout at all.
#
#   4. The happy path reaches `exec tofu`, printing the revision line
#      first. `tofu version` is offline-safe (OpenTofu has no checkpoint
#      call-home) and needs no init, so it is the cheapest argument that
#      still proves env reconstruction + cd + exec all fired.
#
#   5. klaffat-infra-install stages and then SHREDS its --extra-files dir.
#      The trap is the only thing standing between a failed install and a
#      demo host's private SSH key left lying in /var/lib, so the lane
#      forces the failure path and asserts nothing survived it.
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
in
common.mkMinimalTest {
  name = "klaffat-infra";

  extraModules = [
    ../modules/nixos/klaffat-infra.nix
    (_: {
      services.klaffatInfra.enable = true;

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
    # 1. Both wrappers reached PATH.
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
    # 4. As root, with the checkout absent: the exact refusal.
    # ---------------------------------------------------------------
    rc, out = run("${bin}/klaffat-infra version")
    assert rc == 2, f"absent-checkout refusal should exit 2, got {rc}: {out!r}"
    expected = (
        "klaffat-infra: no OpenTofu checkout at "
        "${repo}/deploy/terraform — refusing."
    )
    assert expected in out, f"expected {expected!r}, got {out!r}"

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
    # 5. sudo: password required for the wrapper, NOT for everything else.
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
    # 6. A real jonathan-owned checkout at the fixed path.
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

    # 6a. Dirty tree.
    machine.succeed("install -o jonathan -g users /dev/null ${repo}/deploy/terraform/scratch")
    rc, out = run("${bin}/klaffat-infra version")
    assert rc == 2, f"dirty-tree refusal should exit 2, got {rc}: {out!r}"
    assert "working tree at ${repo} is dirty — refusing." in out, (
        f"unexpected dirty-tree refusal: {out!r}"
    )
    machine.succeed("rm ${repo}/deploy/terraform/scratch")

    # Root just ran git in jonathan's checkout. It must not have taken
    # ownership of anything: an index refreshed as root leaves the founder
    # unable to `git checkout` his own repo afterwards.
    owner = machine.succeed("stat -c '%U' ${repo}/.git/index").strip()
    assert owner == "jonathan", (
        f".git/index is owned by {owner!r} after a root wrapper run"
    )

    # 6b. Wrong branch.
    as_jonathan_git("checkout -q -b feature")
    rc, out = run("${bin}/klaffat-infra version")
    assert rc == 2, f"branch refusal should exit 2, got {rc}: {out!r}"
    assert "HEAD is on 'feature', not 'main' — refusing." in out, (
        f"unexpected branch refusal: {out!r}"
    )
    as_jonathan_git("checkout -q main")

    # 6c. Clean, on main: prints the revision and execs tofu.
    rev = as_jonathan_git("rev-parse HEAD").strip()
    rc, out = run("${bin}/klaffat-infra version")
    assert rc == 0, f"clean run should succeed, got {rc}: {out!r}"
    assert f"klaffat-infra: ${repo} @ {rev} (branch main)" in out, (
        f"revision line missing or wrong: {out!r}"
    )
    assert "OpenTofu v" in out, f"tofu was not exec'd: {out!r}"

    # TF_DATA_DIR is root-only state, created by the wrapper.
    mode = machine.succeed(
        "stat -c '%a %U' /var/lib/klaffat-infra/terraform.d"
    ).strip()
    assert mode == "700 root", f"TF_DATA_DIR should be 700 root, got '{mode}'"

    # ---------------------------------------------------------------
    # 6d. klaffat-publish against the real checkout.
    #
    # The build cannot succeed (the fixture repo has no flake and no
    # klaffat-demo host), which is precisely the failure the worktree
    # bookkeeping has to survive: root must leave nothing behind that
    # jonathan can no longer write.
    # ---------------------------------------------------------------
    rc, out = run("${bin}/klaffat-publish")
    assert rc != 0, "klaffat-publish should fail against a flake-less checkout"
    assert f"klaffat-publish: building klaffat-demo from {rev}" in out, (
        f"publish did not reach the build with main's tip: {out!r}"
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
    # 7. klaffat-infra-install: argument handling + the cleanup trap.
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
    _, leftovers = machine.execute("ls -A /var/lib/klaffat-infra /run/user/0 2>/dev/null")
    assert "klaffat-extra-files" not in leftovers, (
        f"--extra-files staging dir survived a failed install: {leftovers!r}"
    )
  '';
}
