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
#      The ARGUMENTS after the verb are allowlisted per verb too (case 13),
#      because they were an unguarded second input channel into the same
#      credentialed process: `-var` / `-var-file` overrode the committed
#      value, `state push` made root's tofu read a caller-named file,
#      `-plugin-dir` became the only provider search location, and
#      `plan -out=` / `apply <path>` / `show <path>` — checked for a
#      leading slash and nothing else — made root's tofu open ANY absolute
#      path the caller named, O_TRUNC on the write side (reproduced
#      2026-09-06: a canary file and an agenix secret were both replaced by
#      a plan zip, exit 0). Saved plans now live only in one root-only 0700
#      directory under a single name segment, and the lane asserts both
#      halves: the paths outside it are refused with the named file's bytes
#      intact, and a plan saved inside it can still be shown and applied.
#      Every case-13 refusal is an ARGV refusal, so each is asserted to land
#      BEFORE the mirror is fetched — no `main @` line — and never to reach
#      tofu, and the forms the founder needs are asserted to still get
#      through. Refusals LATER in the run do print the provenance line, so
#      the rule that tells a refusal from `plan -detailed-exitcode`'s own
#      exit 2 is the COUNT of `klaffat-infra:` lines: exactly one after a
#      successful run (case 13a), at least two after a refusal past
#      mirror_sync (case 8).
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
#      (a resolvable hostname like `cafe.beef` used to pass), CONFIRMS the
#      target at /dev/tty by requiring the literal `install <ip>` back
#      before the demo host's private key is read or staged, stages its
#      --extra-files dir on tmpfs under /run and removes it on every exit
#      path, and hands `nix run` a flakeref into the root-only mirror
#      pinned to the verified rev.
#
#   9. What the archive may contain: a commit with a symlink under deploy/
#      is refused before extraction; a commit whose .gitattributes drops a
#      file with export-ignore, or merely REWRITES one (`text`/`eol`), is
#      refused after it (raw bytes compared with hash-object
#      --no-filters); and the fixture reads ../cloudflare-ips.json the way
#      hetzner.tf does, so an archive pathspec narrower than deploy/ fails
#      the plan.
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

  # The one directory `plan -out=`, `apply <plan>` and `show <plan>` may
  # name. Round 8 reproduced what the previous rule (any absolute path)
  # allowed: root's tofu opened `-out=/etc/ssh/ssh_host_ed25519_key` with
  # O_TRUNC and replaced it with a plan zip.
  plansDir = "${stateDir}/plans";

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

  localGoogleFixture = "/home/jonathan/worktrees/klaffat-local-google-fixture";
  localGoogleFixtureSecond = "/home/jonathan/worktrees/klaffat-local-google-fixture-second";
  endpointOverrideNames = [
    "KLAFFAT_GOOGLE_AUTH_URL_OVERRIDE"
    "KLAFFAT_GOOGLE_TOKEN_URL_OVERRIDE"
    "KLAFFAT_GOOGLE_JWKS_URL_OVERRIDE"
    "KLAFFAT_GOOGLE_FREEBUSY_URL_OVERRIDE"
    "KLAFFAT_GOOGLE_EVENTS_URL_OVERRIDE"
    "KLAFFAT_GOOGLE_REVOKE_URL_OVERRIDE"
    "KLAFFAT_MS_AUTH_URL_OVERRIDE"
    "KLAFFAT_MS_TOKEN_URL_OVERRIDE"
    "KLAFFAT_MS_JWKS_URL_OVERRIDE"
    "KLAFFAT_MS_EVENTS_URL_OVERRIDE"
    "KLAFFAT_MS_FREEBUSY_URL_OVERRIDE"
    "KLAFFAT_MS_CALENDAR_VIEW_URL_OVERRIDE"
  ];
  fakeGoogleDecryptor = pkgs.writeShellApplication {
    name = "fake-klaffat-google-decryptor";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      set -euo pipefail
      encrypted=""
      for argument in "$@"; do
        encrypted=$argument
      done
      mode=$(cat "$encrypted")
      case "$mode" in
        valid)
          printf '%s\n' \
            'KLAFFAT_GOOGLE_CLIENT_ID=TEST-google-client.apps.googleusercontent.com' \
            'KLAFFAT_GOOGLE_CLIENT_SECRET=TEST-google-secret' \
            'UNRELATED_SECRET=must-not-reach-server'
          ;;
        malformed)
          printf '%s\n' \
            'KLAFFAT_GOOGLE_CLIENT_ID=TEST-google-client.apps.googleusercontent.com' \
            'KLAFFAT_GOOGLE_CLIENT_SECRET=bad value with spaces'
          ;;
        duplicate)
          printf '%s\n' \
            'KLAFFAT_GOOGLE_CLIENT_ID=one' \
            'KLAFFAT_GOOGLE_CLIENT_ID=two' \
            'KLAFFAT_GOOGLE_CLIENT_SECRET=TEST-google-secret'
          ;;
        fail) exit 23 ;;
        hang) sleep 30 ;;
        *) exit 24 ;;
      esac
    '';
  };
  fakeGoogleBuilder = pkgs.writeShellScript "fake-klaffat-google-builder" ''
    set -eu
    test "$#" -eq 1
    if [ "$1" = ${lib.escapeShellArg localGoogleFixture} ] \
        && [ -e /tmp/klaffat-hold-build ]; then
      printf 'entered\n' > /tmp/klaffat-build-entered
      while [ -e /tmp/klaffat-hold-build ]; do
        sleep 0.1
      done
    fi
    exit 0
  '';
  fakeKlaffat = pkgs.writeShellApplication {
    name = "fake-klaffat";
    runtimeInputs = [ pkgs.coreutils pkgs.python3 ];
    text = ''
      set -euo pipefail
      state="''${KLAFFAT_LOCAL_GOOGLE_STATE_DIR:?}"
      if [ "''${1:-}" = migrate ]; then
        if [ -e "$state/hold-migration" ]; then
          printf 'entered\n' > "$state/migration-entered"
          while [ -e "$state/hold-migration" ]; do
            sleep 0.1
          done
        fi
        printf 'migrated\n' > "$state/migrated"
        exit 0
      fi

      required=0
      [ -n "''${KLAFFAT_GOOGLE_CLIENT_ID:-}" ] \
        && [ -n "''${KLAFFAT_GOOGLE_CLIENT_SECRET:-}" ] \
        && required=1
      unrelated=0
      [ -n "''${UNRELATED_SECRET:-}" ] && unrelated=1
      mock=0
      for name in ${lib.concatStringsSep " " endpointOverrideNames}; do
        if printenv "$name" >/dev/null 2>&1; then
          mock=1
        fi
      done
      printf 'required=%s\nunrelated=%s\nmock=%s\n' \
        "$required" "$unrelated" "$mock" > "$state/evidence"

      starts=0
      if [ -f "$state/starts" ]; then
        starts=$(cat "$state/starts")
      fi
      starts=$((starts + 1))
      printf '%s\n' "$starts" > "$state/starts"

      if [ -e "$state/no-health" ]; then
        exec sleep infinity
      fi
      install -d "$state/http"
      printf 'ok\n' > "$state/http/healthz"
      cd "$state/http"
      exec python3 -m http.server "''${PORT:?}" --bind 127.0.0.1
    '';
  };
