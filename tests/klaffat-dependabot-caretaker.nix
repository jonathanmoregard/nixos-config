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
    mkdir -p "$4"; printf repaired > "$4/repaired"
  '';
  verifier = fixture "klaffat-caretaker-verifier" ''
    test -z "''${ANTHROPIC_API_KEY-}"; test -z "''${GITHUB_TOKEN-}"; test -z "''${GH_TOKEN-}"; test -z "''${SSH_AUTH_SOCK-}"
    test ! -e /var/lib/klaffat-dependabot-caretaker/state/fail-verify
  '';
  publisher = fixture "klaffat-caretaker-publisher" ''
    test ! -e /var/lib/klaffat-dependabot-caretaker/state/stale-head
    jq -er '(.ref | test("^dependabot/")) and (.expected_head | test("^[0-9a-f]{40}$"))' "$2" >/dev/null
    jq -r .candidate "$2" >> /var/lib/klaffat-dependabot-caretaker/state/published
  '';
  checks = fixture "klaffat-caretaker-checks" ''test ! -e /var/lib/klaffat-dependabot-caretaker/state/fail-checks'';
  notifier = fixture "klaffat-caretaker-notifier" ''cat > /var/lib/klaffat-dependabot-caretaker/state/notified.json'';
in
common.mkMinimalTest {
  name = "klaffat-dependabot-caretaker";
  extraModules = [
    ../modules/nixos/klaffat-dependabot-caretaker.nix
    ({ ... }: {
      environment.systemPackages = [ pkgs.git pkgs.jq ];
      environment.etc."klaffat-caretaker/repair-token".text = "test-only-repair";
      environment.etc."klaffat-caretaker/git-token".text = "test-only-git";
      environment.etc."klaffat-caretaker/metadata-token".text = "test-only-metadata";
      environment.etc."klaffat-caretaker/checks-token".text = "test-only-checks";
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
      caretaker.succeed("printf %s > /var/lib/klaffat-caretaker/metadata.json" % shlex.quote(json.dumps(value)))

    write_metadata(valid)
    caretaker.succeed("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("test -f /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    caretaker.succeed("jq -e '.state == \"ready\" and .pr == 42 and .url == \"https://github.com/jonathanmoregard/klaffat/pull/42\"' /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    caretaker.succeed("test \"$(wc -l < /var/lib/klaffat-dependabot-caretaker/state/published)\" = 1")
    caretaker.succeed("! rg -i 'merge|approve' /var/lib/klaffat-dependabot-caretaker/state/notified.json")

    for patch in [{"author":"mallory"}, {"head_repo":"mallory/klaffat"}, {"head_ref":"main"}, {"head_sha":"A" * 40}]:
      write_metadata(valid | patch)
      caretaker.fail("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("test \"$(wc -l < /var/lib/klaffat-dependabot-caretaker/state/published)\" = 1")

    write_metadata(valid)
    caretaker.succeed("touch /var/lib/klaffat-dependabot-caretaker/state/fail-verify")
    caretaker.fail("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("rm /var/lib/klaffat-dependabot-caretaker/state/fail-verify")
    caretaker.succeed("touch /var/lib/klaffat-dependabot-caretaker/state/stale-head")
    caretaker.fail("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("rm /var/lib/klaffat-dependabot-caretaker/state/stale-head")
    caretaker.succeed("test \"$(wc -l < /var/lib/klaffat-dependabot-caretaker/state/published)\" = 1")

    caretaker.succeed("flock /var/lib/klaffat-dependabot-caretaker/state/controller.lock sleep 5 &")
    caretaker.fail("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("sleep 6")
    caretaker.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/axios-1.8.0 main && echo axios >> package-lock.json && git commit -qam axios && git push -q -u origin HEAD'")
    next_sha = caretaker.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    failed_pr = valid | {"pr":43, "head_ref":"dependabot/npm_and_yarn/axios-1.8.0", "head_sha":next_sha}
    write_metadata(failed_pr)
    for _ in range(3):
      caretaker.succeed("touch /var/lib/klaffat-dependabot-caretaker/state/fail-verify")
      caretaker.fail("systemctl start klaffat-dependabot-caretaker.service")
      caretaker.succeed("rm /var/lib/klaffat-dependabot-caretaker/state/fail-verify")
    caretaker.fail("systemctl start klaffat-dependabot-caretaker.service")
    next_pr = failed_pr | {"pr":44}
    write_metadata(next_pr)
    caretaker.succeed("systemctl start klaffat-dependabot-caretaker.service")
    caretaker.succeed("jq -e '.pr == 44' /var/lib/klaffat-dependabot-caretaker/state/ready.json")
  '';
}
