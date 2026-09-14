{ pkgs, inputs }:
let
  common = import ./lib/common.nix { inherit pkgs inputs; };
  fixture = name: text: pkgs.writeShellApplication {
    inherit name text;
    runtimeInputs = [ pkgs.coreutils pkgs.jq ];
  };
  metadata = fixture "klaffat-caretaker-metadata" ''cat /var/lib/klaffat-caretaker/metadata.json'';
  repair = fixture "klaffat-caretaker-repair" ''
    test -z "''${GITHUB_TOKEN-}"; test -z "''${GH_TOKEN-}"; test -z "''${SSH_AUTH_SOCK-}"
    printf repaired > "$4/repaired"
    printf '\nrepaired-dirty\n' >> "$4/package-lock.json"
    if test -e "$4/TRIGGER_PROTECTED"; then mkdir -p "$4/.github/workflows"; printf bad > "$4/.github/workflows/evil.yml"; fi
  '';
  verifier = fixture "klaffat-caretaker-verifier" ''
    test -z "''${ANTHROPIC_API_KEY-}"; test -z "''${GITHUB_TOKEN-}"; test -z "''${GH_TOKEN-}"; test -z "''${SSH_AUTH_SOCK-}"
    test ! -e "$1/FAIL_VERIFY"
    test "$(find /sys/class/net -maxdepth 1 -type l | wc -l)" = 1
  '';
  publisher = fixture "klaffat-caretaker-publisher" ''
    test ! -e /var/lib/klaffat-dependabot-caretaker/state/stale-head
    jq -er '(.ref | test("^dependabot/")) and (.expected_head | test("^[0-9a-f]{40}$"))' "$2" >/dev/null
    jq -r .candidate "$2" > "$1/published"
  '';
  checks = fixture "klaffat-caretaker-checks" ''test ! -e /var/lib/klaffat-dependabot-caretaker/state/fail-checks'';
  notifier = fixture "klaffat-caretaker-notifier" ''cat > /var/lib/klaffat-dependabot-caretaker/state/notified.json'';