in
common.mkMinimalTest {
  name = "klaffat-infra";

  extraModules = [
    ../modules/nixos/klaffat-infra.nix
    ../modules/nixos/klaffat-local-google.nix
    (_: {
      services.klaffatInfra.enable = true;
      services.klaffatLocalGoogle = {
        enable = true;
        decryptProgram = "${fakeGoogleDecryptor}/bin/fake-klaffat-google-decryptor";
        decryptTimeoutSeconds = 1;
        buildProgram = "${fakeGoogleBuilder}";
        healthAttempts = 3;
      };
      systemd.services.klaffat-local-google.environment =
        lib.genAttrs endpointOverrideNames (_: "http://mock.invalid");

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

    # ---------------------------------------------------------------
    # Local real-Google capability. The operator controls one fixed unit;
    # root alone decrypts; only the dedicated server account sees the pair.
    # ---------------------------------------------------------------
    machine.succeed("test -x ${bin}/klaffat-local-google")
    machine.succeed(
        "install -d -m 0755 -o jonathan -g users "
        "${localGoogleFixture}/target/local-google/debug "
        "${localGoogleFixture}/crates/klaffat-web/static "
        "${localGoogleFixture}/deploy/secrets "
        "${localGoogleFixture}/tests/e2e/fixtures"
    )
    machine.succeed(
        "install -m 0755 -o jonathan -g users "
        "${fakeKlaffat}/bin/fake-klaffat "
        "${localGoogleFixture}/target/local-google/debug/klaffat"
    )
    write_file("${localGoogleFixture}/crates/klaffat-web/static/app.css", "body {}\n")
    write_file("${localGoogleFixture}/deploy/secrets/klaffat-env.age", "valid\n")
    write_file("${localGoogleFixture}/tests/e2e/fixtures/test-kek", "0123456789abcdef0123456789abcdef")
    machine.succeed("chown -R jonathan:users ${localGoogleFixture}")
    machine.succeed(
        "runuser -u jonathan -- ${git} -C ${localGoogleFixture} init -q && "
        "runuser -u jonathan -- ${git} -C ${localGoogleFixture} remote add origin "
        "https://github.com/jonathanmoregard/klaffat.git"
    )

    rc, out = run(
        "runuser -u jonathan -- ${bin}/klaffat-local-google "
        "start ${localGoogleFixture}"
    )
    assert rc == 0, f"operator could not start local Google Klaffat: {rc} {out!r}"
    assert "http://localhost:3740" in out, f"launcher did not report the URL: {out!r}"
    machine.wait_for_unit("klaffat-local-google.service")
    machine.wait_for_open_port(3740)
    assert machine.succeed("curl -fsS http://localhost:3740/healthz").strip() == "ok"

    evidence = machine.succeed("cat /var/lib/klaffat-local-google/evidence")
    assert evidence == "required=1\nunrelated=0\nmock=0\n", evidence
    env_names = machine.succeed(
        "cut -d= -f1 /run/klaffat-local-google/google.env | sort"
    )
    assert env_names == "KLAFFAT_GOOGLE_CLIENT_ID\nKLAFFAT_GOOGLE_CLIENT_SECRET\n", env_names
    assert machine.succeed(
        "stat -c '%U:%G:%a' /run/klaffat-local-google/google.env"
    ).strip() == "root:root:400"
    assert machine.succeed(
        "stat -c '%U:%G:%a' /var/lib/klaffat-local-google"
    ).strip() == "klaffat-local-google:klaffat-local-google:700"

    pid = machine.succeed(
        "systemctl show -p MainPID --value klaffat-local-google.service"
    ).strip()
    assert machine.succeed(f"ps -o user= -p {pid}").strip() == "klaffat-local-google"
    rc, _ = run(f"runuser -u jonathan -- cat /proc/{pid}/environ")
    assert rc != 0, "jonathan could read the server process environment"
    rc, _ = run("runuser -u jonathan -- cat /run/klaffat-local-google/google.env")
    assert rc != 0, "jonathan could read the root-only Google environment"
    rc, _ = run("runuser -u jonathan -- cat /var/lib/klaffat-local-google/evidence")
    assert rc != 0, "jonathan could traverse the isolated server state"

    rc, out = run("runuser -u jonathan -- ${bin}/klaffat-local-google status")
    assert rc == 0 and "active (running)" in out, f"status failed: {rc} {out!r}"
    rc, out = run(
        "runuser -u jonathan -- systemctl --no-ask-password restart lighttpd.service"
    )
    assert rc != 0, f"polkit rule allowed an unrelated unit: {out!r}"

    # Restart preserves local state while redoing the root-only preparation.
    rc, out = run(
        "runuser -u jonathan -- ${bin}/klaffat-local-google "
        "start ${localGoogleFixture}"
    )
    assert rc == 0, f"second start failed: {rc} {out!r}"
    assert machine.succeed("cat /var/lib/klaffat-local-google/starts").strip() == "2"
    assert machine.succeed(
        "runuser -u postgres -- psql -Atc \"select datname from pg_database "
        "where datname = 'klaffat-local-google'\""
    ).strip() == "klaffat-local-google"
    machine.fail("ss -ltn | grep -q ':5432 '")

    rc, out = run("runuser -u jonathan -- ${bin}/klaffat-local-google stop")
    assert rc == 0, f"operator could not stop fixed unit: {rc} {out!r}"
    machine.wait_until_fails("curl -fsS --max-time 1 http://localhost:3740/healthz")

    # A different process answering the same health URL must never make the
    # launcher report its own failed unit as ready. Reproduce the real-host
    # collision with a competing server, then require readiness to remain
    # bound to the dedicated systemd unit as well as the HTTP probe.
    machine.succeed("install -d /tmp/klaffat-competing-health")
    write_file("/tmp/klaffat-competing-health/healthz", "ok\n")
    machine.succeed(
        "systemd-run --unit=klaffat-competing-health.service --collect "
        "--property=WorkingDirectory=/tmp/klaffat-competing-health "
        "${pkgs.python3}/bin/python3 -m http.server 3740 --bind 127.0.0.1"
    )
    machine.wait_for_open_port(3740)
    rc, out = run(
        "runuser -u jonathan -- ${bin}/klaffat-local-google "
        "start ${localGoogleFixture}"
    )
    assert rc == 1, f"competing health server caused false readiness: {rc} {out!r}"
    assert "port 3740 is already in use" in out, out
    assert machine.succeed(
        "systemctl show -p ActiveState --value klaffat-local-google.service"
    ).strip() != "active"
    machine.succeed("systemctl stop klaffat-competing-health.service")
    machine.wait_until_fails("curl -fsS --max-time 1 http://localhost:3740/healthz")

    # The unprivileged origin check catches a mistaken directory before root
    # receives a restart request.
    machine.succeed(
        "runuser -u jonathan -- ${git} -C ${localGoogleFixture} remote set-url origin "
        "https://example.invalid/not-klaffat.git"
    )
    rc, out = run(
        "runuser -u jonathan -- ${bin}/klaffat-local-google "
        "start ${localGoogleFixture}"
    )
    assert rc == 2 and "unexpected origin" in out, f"wrong origin passed: {rc} {out!r}"
    machine.succeed(
        "runuser -u jonathan -- ${git} -C ${localGoogleFixture} remote set-url origin "
        "https://github.com/jonathanmoregard/klaffat.git"
    )

    # Root preparation refuses linked executables and every decryptor failure
    # without leaving a consumable environment behind.
    machine.succeed(
        "mv ${localGoogleFixture}/target/local-google/debug/klaffat "
        "${localGoogleFixture}/target/local-google/debug/klaffat.real && "
        "ln -s klaffat.real ${localGoogleFixture}/target/local-google/debug/klaffat && "
        "chown -h jonathan:users ${localGoogleFixture}/target/local-google/debug/klaffat"
    )
    rc, out = run(
        "runuser -u jonathan -- ${bin}/klaffat-local-google "
        "start ${localGoogleFixture}"
    )
    assert rc != 0, f"linked application binary passed root preparation: {out!r}"
    machine.succeed(
        "rm ${localGoogleFixture}/target/local-google/debug/klaffat && "
        "mv ${localGoogleFixture}/target/local-google/debug/klaffat.real "
        "${localGoogleFixture}/target/local-google/debug/klaffat"
    )

    for mode in ["malformed", "duplicate", "fail", "hang"]:
        write_file("${localGoogleFixture}/deploy/secrets/klaffat-env.age", mode + "\n")
        machine.succeed(
            "chown jonathan:users ${localGoogleFixture}/deploy/secrets/klaffat-env.age"
        )
        rc, out = run(
            "runuser -u jonathan -- ${bin}/klaffat-local-google "
            "start ${localGoogleFixture}"
        )
        assert rc != 0, f"decrypt mode {mode!r} should fail closed: {out!r}"
        assert machine.succeed(
            "systemctl show -p NRestarts --value klaffat-local-google.service"
        ).strip() == "0", f"decrypt mode {mode!r} retried root preparation"
        assert "TEST-google-secret" not in out, f"secret leaked for {mode}: {out!r}"
        machine.fail("test -e /run/klaffat-local-google/google.env")

    # Launcher health polling is bounded and fails loudly if the process never
    # exposes /healthz.
    write_file("${localGoogleFixture}/deploy/secrets/klaffat-env.age", "valid\n")
    machine.succeed("chown jonathan:users ${localGoogleFixture}/deploy/secrets/klaffat-env.age")
    machine.succeed("touch /var/lib/klaffat-local-google/no-health")
    rc, out = run(
        "runuser -u jonathan -- ${bin}/klaffat-local-google "
        "start ${localGoogleFixture}"
    )
    assert rc == 1 and "did not become healthy" in out, f"health timeout wrong: {rc} {out!r}"
    machine.succeed("rm /var/lib/klaffat-local-google/no-health")
    machine.succeed("systemctl stop klaffat-local-google.service")

    # Close-out review reproducers: all three outcomes below violate the
    # launcher's claim that its ready message identifies the selected unit.
    # Collect them before asserting so a red run records every race at once.
    false_readiness = []

    # localhost can prefer a competing IPv6-only listener even while the
    # selected service owns a healthy IPv4 listener.
    machine.succeed("install -d /tmp/klaffat-ipv6-health")
    write_file("/tmp/klaffat-ipv6-health/healthz", "ok\n")
    machine.succeed(
        "systemd-run --unit=klaffat-ipv6-health.service --collect "
        "--property=WorkingDirectory=/tmp/klaffat-ipv6-health "
        "${pkgs.python3}/bin/python3 -m http.server 3740 --bind ::1"
    )
    machine.wait_until_succeeds(
        "curl --noproxy '*' -gfsS http://[::1]:3740/healthz"
    )
    rc, out = run(
        "runuser -u jonathan -- ${bin}/klaffat-local-google "
        "start ${localGoogleFixture}"
    )
    if rc == 0:
        false_readiness.append("ipv6-listener")
    machine.succeed("systemctl stop klaffat-local-google.service")
    machine.succeed("systemctl stop klaffat-ipv6-health.service")

    # A competing IPv4 server that appears after the launcher's precheck can
    # satisfy HTTP while the real app is still blocked in its migration.
    machine.succeed("touch /var/lib/klaffat-local-google/hold-migration")
    machine.succeed(
        "systemd-run --unit=klaffat-race-launch.service "
        "--property=User=jonathan ${bin}/klaffat-local-google "
        "start ${localGoogleFixture}"
    )
    machine.wait_for_file("/var/lib/klaffat-local-google/migration-entered")
    machine.succeed(
        "systemd-run --unit=klaffat-race-health.service --collect "
        "--property=WorkingDirectory=/tmp/klaffat-competing-health "
        "${pkgs.python3}/bin/python3 -m http.server 3740 --bind 127.0.0.1"
    )
    machine.wait_for_open_port(3740)
    machine.wait_until_succeeds(
        "! systemctl is-active --quiet klaffat-race-launch.service"
    )
    if machine.succeed(
        "systemctl show -p ExecMainStatus --value klaffat-race-launch.service"
    ).strip() == "0":
        false_readiness.append("post-precheck-ipv4-listener")
    machine.succeed("systemctl stop klaffat-local-google.service")
    machine.succeed("systemctl stop klaffat-race-health.service")
    machine.succeed(
        "rm /var/lib/klaffat-local-google/hold-migration "
        "/var/lib/klaffat-local-google/migration-entered"
    )

    # A second selection must cancel an in-flight activation. Otherwise both
    # launchers join the first job and the second reports the wrong worktree.
    machine.succeed(
        "cp -a ${localGoogleFixture} ${localGoogleFixtureSecond} && "
        "chown -R jonathan:users ${localGoogleFixtureSecond}"
    )
    machine.succeed(
        "install -d /run/systemd/system/klaffat-local-google.service.d"
    )
    write_file(
        "/run/systemd/system/klaffat-local-google.service.d/hold.conf",
        "[Service]\nExecStartPre=${pkgs.coreutils}/bin/sleep 3\n",
    )
    machine.succeed("systemctl daemon-reload")
    machine.succeed(
        "systemd-run --unit=klaffat-first-selection.service "
        "--property=User=jonathan ${bin}/klaffat-local-google "
        "start ${localGoogleFixture}"
    )
    machine.wait_until_succeeds(
        "test $(systemctl show -p ActiveState --value klaffat-local-google.service) = activating "
        "&& test $(cat /run/klaffat-local-google/prepared/source-worktree) "
        "= ${localGoogleFixture}"
    )
    rc, out = run(
        "runuser -u jonathan -- ${bin}/klaffat-local-google "
        "start ${localGoogleFixtureSecond}"
    )
    selected = machine.succeed(
        "cat /run/klaffat-local-google/prepared/source-worktree"
    ).strip()
    if rc != 0 or selected != "${localGoogleFixtureSecond}":
        false_readiness.append("activating-selection")
    machine.succeed("systemctl stop klaffat-local-google.service")
    machine.succeed(
        "rm /run/systemd/system/klaffat-local-google.service.d/hold.conf && "
        "systemctl daemon-reload"
    )

    # An older invocation paused during its build must not overtake a newer
    # selection. Serializing the whole start transaction makes invocation
    # order, the prepared worktree, and each ready message agree.
    machine.succeed("touch /tmp/klaffat-hold-build")
    machine.succeed(
        "systemd-run --unit=klaffat-held-build.service "
        "--property=User=jonathan ${bin}/klaffat-local-google "
        "start ${localGoogleFixture}"
    )
    machine.wait_for_file("/tmp/klaffat-build-entered")
    machine.succeed(
        "systemd-run --unit=klaffat-newer-selection.service "
        "--property=User=jonathan ${bin}/klaffat-local-google "
        "start ${localGoogleFixtureSecond}"
    )
    machine.sleep(1)
    newer_waited = machine.execute(
        "systemctl is-active --quiet klaffat-newer-selection.service"
    )[0] == 0
    machine.succeed("rm /tmp/klaffat-hold-build")
    machine.wait_until_succeeds(
        "! systemctl is-active --quiet klaffat-newer-selection.service"
    )
    machine.wait_until_succeeds(
        "! systemctl is-active --quiet klaffat-held-build.service"
    )
    selected = machine.succeed(
        "cat /run/klaffat-local-google/prepared/source-worktree"
    ).strip()
    old_status = machine.succeed(
        "systemctl show -p ExecMainStatus --value klaffat-held-build.service"
    ).strip()
    new_status = machine.succeed(
        "systemctl show -p ExecMainStatus --value klaffat-newer-selection.service"
    ).strip()
    if (
        not newer_waited
        or old_status != "0"
        or new_status != "0"
        or selected != "${localGoogleFixtureSecond}"
    ):
        false_readiness.append("overlapping-selection")
    machine.succeed("systemctl stop klaffat-local-google.service")
    machine.succeed(
        "rm /tmp/klaffat-build-entered"
    )

    assert not false_readiness, (
        "launcher reported false readiness in: " + ", ".join(false_readiness)
    )

    # A LEFTOVER is a per-run TEMPORARY that outlived its trap: the archive
    # directory (`infra-*`), klaffat-publish's scratch (`publish-*`), the
    # install wrapper's --extra-files staging dir. This is an allowlist of
    # those three name prefixes, so the durable state the module owns —
    # `klaffat.git`, `terraform.d`, and as of round 8 `plans` and the plan
    # files inside it — is not a leftover and never counts as one. That is
    # deliberate for `plans`, not incidental: saved plans are the one thing
    # a run is MEANT to leave behind (the wrapper never empties the
    # directory; see the module header's residual (2)), and case 13a's
    # positive control leaves one there for every later assertion to see.
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
    #
    # That is a claim about the WHOLE sudoers file, not about the line this
    # module emits, and greping for the module's own line could never have
    # falsified it: nixpkgs emits a GLOBAL `env_keep+=SSH_AUTH_SOCK` under
    # `security.pam.sshAgentAuth`, which dellan does not enable today.
    # Enabling it anywhere would keep the variable for every sudo command on
    # the laptop while the command-scoped line below still read correctly.
    # So collect every line that keeps it, and assert the list is exactly
    # the one.
    ssh_sock_lines = [
        ln.strip() for ln in sudoers.splitlines()
        if "env_keep" in ln and "SSH_AUTH_SOCK" in ln
    ]
    assert ssh_sock_lines == ['Defaults!KLAFFAT_INSTALL_CMNDS env_keep += "SSH_AUTH_SOCK"'], (
        "SSH_AUTH_SOCK must survive env_reset for the install command and for nothing "
        f"else (security.pam.sshAgentAuth would widen it); sudoers keeps it on: {ssh_sock_lines!r}"
    )
    assert "KLAFFAT_INFRA_CMNDS env_keep" not in sudoers, "env_keep leaked onto the OpenTofu/publish rule"

    # The alias body is `concatStringsSep ", "`, so every element but the
    # last carries a trailing comma — which is why testing the JOINED line
    # for `bin/klaffat-infra ` only ever caught a klaffat-infra appended
    # LAST. Split the body and check each command in it.
    install_alias = [ln for ln in sudoers.splitlines() if ln.startswith("Cmnd_Alias KLAFFAT_INSTALL_CMNDS")]
    assert len(install_alias) == 1, install_alias
    alias_cmds = [c.strip() for c in install_alias[0].split("=", 1)[1].split(", ")]
    assert alias_cmds and all(c.endswith("/bin/klaffat-infra-install") for c in alias_cmds), (
        f"the install alias must name only klaffat-infra-install: {alias_cmds!r}"
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

    # The install wrapper confirms its TARGET at /dev/tty (case 10), so the
    # flakeref line is only reached with the phrase typed on a pty.
    rc, out = run(
        "printf 'install 10.0.0.1\\n' | timeout 180 script -qec "
        "'${bin}/klaffat-infra-install 10.0.0.1' /dev/null"
    )
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
        # THE `-detailed-exitcode` RULE, refusal half. This refusal happens
        # AFTER mirror_sync, so it prints the provenance line FIRST and then
        # its own — which is why "a refusal never prints `main @`" was false
        # and is no longer claimed anywhere. What is true, and what tells a
        # refusal from tofu's own exit 2, is the COUNT: a successful run has
        # exactly one `klaffat-infra:` line (13a asserts that half), a
        # refusal past this point has at least two.
        infra_lines = [ln for ln in out.splitlines() if ln.startswith("klaffat-infra:")]
        assert len(infra_lines) >= 2, (
            f"'{cmd}' refused after mirror_sync must print the provenance line AND a "
            f"refusal line; got {infra_lines!r}"
        )
        assert any("main @" in ln for ln in infra_lines), (
            f"'{cmd}' refused after mirror_sync without the provenance line: {infra_lines!r}"
        )

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
    # 10. klaffat-infra-install: argument handling, the /dev/tty
    #     confirmation of the TARGET, the rev-pinned flakeref, and the
    #     cleanup trap.
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

    # 10a. NO TERMINAL, NO INSTALL. This wrapper writes the demo host's
    #      PRIVATE ssh identity into a staging dir and hands it, with root
    #      on a fresh machine, to whatever answers at the address in argv.
    #      The IP check above proves the argument is an address; only the
    #      founder can say it is the RIGHT address. So the target is
    #      confirmed at /dev/tty, exactly like `destroy` — and `setsid
    #      --wait` here for exactly the reason case 8 explains: the driver's
    #      backdoor shell HAS a controlling terminal on /dev/hvc0, and a
    #      prompt written to it desynchronises the driver protocol.
    for ip in ["10.0.0.1", "2a01:4f8::1"]:
        rc, out = run(f"yes | setsid --wait timeout 60 ${bin}/klaffat-infra-install {ip}")
        assert rc != 124, (
            f"install blocked on a terminal read instead of refusing ({ip}): {out!r}"
        )
        assert rc == 2, f"install without a terminal should exit 2 ({ip}), got {rc}: {out!r}"
        assert "no terminal to confirm at" in out, f"unexpected install refusal ({ip}): {out!r}"
        assert "installing klaffat-demo" not in out, (
            f"an unconfirmed install proceeded ({ip}): {out!r}"
        )
    assert state_leftovers() == [], (
        f"a refused install staged something anyway: {state_leftovers()!r}"
    )

    # 10b. WITH a terminal and the WRONG phrase: refused, nothing staged.
    rc, out = run(
        "printf 'no\\n' | timeout 60 script -qec "
        "'${bin}/klaffat-infra-install 10.0.0.1' /dev/null"
    )
    assert rc != 124, f"install hung on a pty instead of reading the answer: {out!r}"
    assert "type exactly 'install 10.0.0.1' to proceed" in out, (
        f"the confirmation prompt never reached the terminal: {out!r}"
    )
    assert "install not confirmed" in out, f"a wrong answer must refuse: {out!r}"
    assert "installing klaffat-demo" not in out, f"a refused install proceeded: {out!r}"
    assert state_leftovers() == [], (
        f"a refused install staged something anyway: {state_leftovers()!r}"
    )

    # 10c. The right phrase — the literal IP, retyped — gets through, and
    #      `nix run` then fails on the fixture flake (no nixos-anywhere),
    #      which is exactly the failure the cleanup trap has to survive.
    for ip in ["10.0.0.1", "2a01:4f8::1"]:
        rc, out = run(
            f"printf 'install {ip}\\n' | timeout 180 script -qec "
            f"'${bin}/klaffat-infra-install {ip}' /dev/null"
        )
        assert rc != 124, f"the confirmed install hung ({ip}): {out!r}"
        assert "install not confirmed" not in out and "no terminal to confirm at" not in out, (
            f"a correctly typed confirmation was still refused ({ip}): {out!r}"
        )
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

    # 12c. …and so is a .gitattributes that merely REWRITES the bytes.
    #      export-ignore is not the only attribute `git archive` honours:
    #      `text`/`eol` rewrite line endings, `ident` substitutes the blob
    #      sha, `export-subst` expands `$Format:…$` and `filter` runs a
    #      smudge command. Measured with git 2.55.0 on 2026-09-06 in a
    #      scratch bare repo: `* text=auto eol=crlf` under deploy/ makes
    #      `git archive` write CRLF where the blob holds LF, so what tofu
    #      would read is NOT what the commit says. `hash-object
    #      --no-filters` compares raw bytes, so it refuses.
    machine.succeed(f"rm {src}/.gitattributes")
    write_file(f"{src}/deploy/.gitattributes", "* text=auto eol=crlf\n")
    src_git("add -A")
    src_git("commit -q -m 'eol=crlf'")
    push_origin()
    rc, out = run("${bin}/klaffat-infra validate -no-color")
    assert rc == 2 and "differs from commit" in out, (
        f"an eol-rewriting .gitattributes was not refused: {rc} {out!r}"
    )
    assert "text/eol" in out, (
        f"the refusal must name the attribute classes that cause it: {out!r}"
    )
    assert "Success!" not in out, f"tofu ran on a rewritten tree: {out!r}"

    # 12d. …and a clean commit runs again.
    machine.succeed(f"rm {src}/deploy/.gitattributes")
    src_git("add -A")
    src_git("commit -q -m 'clean again'")
    push_origin()
    rc, out = run("${bin}/klaffat-infra validate -no-color")
    assert rc == 0 and "Success!" in out, f"a clean commit should validate: {rc} {out!r}"
    assert state_leftovers() == [], f"runs left artefacts in ${stateDir}: {state_leftovers()!r}"

    # ---------------------------------------------------------------
    # 13. ARGV AFTER THE VERB IS ALLOWLISTED, PER VERB.
    #
    #     `tofu "$@"` used to hand root's OpenTofu every argument after the
    #     verb. Reproduced 2026-09-06 against the real generated wrapper:
    #     `-var`/`-var-file` override the value the committed tfvars
    #     authored (and `apply -auto-approve -var …` commits it),
    #     `state push` makes root's tofu READ a caller-named file,
    #     `init -plugin-dir=` becomes the only provider search location and
    #     `init -from-module=` copies code from outside the verified commit
    #     into the working directory.
    #
    #     Each refusal below must cost exit 2, must happen BEFORE the mirror
    #     is touched (so no `main @` line) and must never reach tofu.
    #
    #     The plan-path rows are round 8's. `-out=`, `apply <path>` and
    #     `show <path>` were checked for a LEADING SLASH and nothing else,
    #     so root's tofu opened any absolute path the caller named:
    #     reproduced 2026-09-06 against the real generated wrapper,
    #     `plan -out=/etc/ssh/ssh_host_ed25519_key` exited 0 having replaced
    #     a 35-byte canary file with a 1526-byte plan zip, and
    #     `-out=/run/agenix/<secret>` replaced the wrapper's own secret the
    #     same way. Saved plans now live in exactly one root-only 0700
    #     directory under a single name segment, so `..`, a subdirectory, a
    #     dotfile, a trailing slash and every path outside it are refused by
    #     the same lexical rule.
    # ---------------------------------------------------------------
    write_file("/root/evil.tfvars", 'canary = "ATTACKER"\n')
    write_file("/root/evil.tfstate", '{"version": 4}\n')
    machine.succeed("install -d -m 0700 /root/plugins /root/m")

    for args in [
        "plan -no-color -var github_repo=attacker/x",
        "plan -var=github_repo=attacker/x",
        "plan -var-file=/root/evil.tfvars",
        "init -plugin-dir=/root/plugins",
        "init -backend-config=bucket=x",
        "init -from-module=/root/m",
        "state push /root/evil.tfstate",
        "plan -target null_resource.x",
        "plan -- -var",
        "apply relative.tfplan",
        "plan -out=relative.tfplan",
        "plan -bogus",
        "workspace new x",
        "providers mirror /root/m",
        # Round 8: a plan path is the plans directory plus ONE name.
        "plan -no-color -out=/etc/ssh/ssh_host_ed25519_key",
        "plan -no-color -out=/dev/null",
        "plan -no-color -out=/run/agenix/klaffat-hcloud-token",
        "plan -no-color -out=/root/r7.tfplan",
        "plan -no-color -out=${plansDir}/../r7.tfplan",
        "plan -no-color -out=${plansDir}/sub/r7.tfplan",
        "plan -no-color -out=${plansDir}/.hidden",
        "plan -no-color -out=${plansDir}/",
        "apply -no-color /etc/passwd",
        "show -no-color /run/agenix/klaffat-hcloud-token",
        "show -no-color ${plansDir}/../klaffat.git/HEAD",
    ]:
        rc, out = run(f"${bin}/klaffat-infra {args}")
        assert rc == 2, f"'{args}' should be refused with exit 2, got {rc}: {out!r}"
        assert "main @" not in out, (
            f"'{args}' was checked only after the mirror was fetched: {out!r}"
        )
        assert "OpenTofu" not in out, f"'{args}' reached tofu: {out!r}"
        assert "klaffat-infra:" in out, f"'{args}' refused without saying why: {out!r}"
        assert "ATTACKER" not in out, f"'{args}' let a caller-supplied value through: {out!r}"
    assert state_leftovers() == [], f"an argv refusal left artefacts: {state_leftovers()!r}"

    # The refusal has to teach the RULE — the directory and the name shape —
    # not just say no to this one path, because the founder's next attempt
    # is otherwise another guess.
    rc, out = run("${bin}/klaffat-infra plan -no-color -out=/etc/ssh/ssh_host_ed25519_key")
    assert "is not a plan path" in out, f"the plan-path refusal must name what it wants: {out!r}"
    assert "${plansDir}/<name>" in out, (
        f"the refusal must name the plans directory: {out!r}"
    )
    assert "no subdirectories" in out, f"the refusal must name the name rule: {out!r}"

    # …and the PROPERTY, measured rather than inferred: the file the caller
    # named still holds its own bytes. This is the repro's scenario 1a/1b —
    # at 4d3d73c the canary and the agenix secret were both replaced by a
    # plan zip, exit 0.
    write_file("/root/victim.txt", "canary-bytes-do-not-truncate\n")
    victim_before = machine.succeed("cat /root/victim.txt")
    rc, out = run("${bin}/klaffat-infra plan -no-color -out=/root/victim.txt")
    assert rc == 2, f"-out=<outside the plans dir> should be refused, got {rc}: {out!r}"
    assert machine.succeed("cat /root/victim.txt") == victim_before, (
        "root's tofu opened the caller-named path with O_TRUNC: "
        f"{machine.succeed('cat /root/victim.txt')!r}"
    )
    assert machine.succeed("cat /run/agenix/klaffat-hcloud-token").strip() == "TEST-hcloud-token", (
        "the wrapper's own agenix secret was overwritten through -out="
    )
    # The directory itself is root-only and, so far, empty: every refusal
    # above happened before tofu could write anything anywhere.
    mode = machine.succeed("stat -c '%U:%a' ${plansDir}").strip()
    assert mode == "root:700", f"the plans dir must be root:700, got '{mode}'"
    assert machine.succeed("ls -A ${plansDir}").strip() == "", (
        "a refused -out= wrote into the plans directory anyway"
    )

    # 13a. …and the forms the founder actually needs still reach tofu.
    rc, out = run("${bin}/klaffat-infra plan -no-color")
    assert rc == 0 and 'canary = "REMOTE-2"' in squash(out), (
        f"the plain plan must still plan the committed values: {rc} {out!r}"
    )
    # THE `-detailed-exitcode` RULE, success half. `plan -detailed-exitcode`
    # exits 2 for "there are changes", the same code every refusal uses, and
    # what tells them apart is that a SUCCESSFUL run prints exactly one
    # `klaffat-infra:` line — the provenance line — while a refusal prints
    # at least one more (case 8 asserts that half). The rule the module used
    # to state, "a refusal never prints `main @`", was measured false: a
    # refusal past mirror_sync prints it first.
    infra_lines = [ln for ln in out.splitlines() if ln.startswith("klaffat-infra:")]
    assert len(infra_lines) == 1, (
        f"a successful run must print exactly one klaffat-infra: line, the provenance "
        f"line; got {infra_lines!r}"
    )
    assert "main @" in infra_lines[0], (
        f"the one klaffat-infra: line on a successful run must be the provenance line: "
        f"{infra_lines[0]!r}"
    )

    # A single-token `-target=` is allowed. tofu's own "Resource targeting
    # is in effect" warning is the proof the flag reached it.
    rc, out = run("${bin}/klaffat-infra plan -no-color -target=null_resource.nothing")
    assert "Resource targeting is in effect" in out, (
        f"-target=ADDR did not reach tofu: {rc} {out!r}"
    )

    # plan -out= / show / apply, all naming a file in the ONE directory the
    # wrapper offers. Until round 8 this control saved to /root/r7.tfplan
    # and any absolute path was accepted; that path is now in the refusal
    # list above, and the plan lives here instead.
    rc, out = run("${bin}/klaffat-infra plan -no-color -out=${plansDir}/r7.tfplan")
    assert rc == 0 and "Saved the plan to: ${plansDir}/r7.tfplan" in out, (
        f"plan -out=<plans dir> did not save a plan: {rc} {out!r}"
    )
    machine.succeed("test -f ${plansDir}/r7.tfplan")
    # 0700 on the directory and 0600 on the file, both root: the plan is
    # encrypted with the state passphrase, but jonathan should not be able
    # to so much as list what the founder has planned.
    mode = machine.succeed("stat -c '%U:%a' ${plansDir}").strip()
    assert mode == "root:700", f"the plans dir must be root:700, got '{mode}'"
    mode = machine.succeed("stat -c '%U:%a' ${plansDir}/r7.tfplan").strip()
    assert mode == "root:600", f"a saved plan must be root:600, got '{mode}'"

    rc, out = run("${bin}/klaffat-infra show -no-color ${plansDir}/r7.tfplan")
    assert rc == 0 and "REMOTE-2" in out, f"show <saved plan> did not reach tofu: {rc} {out!r}"
    rc, out = run("${bin}/klaffat-infra apply -no-color ${plansDir}/r7.tfplan")
    assert "Apply complete!" in out, (
        f"apply <saved plan> did not reach tofu: {rc} {out!r}"
    )

    rc, out = run("${bin}/klaffat-infra output -json")
    assert rc == 0 and out.strip().endswith("}"), f"output -json was refused: {rc} {out!r}"
    assert "is not an allowed argument" not in out, f"output -json was refused: {out!r}"

    # `state list` has no state to list in this fixture; tofu's own error is
    # what proves the operand and the verb both got through.
    rc, out = run("${bin}/klaffat-infra state list")
    assert "No state file was found" in out, f"state list did not reach tofu: {rc} {out!r}"

    rc, out = run("${bin}/klaffat-infra version -json")
    assert rc == 0 and '"terraform_version"' in out, (
        f"version -json did not reach tofu: {rc} {out!r}"
    )

    # 13b. `-help` waives a verb's MINIMUM operand count — and only the
    #      minimum, never a maximum, a refusal by name or a shape. Nothing
    #      exercised that branch: `apply -destroy -help` (case 8b) is the
    #      only `-help` row and `apply` has no minimum, so `argv_arity=0`
    #      could have been wired to anything. `import` needs two operands
    #      and `state` needs one, so with no operand and no `-help` both
    #      refuse; with `-help` both must get PAST the argv check and reach
    #      tofu's own usage text. (`-help` is not an argv refusal and not
    #      free: it still goes through mirror_sync and the archive, so the
    #      provenance line is expected here — what must be absent is the
    #      "'<verb>' accepts:" line every argv_refuse prints.)
    for verb in ["state", "import"]:
        rc, out = run(f"${bin}/klaffat-infra {verb} -no-color -help")
        assert "accepts:" not in out, (
            f"'{verb} -help' was argv-refused; -help must waive the minimum operand "
            f"count: {rc} {out!r}"
        )
        assert f"Usage: tofu [global options] {verb}" in out, (
            f"'{verb} -help' did not reach tofu's own help: {rc} {out!r}"
        )
    rc, out = run("${bin}/klaffat-infra state -no-color")
    assert rc == 2 and "'state' needs one of" in out, (
        f"without -help, 'state' with no operand must still refuse: {rc} {out!r}"
    )
    rc, out = run("${bin}/klaffat-infra import -no-color")
    assert rc == 2 and "'import' takes exactly two operands" in out, (
        f"without -help, 'import' with no operands must still refuse: {rc} {out!r}"
    )

    assert state_leftovers() == [], f"runs left artefacts in ${stateDir}: {state_leftovers()!r}"
  '';
}
