# vm-klaffat-infra: the sudo-gated OpenTofu wrapper end to end.
#
# Run: nix build .#checks.x86_64-linux.vm-klaffat-infra -L
#
# What this lane proves, and why each assertion is behavioural rather
# than a presence check:
#
#   1. The eight provisioning secrets DECRYPT inside the VM and land 0400
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
#   3. THE PROVENANCE GATE IS THE POINT OF THIS LANE, and it is now a
#      mirror, not a check. Root fetches the pinned remote into its own
#      bare repository before every run and builds from THAT. So the lane
#      brings a real remote — a bare repo served by lighttpd +
#      git-http-backend behind HTTP basic auth, exactly the shape GitHub
#      presents — and asserts:
#        - the run uses main's tip AS THE SERVER HAS IT, and follows it
#          when it moves;
#        - the token from /run/agenix is what authenticates the fetch
#          (a wrong token refuses; the credential-helper path is exercised
#          for real, not asserted by string);
#        - an unreachable origin REFUSES — no fallback to the mirror's
#          last contents;
#        - a founder checkout at /home/jonathan/Repos/klaffat, booby-trapped
#          with every jonathan-writable git hook the earlier designs were
#          reproduced tripping (core.fsmonitor, a smudge filter,
#          post-checkout, an exclude-hidden override.tf, a divergent local
#          main), changes NOTHING: no trap fires, no root-owned path
#          appears in it, and OpenTofu plans the remote's content.
#
#   4. The happy path reaches `tofu`, planning the ARCHIVED remote tree —
#      a `canary` output whose value says which tree was read.
#
#   5. Only allowlisted OpenTofu subcommands run at all, `console` is
#      refused by name, and `destroy` (including `apply -destroy`) needs
#      a confirmation typed at a terminal. sudo's prompt names the
#      wrapper, never the subcommand, so without this
#      `yes | sudo klaffat-infra destroy` is one password away from an
#      empty stack.
#
#   6. Each verb sees only the credentials it is entitled to: with the
#      Hetzner token removed, `validate` and `output` still run and `plan`
#      exits 3; with the state passphrase removed, `validate` runs and
#      `output` exits 3.
#
#   7. klaffat-publish's default target is the remote's main; an explicit
#      rev must exist on SOME branch of the remote (a local-only commit is
#      refused); the build addresses the root-only mirror at the exact rev.
#
#   8. klaffat-infra-install refuses anything that is not an IP address
#      (a resolvable hostname like `cafe.beef` used to pass), stages its
#      --extra-files dir on tmpfs under /run and removes it on every exit
#      path, and hands `nix run` a flakeref into the root-only mirror
#      pinned to the verified rev.
#
#   9. What the archive may contain: a commit with a symlink under deploy/
#      is refused before extraction; a commit whose .gitattributes drops a
#      file with export-ignore is refused after it (blob shas compared);
#      and the fixture reads ../cloudflare-ips.json the way hetzner.tf
#      does, so an archive pathspec narrower than deploy/ fails the plan.
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
    "klaffat-github-token"
  ];

  git = "${pkgs.git}/bin/git";
  bin = "/run/current-system/sw/bin";

  # The founder's checkout. The wrappers no longer read it; the lane
  # builds a booby-trapped one here to prove that.
  repo = "/home/jonathan/Repos/klaffat";

  # Root-only state the module owns, and the mirror inside it.
  stateDir = "/var/lib/klaffat-infra";
  mirror = "${stateDir}/klaffat.git";

  # The lane's stand-in for github.com: a bare repo under a root-owned
  # directory, served over HTTP by lighttpd + git-http-backend behind basic
  # auth. That is the property the gate needs — an authority outside
  # anything jonathan writes, reached over the network with a credential —
  # and it is the one part of the real setup a network-less VM cannot
  # borrow.
  originRoot = "/var/lib/klaffat-origin";
  originPort = 8080;
  originUrl = "http://127.0.0.1:${toString originPort}/git/klaffat.git";

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
      # the token secret goes with it; here it is the lane's own
      # basic-auth http origin, so the gate's logic — fetch, authenticate,
      # archive — is exercised end to end with no internet.
      services.klaffatInfra.repoRemoteUrl = originUrl;

      # Swap dellan's host-key-encrypted ciphertexts for fixtures this VM
      # can actually open. `file` (not `rekeyFile`) on both sides, so the
      # only thing that changes is the recipient. The token fixture
      # decrypts to the password the origin below expects.
      age.identityPaths = lib.mkForce [ "${fixtures}/id_ed25519" ];
      age.secrets = lib.genAttrs secretNames (n: {
        file = lib.mkForce "${fixtures}/${n}.age";
      });

      # The origin. `GIT_CONFIG_*` safe.directory because the CGI runs as
      # the lighttpd user against a root-owned repository — that is the
      # test's ownership shape, not production's, where root fetches from
      # GitHub.
      services.lighttpd = {
        enable = true;
        port = originPort;
        document-root = "/var/empty";
        enableModules = [ "mod_alias" "mod_auth" "mod_authn_file" "mod_setenv" "mod_cgi" ];
        extraConfig = ''
          alias.url = ( "/git" => "${pkgs.git}/libexec/git-core/git-http-backend" )
          $HTTP["url"] =~ "^/git" {
            cgi.assign = ( "" => "" )
            setenv.add-environment = (
              "PATH" => "${pkgs.git}/bin:${pkgs.coreutils}/bin",
              "GIT_PROJECT_ROOT" => "${originRoot}",
              "GIT_HTTP_EXPORT_ALL" => "",
              "GIT_CONFIG_COUNT" => "1",
              "GIT_CONFIG_KEY_0" => "safe.directory",
              "GIT_CONFIG_VALUE_0" => "*"
            )
            auth.backend = "plain"
            auth.backend.plain.userfile = "/etc/klaffat-origin-users"
            auth.require = ( "" => ( "method" => "basic", "realm" => "git", "require" => "valid-user" ) )
          }
        '';
      };
      environment.etc."klaffat-origin-users".text = "x-access-token:TEST-github-token\n";
      systemd.tmpfiles.rules = [ "d ${originRoot} 0755 root root -" ];
    })
  ];

  testScript = ''
    import shlex

    start_all()
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("lighttpd.service")
    machine.wait_for_open_port(${toString originPort})

    def run(cmd):
        rc, out = machine.execute(f"timeout 300 {cmd} 2>&1")
        return rc, out.strip()

    # `tofu plan` pads output names to a column, so values are matched on
    # whitespace-squashed text.
    def squash(s):
        return " ".join(s.split())

    def write_file(path, content):
        machine.succeed(f"printf '%s' {shlex.quote(content)} > {path}")

    def state_leftovers():
        _, ls = machine.execute("ls -A ${stateDir} /run")
        return [x for x in ls.split() if x.startswith(("infra-", "publish-", "klaffat-extra-files"))]

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
    #    Some defects are pure string faults no runtime path in this VM
    #    can reach (the Secrets Manager id), and some properties are
    #    universal negatives (no wrapper ever addresses the founder's
    #    tree). Both are asserted on the artifact the founder actually
    #    runs.
    # ---------------------------------------------------------------
    srcs = {
        w: machine.succeed(f"cat $(readlink -f ${bin}/{w})")
        for w in ["klaffat-infra", "klaffat-infra-install", "klaffat-publish"]
    }
    for w, src in srcs.items():
        # Root must never run git inside a repository jonathan owns: that
        # loads jonathan's .git/config, and core.fsmonitor / filter.*.smudge
        # / hooks in there execute as root. `safe.directory` is the switch
        # that re-enables it, so its absence is the property.
        assert "safe.directory" not in src, f"{w} re-enables root git inside a foreign repo"
        assert "worktree add" not in src, f"{w} checks out a worktree (hooks + smudge filters run)"
        assert "/home/jonathan" not in src, f"{w} addresses the founder's home"
        assert "${mirror}" in src, f"{w} does not use the root-only mirror"

    publish_src = srcs["klaffat-publish"]
    assert '--secret-id "${signingKeySecretId}"' in publish_src, (
        "klaffat-publish does not pass the Secrets Manager id Terraform creates "
        "(${signingKeySecretId}); put-secret-value does NOT create a missing "
        "secret, so the signing key never reaches Actions and no closure is signed"
    )
    assert "klaffat/nix-signing-key" not in publish_src, (
        "the old slash-spelled Secrets Manager id is still in klaffat-publish"
    )

    install_src = srcs["klaffat-infra-install"]
    assert 'flakeref="git+file://${mirror}?rev=$rev&allRefs=1"' in install_src, (
        "klaffat-infra-install must address the root-only mirror by a rev-pinned "
        "git flakeref; a bare path flakeref builds working-tree content"
    )

    infra_src = srcs["klaffat-infra"]
    assert "console)" in infra_src and "'console' is not offered" in infra_src, (
        "klaffat-infra must refuse `console` by name"
    )

    # ---------------------------------------------------------------
    # 5. As root, before any origin exists: argv refusals need no
    #    network; everything else refuses because the mirror fetch fails.
    # ---------------------------------------------------------------
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

    # `console` evaluates nonsensitive(var.hcloud_token) and prints it.
    rc, out = run("printf 'nonsensitive(var.hcloud_token)\\n' | ${bin}/klaffat-infra console")
    assert rc == 2, f"console should be refused with exit 2, got {rc}: {out!r}"
    assert "'console' is not offered" in out, f"unexpected console refusal: {out!r}"
    assert "TEST-hcloud-token" not in out, f"console printed the token: {out!r}"

    # `fmt` would rewrite files in a directory the wrapper deletes on exit.
    rc, out = run("${bin}/klaffat-infra fmt")
    assert rc == 2 and "'fmt' is not offered" in out, f"fmt should be refused by name: {rc} {out!r}"

    rc, out = run("${bin}/klaffat-infra plan")
    assert rc == 2, f"fetch-failure refusal should exit 2, got {rc}: {out!r}"
    assert "could not fetch ${originUrl} into the root-only mirror" in out, (
        f"unexpected refusal with no origin: {out!r}"
    )
    assert "OpenTofu" not in out, f"tofu ran without a fetched mirror: {out!r}"

    rc, out = run("${bin}/klaffat-publish")
    assert rc == 2 and "could not fetch ${originUrl}" in out, (
        f"klaffat-publish should refuse when the fetch fails: {rc} {out!r}"
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
    # root has no ssh key; the install wrapper reaches the fresh box through
    # the founder's agent, so SSH_AUTH_SOCK survives env_reset for that ONE
    # command and for nothing else.
    assert 'Defaults!KLAFFAT_INSTALL_CMNDS env_keep += "SSH_AUTH_SOCK"' in sudoers, (
        "the install wrapper's sudo rule must keep SSH_AUTH_SOCK"
    )
    assert "KLAFFAT_INFRA_CMNDS env_keep" not in sudoers, "env_keep leaked onto the OpenTofu/publish rule"
    install_alias = [ln for ln in sudoers.splitlines() if ln.startswith("Cmnd_Alias KLAFFAT_INSTALL_CMNDS")]
    assert len(install_alias) == 1 and "klaffat-infra-install" in install_alias[0], install_alias
    assert "klaffat-publish" not in install_alias[0] and "bin/klaffat-infra " not in install_alias[0] + " ", (
        f"the install alias must name only the install wrapper: {install_alias[0]!r}"
    )

    # ---------------------------------------------------------------
    # 7. THE ORIGIN, and the mirror that follows it.
    #
    #    Content is authored in a root-only work repo and pushed into the
    #    served bare repo, the way commits reach GitHub. The fixture tree
    #    is provider-free so `tofu plan` runs offline without `init`, and
    #    its outputs report which tree was planned and which credentials
    #    the process received.
    # ---------------------------------------------------------------
    src = "/root/klaffat-src"

    def src_git(args):
        return machine.succeed(
            f"${git} -C {src} -c user.email=t@example.invalid -c user.name=t {args}"
        )

    # The fixture reads a file OUTSIDE deploy/terraform exactly the way the
    # real hetzner.tf does (`file("''${path.module}/../cloudflare-ips.json")`),
    # so an archive pathspec narrower than deploy/ fails the plan here
    # instead of on the founder's first credentialed run.
    def tf_fixture(canary):
        return (
            'variable "hcloud_token" {\n  type    = string\n  default = ""\n}\n'
            'variable "state_passphrase" {\n  type    = string\n  default = ""\n}\n'
            'locals {\n  cf = jsondecode(file("''${path.module}/../cloudflare-ips.json"))\n}\n'
            f'output "canary" {{\n  value = "{canary}"\n}}\n'
            'output "cloudflare_ip_count" {\n  value = length(local.cf.ipv4)\n}\n'
            'output "hcloud_token_present" {\n  value = var.hcloud_token != ""\n}\n'
            'output "state_passphrase_present" {\n  value = var.state_passphrase != ""\n}\n'
        )

    cf_ips = '{"ipv4": ["203.0.113.0/24"]}\n'

    machine.succeed(f"install -d -m 0755 {src}/deploy/terraform")
    write_file(f"{src}/deploy/cloudflare-ips.json", cf_ips)
    write_file(f"{src}/deploy/terraform/main.tf", tf_fixture("REMOTE-1"))
    # A flake with no inputs, so klaffat-publish's `nix build` gets past
    # fetching (offline) and fails on the missing attribute — which is how
    # the lane tells "fetched the exact rev from the mirror" from "could
    # not fetch".
    write_file(f"{src}/flake.nix", "{ outputs = { self }: { }; }\n")
    machine.succeed(f"${git} init -q -b main {src}")
    src_git("add -A")
    src_git("commit -q -m 'main 1'")
    rev_a = src_git("rev-parse HEAD").strip()

    machine.succeed("umask 022 && ${git} init -q --bare ${originRoot}/klaffat.git")

    def push_origin():
        machine.succeed(
            "umask 022 && ${git} --git-dir=${originRoot}/klaffat.git "
            f"fetch -q --prune file://{src} '+refs/heads/*:refs/heads/*'"
        )
        # The CGI runs as the lighttpd user.
        machine.succeed("chmod -R a+rX ${originRoot}/klaffat.git")

    push_origin()

    # 7a. Happy path: the mirror is created, main's tip is what the server
    #     has, and OpenTofu plans the archived REMOTE tree.
    rc, out = run("${bin}/klaffat-infra plan -no-color")
    assert rc == 0, f"clean run should succeed, got {rc}: {out!r}"
    assert f"klaffat-infra: ${originUrl} main @ {rev_a}" in out, (
        f"revision line missing or wrong: {out!r}"
    )
    assert 'canary = "REMOTE-1"' in squash(out), f"tofu did not plan the remote tree: {out!r}"
    assert "cloudflare_ip_count = 1" in squash(out), (
        f"the archive did not carry deploy/cloudflare-ips.json (pathspec too narrow?): {out!r}"
    )
    assert "hcloud_token_present = true" in squash(out), f"plan did not receive the provider token: {out!r}"
    assert "state_passphrase_present = true" in squash(out), f"plan did not receive the state passphrase: {out!r}"

    mode = machine.succeed("stat -c '%a %U' ${mirror}").strip()
    assert mode == "700 root", f"the mirror should be 700 root, got '{mode}'"
    mode = machine.succeed("stat -c '%a %U' ${stateDir}/terraform.d").strip()
    assert mode == "700 root", f"TF_DATA_DIR should be 700 root, got '{mode}'"
    tip = machine.succeed("${git} --git-dir=${mirror} rev-parse refs/heads/main").strip()
    assert tip == rev_a, f"mirror main is {tip}, server main is {rev_a}"
    assert state_leftovers() == [], f"a run left artefacts in ${stateDir}: {state_leftovers()!r}"

    # 7b. The token is what authenticates. With the wrong one in
    #     /run/agenix the fetch is refused by the server and the wrapper
    #     refuses — proving the credential helper is the path in use, and
    #     that a 401 does not fall back to the mirror's last contents.
    token_file = machine.succeed("readlink -f /run/agenix/klaffat-github-token").strip()
    machine.succeed(f"printf 'WRONG' > {token_file}")
    rc, out = run("${bin}/klaffat-infra plan -no-color")
    assert rc == 2, f"a wrong token should refuse with exit 2, got {rc}: {out!r}"
    assert "Authentication failed" in out, f"the server did not reject the token: {out!r}"
    assert "could not fetch ${originUrl}" in out, f"unexpected wrong-token refusal: {out!r}"
    assert "REMOTE-1" not in out, f"tofu ran on a stale mirror after a refused fetch: {out!r}"
    machine.succeed(f"printf 'TEST-github-token' > {token_file}")

    # 7c. THE DECOY. A jonathan-owned checkout at the fixed path, carrying
    #     every trap the earlier designs were reproduced tripping. All of
    #     it must be inert: the wrappers never open this repository.
    machine.succeed("install -d -o jonathan -g users /home/jonathan/Repos ${repo}")
    machine.succeed("install -d -o jonathan -g users ${repo}/deploy ${repo}/deploy/terraform")

    def as_jonathan(cmd):
        return machine.succeed(f"runuser -u jonathan -- env HOME=/home/jonathan {cmd}")

    def as_jonathan_git(args):
        return as_jonathan(
            f"${git} -C ${repo} -c user.email=t@example.invalid -c user.name=t {args}"
        )

    write_file("${repo}/deploy/terraform/main.tf", tf_fixture("LOCAL"))
    write_file("${repo}/deploy/cloudflare-ips.json", cf_ips)
    machine.succeed("chown jonathan:users ${repo}/deploy/terraform/main.tf ${repo}/deploy/cloudflare-ips.json")
    as_jonathan("${git} init -q -b main ${repo}")
    as_jonathan_git("add -A")
    as_jonathan_git("commit -q -m 'agent: unreviewed local commit'")
    as_jonathan_git("remote add origin ${originUrl}")
    rev_local = as_jonathan_git("rev-parse HEAD").strip()
    assert rev_local != rev_a

    markers = "/home/jonathan/markers.txt"
    for name, body in [
        ("fsmon.sh", f'echo "core.fsmonitor ran as $(id -un)" >> {markers}\nprintf "/"\n'),
        ("smudge.sh", f'echo "smudge filter ran as $(id -un)" >> {markers}\ncat\n'),
        ("post-checkout", f'echo "post-checkout hook ran as $(id -un)" >> {markers}\n'),
    ]:
        write_file(f"/home/jonathan/{name}", "#!/bin/sh\n" + body)
        machine.succeed(f"chown jonathan:users /home/jonathan/{name} && chmod 755 /home/jonathan/{name}")
    machine.succeed("cp /home/jonathan/post-checkout ${repo}/.git/hooks/post-checkout")
    machine.succeed("chown jonathan:users ${repo}/.git/hooks/post-checkout")
    as_jonathan_git("config core.fsmonitor /home/jonathan/fsmon.sh")
    as_jonathan_git("config filter.evil.smudge /home/jonathan/smudge.sh")
    write_file("${repo}/.git/info/attributes", "* filter=evil\n")
    write_file("${repo}/.git/info/exclude", "deploy/terraform/override.tf\n")
    write_file("${repo}/deploy/terraform/override.tf", 'output "canary" { value = "LOCAL-OVERRIDE" }\n')
    machine.succeed(
        "chown jonathan:users ${repo}/.git/info/attributes ${repo}/.git/info/exclude "
        "${repo}/deploy/terraform/override.tf"
    )

    # Positive control: the traps DO fire when git runs as jonathan in that
    # repository — so "no marker after the wrappers ran" means the wrappers
    # never opened it, not that the fixture is inert. (`execute`, not
    # `succeed`: the fsmonitor stub answers the hook protocol crudely, and
    # git's opinion of that answer is not what is under test.)
    machine.execute(
        "runuser -u jonathan -- env HOME=/home/jonathan ${git} -C ${repo} status --porcelain"
    )
    machine.execute(
        "runuser -u jonathan -- env HOME=/home/jonathan "
        "${git} -C ${repo} worktree add --detach /home/jonathan/wt-control HEAD"
    )
    fired = machine.succeed(f"cat {markers}")
    for trap in [
        "core.fsmonitor ran as jonathan",
        "smudge filter ran as jonathan",
        "post-checkout hook ran as jonathan",
    ]:
        assert trap in fired, f"positive control: {trap!r} did not fire for jonathan's own git: {fired!r}"
    machine.succeed(f"rm -f {markers}")

    rc, out = run("${bin}/klaffat-infra plan -no-color")
    assert rc == 0, f"the decoy must not break the run, got {rc}: {out!r}"
    assert 'canary = "REMOTE-1"' in squash(out), f"tofu did not plan the remote tree: {out!r}"
    assert "LOCAL" not in out, f"the founder's checkout leaked into the plan: {out!r}"
    assert rev_local not in out, f"the local commit was mentioned: {out!r}"

    rc, out = run("${bin}/klaffat-publish")
    assert rc != 0
    assert f"klaffat-publish: building klaffat-demo from {rev_a}" in out, (
        f"klaffat-publish did not default to the REMOTE tip {rev_a}: {out!r}"
    )
    assert rev_local not in out, f"klaffat-publish targeted the local main {rev_local}: {out!r}"

    rc, out = run("${bin}/klaffat-infra-install 10.0.0.1")
    assert rc != 0
    assert f"flakeref git+file://${mirror}?rev={rev_a}&allRefs=1" in out, (
        f"install did not pin the remote tip in the mirror: {out!r}"
    )

    machine.succeed(f"test ! -e {markers}")
    _, root_owned = machine.execute("find ${repo} -user root")
    assert root_owned.strip() == "", (
        f"a wrapper left root-owned paths in the founder's checkout: {root_owned!r}"
    )
    assert state_leftovers() == [], f"runs left artefacts in ${stateDir}: {state_leftovers()!r}"

    # 7d. main moves on the server; the next run follows it.
    write_file(f"{src}/deploy/terraform/main.tf", tf_fixture("REMOTE-2"))
    src_git("add -A")
    src_git("commit -q -m 'main 2'")
    rev_b = src_git("rev-parse HEAD").strip()
    src_git("checkout -q -b hotfix")
    write_file(f"{src}/deploy/terraform/main.tf", tf_fixture("HOTFIX"))
    src_git("add -A")
    src_git("commit -q -m 'hotfix 1'")
    rev_hotfix = src_git("rev-parse HEAD").strip()
    src_git("checkout -q main")
    push_origin()

    rc, out = run("${bin}/klaffat-infra plan -no-color")
    assert rc == 0, f"run after main moved failed: {rc} {out!r}"
    assert f"main @ {rev_b}" in out and 'canary = "REMOTE-2"' in squash(out), (
        f"the mirror did not follow main to {rev_b}: {out!r}"
    )
    assert "HOTFIX" not in out, f"a non-main branch reached tofu: {out!r}"

    # 7e. Origin unreachable: REFUSE. The mirror holds rev_b, and using it
    #     would be exactly the stale-main fallback the design forbids.
    machine.succeed("systemctl stop lighttpd.service")
    rc, out = run("${bin}/klaffat-infra plan -no-color")
    assert rc == 2, f"unreachable origin should refuse with exit 2, got {rc}: {out!r}"
    assert "could not fetch ${originUrl}" in out, f"unexpected offline refusal: {out!r}"
    assert "REMOTE-2" not in out, f"tofu ran on the stale mirror while offline: {out!r}"
    rc, out = run("${bin}/klaffat-publish")
    assert rc == 2 and "could not fetch" in out, f"publish used a stale mirror offline: {rc} {out!r}"
    machine.succeed("systemctl start lighttpd.service")
    machine.wait_for_open_port(${toString originPort})

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
    # Every spelling OpenTofu's Go flag parser accepts for a true boolean,
    # plus the explicit false — the flag is matched by prefix now, because
    # `apply -destroy=1 -auto-approve` walked past a list of spellings.
    for cmd in [
        "destroy", "destroy -auto-approve", "apply -destroy",
        "apply -destroy=1 -auto-approve", "apply -destroy=t", "apply -destroy=T",
        "apply -destroy=TRUE", "apply -destroy=True", "apply --destroy=1", "apply -destroy=false",
    ]:
        rc, out = run(f"yes | setsid --wait timeout 60 ${bin}/klaffat-infra {cmd}")
        assert rc != 124, (
            f"'{cmd}' blocked on a terminal read instead of refusing: {out!r}"
        )
        assert rc == 2, f"'{cmd}' should be refused without a terminal, got {rc}: {out!r}"
        assert "no terminal to confirm at" in out, (
            f"unexpected destroy refusal for '{cmd}': {out!r}"
        )
        assert "OpenTofu" not in out, f"'{cmd}' reached tofu: {out!r}"

    # 8a. WITH a real terminal and `yes` on stdin — the shape of the
    #     original attack. The pipe feeds stdin; the confirmation is read
    #     from /dev/tty, so the pipe never touches it and the typed answer
    #     (here deliberately wrong) is what decides.
    rc, out = run(
        "printf 'no\\n' | timeout 60 script -qec "
        "'yes | ${bin}/klaffat-infra destroy' /dev/null"
    )
    assert rc != 124, f"destroy hung on a pty instead of reading the answer: {out!r}"
    assert "type exactly 'destroy klaffat' to proceed" in out, (
        f"the confirmation prompt never reached the terminal: {out!r}"
    )
    assert "destroy not confirmed — refusing." in out, (
        f"a wrong answer must refuse — the piped `yes` must not count: {out!r}"
    )
    assert "OpenTofu" not in out, f"destroy reached tofu anyway: {out!r}"

    # 8b. …and the right answer, typed, gets through. `apply -destroy
    #     -help` is destroy-flagged (so it must be confirmed) but writes
    #     no state.
    rc, out = run(
        "printf 'destroy klaffat\\n' | timeout 120 script -qec "
        "'${bin}/klaffat-infra apply -destroy -help' /dev/null"
    )
    assert rc != 124, f"the confirmed destroy hung: {out!r}"
    assert "destroy not confirmed" not in out and "no terminal to confirm at" not in out, (
        f"a correctly typed confirmation was still refused: {out!r}"
    )
    assert "Usage: tofu [global options] apply" in out, f"the confirmed command did not reach tofu: {out!r}"
    assert state_leftovers() == [], f"a run left artefacts in ${stateDir}: {state_leftovers()!r}"

    # ---------------------------------------------------------------
    # 9. klaffat-publish: which commits it will build.
    #
    #    The build cannot succeed (the fixture flake has no klaffat-demo
    #    host), and the failure it reaches is the proof: nix reports the
    #    MIRROR flakeref at the exact rev as the flake lacking the
    #    attribute, so the fetch from root's own repository worked.
    # ---------------------------------------------------------------
    rc, out = run("${bin}/klaffat-publish")
    assert rc != 0, "klaffat-publish should fail against a host-less flake"
    assert f"klaffat-publish: building klaffat-demo from {rev_b}" in out, (
        f"publish did not default to the remote's main {rev_b}: {out!r}"
    )
    assert f"git+file://${mirror}?rev={rev_b}" in out and "does not provide attribute" in out, (
        f"nix did not build from the mirror at the exact rev: {out!r}"
    )

    # An explicit rev on ANOTHER branch of the remote is honoured…
    rc, out = run(f"${bin}/klaffat-publish {rev_hotfix}")
    assert rc != 2 and f"klaffat-publish: building klaffat-demo from {rev_hotfix}" in out, (
        f"an explicit rev the server has must be honoured: {rc} {out!r}"
    )
    # …a commit whose branch the server has since deleted is refused even
    # though `fetch --prune` leaves its objects in the mirror…
    machine.succeed("${git} --git-dir=${originRoot}/klaffat.git branch -D hotfix")
    rc, out = run(f"${bin}/klaffat-publish {rev_hotfix}")
    assert rc == 2 and "is not reachable from any current branch" in out, (
        f"a commit on a deleted branch was accepted for publishing: {rc} {out!r}"
    )
    assert "building klaffat-demo" not in out, f"publish reached the build with an unreachable commit: {out!r}"
    # …and a commit the server has never seen is not, however explicitly named.
    rc, out = run(f"${bin}/klaffat-publish {rev_local}")
    assert rc == 2 and f"'{rev_local}' is not a commit on any branch of ${originUrl}" in out, (
        f"a local-only commit was accepted for publishing: {rc} {out!r}"
    )
    assert "building klaffat-demo" not in out, f"publish reached the build with a local commit: {out!r}"
    rc, out = run("${bin}/klaffat-publish no-such-rev")
    assert rc == 2 and "is not a commit on any branch" in out, (
        f"unknown-rev refusal wrong: {rc} {out!r}"
    )

    assert state_leftovers() == [], f"publish left artefacts in ${stateDir}: {state_leftovers()!r}"
    _, root_owned = machine.execute("find ${repo}/.git -user root")
    assert root_owned.strip() == "", (
        f"klaffat-publish left root-owned paths in the founder's .git: {root_owned!r}"
    )
    machine.succeed(f"test ! -e {markers}")
    # And the founder can still use his own worktrees afterwards.
    as_jonathan("${git} -C ${repo} -c core.fsmonitor= worktree add --detach /home/jonathan/wt HEAD")

    # ---------------------------------------------------------------
    # 10. klaffat-infra-install: argument handling, the rev-pinned
    #     flakeref, and the cleanup trap.
    # ---------------------------------------------------------------
    rc, out = run("${bin}/klaffat-infra-install")
    assert rc == 2 and "usage:" in out, f"missing-arg refusal wrong: {rc} {out!r}"

    # Hostnames resolve, and this wrapper ships the demo host's private
    # key to its argument. `cafe.beef` and `dead` are hex-and-dots.
    for bad in ["not-an-ip", "cafe.beef", "dead", "999.1.1.1", "1.2.3", "1.2.3.4.5", "::ffff:1.2.3.4", "10.0.0.1:22"]:
        rc, out = run(f"${bin}/klaffat-infra-install '{bad}'")
        assert rc == 2 and "is not an IP address" in out, (
            f"'{bad}' should be refused as not an IP address: {rc} {out!r}"
        )
        assert "installing klaffat-demo" not in out, f"'{bad}' reached the install: {out!r}"

    # Real staging run. `nix run` cannot succeed here (the fixture flake
    # has no nixos-anywhere), which is exactly the failure the trap has to
    # survive.
    for ip in ["10.0.0.1", "2a01:4f8::1"]:
        rc, out = run(f"${bin}/klaffat-infra-install {ip}")
        assert rc != 0, "install against a host-less flake should fail"
        assert f"installing klaffat-demo onto root@{ip}" in out, (
            f"install did not reach the nixos-anywhere call: {out!r}"
        )
        assert f"flakeref git+file://${mirror}?rev={rev_b}&allRefs=1" in out, (
            f"the flakeref handed to nix run must pin main's tip in the mirror: {out!r}"
        )
    _, leftovers = machine.execute("ls -A ${stateDir} /run")
    assert "klaffat-extra-files" not in leftovers, (
        f"--extra-files staging dir survived a failed install: {leftovers!r}"
    )
    # The staging dir lives on tmpfs, never on the disk-backed state dir.
    assert "/run/klaffat-extra-files." in srcs["klaffat-infra-install"], (
        "the install wrapper must stage --extra-files under /run (tmpfs)"
    )
    assert "${stateDir}/klaffat-extra-files" not in srcs["klaffat-infra-install"]

    # ---------------------------------------------------------------
    # 11. Credentials by verb. Remove a secret and see which verbs still
    #     run: a verb that never instantiates a provider must not need the
    #     provider token; a verb that never touches state must not need
    #     the state credentials.
    # ---------------------------------------------------------------
    def without_secret(name, body):
        machine.succeed(f"mv /run/agenix/{name} /run/agenix/{name}.aside")
        try:
            body()
        finally:
            machine.succeed(f"mv /run/agenix/{name}.aside /run/agenix/{name}")

    def scoped_by_provider_token():
        rc, out = run("${bin}/klaffat-infra validate -no-color")
        assert rc == 0 and "Success!" in out, f"validate should not need the Hetzner token: {rc} {out!r}"
        rc, out = run("${bin}/klaffat-infra output -no-color")
        assert rc == 0, f"output should not need the Hetzner token: {rc} {out!r}"
        rc, out = run("${bin}/klaffat-infra plan -no-color")
        assert rc == 3 and "cannot read /run/agenix/klaffat-hcloud-token" in out, (
            f"plan must require the Hetzner token: {rc} {out!r}"
        )
        assert "canary" not in out, f"plan ran without the provider token: {out!r}"

    def scoped_by_state_passphrase():
        rc, out = run("${bin}/klaffat-infra validate -no-color")
        assert rc == 0 and "Success!" in out, f"validate should not need the state passphrase: {rc} {out!r}"
        rc, out = run("${bin}/klaffat-infra output -no-color")
        assert rc == 3 and "cannot read /run/agenix/klaffat-state-passphrase" in out, (
            f"output must require the state passphrase: {rc} {out!r}"
        )

    without_secret("klaffat-hcloud-token", scoped_by_provider_token)
    without_secret("klaffat-state-passphrase", scoped_by_state_passphrase)

    # And with everything back, version — which gets nothing — still runs.
    rc, out = run("${bin}/klaffat-infra version")
    assert rc == 0 and "OpenTofu v" in out, f"version did not reach tofu: {rc} {out!r}"
    assert state_leftovers() == [], f"runs left artefacts in ${stateDir}: {state_leftovers()!r}"

    # ---------------------------------------------------------------
    # 12. What the archive may contain. Both cases are commits on the
    #     server's main, i.e. inside the trust boundary — this is belt and
    #     braces against a review that lets one through.
    # ---------------------------------------------------------------
    # 12a. A committed symlink under deploy/ is refused before extraction.
    machine.succeed(f"ln -s /etc/hostname {src}/deploy/terraform/link.tf")
    src_git("add -A")
    src_git("commit -q -m 'symlink'")
    push_origin()
    rc, out = run("${bin}/klaffat-infra validate -no-color")
    assert rc == 2 and "has a symlink or submodule under deploy" in out, (
        f"a committed symlink was not refused: {rc} {out!r}"
    )
    assert "Success!" not in out, f"tofu ran on a tree with a symlink: {out!r}"
    assert state_leftovers() == [], f"refusal left artefacts: {state_leftovers()!r}"

    # 12b. A committed .gitattributes that drops a file from the archive is
    #      refused after extraction: the blob shas no longer match the tree.
    machine.succeed(f"rm {src}/deploy/terraform/link.tf")
    write_file(f"{src}/.gitattributes", "deploy/terraform/main.tf export-ignore\n")
    src_git("add -A")
    src_git("commit -q -m 'export-ignore'")
    push_origin()
    rc, out = run("${bin}/klaffat-infra validate -no-color")
    assert rc == 2 and "differs from commit" in out, (
        f"an export-ignore'd archive was not refused: {rc} {out!r}"
    )
    assert "Success!" not in out, f"tofu ran on an incomplete tree: {out!r}"

    # 12c. …and a clean commit runs again.
    machine.succeed(f"rm {src}/.gitattributes")
    src_git("add -A")
    src_git("commit -q -m 'clean again'")
    push_origin()
    rc, out = run("${bin}/klaffat-infra validate -no-color")
    assert rc == 0 and "Success!" in out, f"a clean commit should validate: {rc} {out!r}"
    assert state_leftovers() == [], f"runs left artefacts in ${stateDir}: {state_leftovers()!r}"
  '';
}