in
common.mkMinimalTest {
  name = "klaffat-dependabot-caretaker";
  extraModules = [
    ../modules/nixos/klaffat-dependabot-caretaker.nix
    ({ config, ... }: {
      assertions = [
        {
          assertion = config.users.users ? klaffat-caretaker-controller
            && config.users.users ? klaffat-caretaker-repair
            && config.users.users ? klaffat-caretaker-verifier
            && config.users.users ? klaffat-caretaker-publisher;
          message = "caretaker stages must use fixed separate service identities";
        }
      ];
      environment.systemPackages = [ pkgs.git pkgs.jq ];
      environment.etc."klaffat-caretaker/repair-token" = { text = "test-only-repair"; mode = "0440"; group = "klaffat-caretaker-repair"; };
      environment.etc."klaffat-caretaker/git-token" = { text = "test-only-git"; mode = "0440"; group = "klaffat-caretaker-publisher"; };
      environment.etc."klaffat-caretaker/metadata-token" = { text = "test-only-metadata"; mode = "0400"; };
      environment.etc."klaffat-caretaker/checks-token" = { text = "test-only-checks"; mode = "0400"; };
      services.klaffatDependabotCaretaker = {
        enable = true;
        repoRemoteUrl = "file:///var/lib/klaffat-caretaker/remote.git";
        metadataCommand = metadata;
        repairCommand = repair;
        verifierCommand = verifier;
        publisherCommand = publisher;
        requiredCheckCommand = checks;
        notifierCommand = notifier;
        repairCredentialFile = "/etc/klaffat-caretaker/repair-token";
        gitCredentialFile = "/etc/klaffat-caretaker/git-token";
        metadataCredentialFile = "/etc/klaffat-caretaker/metadata-token";
        checksCredentialFile = "/etc/klaffat-caretaker/checks-token";
      };
    })
  ];
  testScript = ''
    import json, shlex

    caretaker.wait_for_unit("multi-user.target")
    caretaker.succeed("runuser -u klaffat-caretaker-repair -- test -r /etc/klaffat-caretaker/repair-token")
    caretaker.succeed("runuser -u klaffat-caretaker-repair -- test ! -r /etc/klaffat-caretaker/git-token")
    caretaker.succeed("runuser -u klaffat-caretaker-verifier -- test ! -r /etc/klaffat-caretaker/repair-token")
    caretaker.succeed("runuser -u klaffat-caretaker-verifier -- test ! -r /etc/klaffat-caretaker/git-token")
    caretaker.succeed("runuser -u klaffat-caretaker-publisher -- test -r /etc/klaffat-caretaker/git-token")
    caretaker.succeed("runuser -u klaffat-caretaker-publisher -- test ! -r /etc/klaffat-caretaker/repair-token")
    caretaker.succeed("runuser -u klaffat-caretaker-repair -- test ! -r /etc/klaffat-caretaker/metadata-token")
    caretaker.succeed("runuser -u klaffat-caretaker-publisher -- test ! -r /etc/klaffat-caretaker/checks-token")
    contexts = caretaker.succeed("nixos-option services.klaffatDependabotCaretaker.requiredContexts")
    for context in [
      "refuse test-endpoints in release",
      "rust — fmt + clippy + test",
      "e2e — playwright",
      "race-condition harness (real-contention, file-backed WAL)",
      "infra — fmt + validate + guard tests",
    ]:
      assert context in contexts
    caretaker.succeed("mkdir -p /var/lib/klaffat-caretaker/source && git init -q /var/lib/klaffat-caretaker/source && git -C /var/lib/klaffat-caretaker/source config user.email test@example.invalid && git -C /var/lib/klaffat-caretaker/source config user.name test")
    caretaker.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && echo base > package-lock.json && git add package-lock.json && git commit -qm base && git branch -M main && git clone -q --bare . ../remote.git && git remote add origin ../remote.git && git push -q -u origin main && git checkout -qb dependabot/npm_and_yarn/lodash-4.17.22 && echo update >> package-lock.json && git commit -qam update && git push -q -u origin HEAD'")
    base_sha = caretaker.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse main").strip()
    head_sha = caretaker.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    valid = {"state":"OPEN", "author":"dependabot[bot]", "base":"main", "head_repo":"jonathanmoregard/klaffat", "pr":42, "head_ref":"dependabot/npm_and_yarn/lodash-4.17.22", "head_sha":head_sha, "base_sha":base_sha}
    def write_metadata(value):
      values = value if isinstance(value, list) else [value]
      caretaker.succeed("printf %s > /var/lib/klaffat-caretaker/metadata.json" % shlex.quote(json.dumps(values)))

    write_metadata(valid)
    caretaker.succeed("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("test -f /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    caretaker.succeed("jq -e '.state == \"ready\" and .pr == 42 and .url == \"https://github.com/jonathanmoregard/klaffat/pull/42\"' /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    ready_sha = caretaker.succeed("jq -r .sha /var/lib/klaffat-dependabot-caretaker/state/ready.json").strip()
    caretaker.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/lodash-4.17.22)\" = %s" % shlex.quote(ready_sha))
    caretaker.succeed("git -C /var/lib/klaffat-caretaker/remote.git show %s:repaired | grep -qx repaired" % shlex.quote(ready_sha))
    caretaker.succeed("git -C /var/lib/klaffat-caretaker/remote.git show %s:package-lock.json | grep -qx repaired-dirty" % shlex.quote(ready_sha))
    caretaker.succeed("! rg -i 'merge|approve' /var/lib/klaffat-dependabot-caretaker/state/notified.json")

    for patch in [{"author":"mallory"}, {"head_repo":"mallory/klaffat"}, {"head_ref":"main"}, {"head_sha":"A" * 40}]:
      write_metadata(valid | patch)
      caretaker.fail("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed('test "$(jq -s \'[.[] | select(.stage == "ready")] | length\' /var/lib/klaffat-dependabot-caretaker/state/audit/events.jsonl)" = 1')
    write_metadata(valid)
    caretaker.fail("systemctl start klaffat-dependabot-caretaker.service")

    caretaker.succeed("flock /var/lib/klaffat-dependabot-caretaker/state/controller.lock sleep 5 &")
    caretaker.fail("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("sleep 6")
    caretaker.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/broken-1.0.0 main && echo broken >> package-lock.json && touch FAIL_VERIFY && git add FAIL_VERIFY && git commit -qam broken && git push -q -u origin HEAD'")
    next_sha = caretaker.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    failed_pr = valid | {"pr":43, "head_ref":"dependabot/npm_and_yarn/broken-1.0.0", "head_sha":next_sha}
    write_metadata(failed_pr)
    for _ in range(3):
      caretaker.fail("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/broken-1.0.0)\" = %s" % shlex.quote(next_sha))
    caretaker.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/axios-1.8.0 main && echo axios >> package-lock.json && git commit -qam axios && git push -q -u origin HEAD'")
    final_sha = caretaker.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    next_pr = valid | {"pr":44, "head_ref":"dependabot/npm_and_yarn/axios-1.8.0", "head_sha":final_sha}
    write_metadata([failed_pr, next_pr])
    caretaker.succeed("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("jq -e '.pr == 44' /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    caretaker.succeed("jq -e '[.[] | select(.stage == \"failure\")] | length >= 3' /var/lib/klaffat-dependabot-caretaker/state/audit/events.jsonl")
    caretaker.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/protected-1.0.0 main && echo protected >> package-lock.json && touch TRIGGER_PROTECTED && git add TRIGGER_PROTECTED && git commit -qam protected && git push -q -u origin HEAD'")
    protected_sha = caretaker.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    protected_pr = valid | {"pr":45, "head_ref":"dependabot/npm_and_yarn/protected-1.0.0", "head_sha":protected_sha}
    write_metadata(protected_pr)
    caretaker.fail("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/protected-1.0.0)\" = %s" % shlex.quote(protected_sha))
  '';
}
