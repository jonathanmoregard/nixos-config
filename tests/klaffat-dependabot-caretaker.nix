{ pkgs, inputs }:
let
  common = import ./lib/common.nix { inherit pkgs inputs; };
  fixture = name: text: pkgs.writeShellApplication {
    inherit name text;
    runtimeInputs = [ pkgs.coreutils pkgs.findutils pkgs.gawk pkgs.git pkgs.gnugrep pkgs.jq pkgs.util-linux ];
  };
  metadata = fixture "klaffat-caretaker-metadata" ''cat /var/lib/klaffat-caretaker/metadata.json'';
  repair = fixture "klaffat-caretaker-repair" ''
    test -z "''${GITHUB_TOKEN-}"; test -z "''${GH_TOKEN-}"; test -z "''${SSH_AUTH_SOCK-}"
    test -n "''${ANTHROPIC_API_KEY_FILE-}"; test -r "$ANTHROPIC_API_KEY_FILE"
    test -r "$5"
    test ! -e "$4/.git"
    test "$(awk '/^NoNewPrivs:/ { print $2 }' /proc/self/status)" = 1
    test ! -r /etc/klaffat-caretaker/git-token
    test ! -r /etc/klaffat-caretaker/refresh-token
    test ! -r /etc/klaffat-caretaker/metadata-token
    test ! -r /etc/klaffat-caretaker/checks-token
    printf 'repaired-dirty\n' > "$4/crates/klaffat-web/src/dependency_compat.rs"
    if grep -q trigger-protected "$4/tests/e2e/package-lock.json"; then mkdir -p "$4/.github/workflows"; printf bad > "$4/.github/workflows/evil.yml"; fi
    if grep -q trigger-symlink "$4/tests/e2e/package-lock.json"; then ln -s /etc/shadow "$4/leak"; fi
    if grep -q trigger-instructions "$4/tests/e2e/package-lock.json"; then mkdir -p "$4/crates/klaffat-web/src/nested"; printf bad > "$4/crates/klaffat-web/src/nested/CLAUDE.md"; fi
    if grep -q trigger-secret "$4/tests/e2e/package-lock.json"; then printf DO_NOT_PUSH > "$4/crates/klaffat-web/src/dependency_compat.rs"; fi
    if grep -q trigger-delete "$4/tests/e2e/package-lock.json"; then rm "$4/crates/klaffat-web/src/dependency_compat.rs"; fi
  '';
  dependencyPreparation = fixture "klaffat-caretaker-dependency-preparation" ''
    test -z "''${ANTHROPIC_API_KEY-}"; test -z "''${GITHUB_TOKEN-}"; test -z "''${GH_TOKEN-}"; test -z "''${SSH_AUTH_SOCK-}"
    test ! -r /etc/klaffat-caretaker/repair-token
    test ! -r /etc/klaffat-caretaker/git-token
    test ! -r /etc/klaffat-caretaker/refresh-token
    test ! -r /etc/klaffat-caretaker/metadata-token
    test ! -r /etc/klaffat-caretaker/checks-token
    test "$(awk '/^NoNewPrivs:/ { print $2 }' /proc/self/status)" = 1
    test "$(find /sys/class/net -maxdepth 1 -type l | wc -l)" -gt 1
    mkdir -p "$1/tests/e2e/node_modules" "$CARGO_HOME"
    touch "$1/tests/e2e/node_modules/.caretaker-prepared" "$CARGO_HOME/.caretaker-prepared"
  '';
  verifier = fixture "klaffat-caretaker-verifier" ''
    test -z "''${ANTHROPIC_API_KEY-}"; test -z "''${GITHUB_TOKEN-}"; test -z "''${GH_TOKEN-}"; test -z "''${SSH_AUTH_SOCK-}"
    test ! -r /etc/klaffat-caretaker/repair-token
    test ! -r /etc/klaffat-caretaker/git-token
    test ! -r /etc/klaffat-caretaker/refresh-token
    test -e "$1/tests/e2e/node_modules/.caretaker-prepared"
    test -e "$CARGO_HOME/.caretaker-prepared"
    test "''${CARGO_NET_OFFLINE-}" = true
    test "''${npm_config_offline-}" = true
    if ! grep -q already-compatible "$1/tests/e2e/package-lock.json"; then grep -qx repaired-dirty "$1/crates/klaffat-web/src/dependency_compat.rs"; fi
    if grep -q fail-verify "$1/tests/e2e/package-lock.json"; then exit 1; fi
    test "$(find /sys/class/net -maxdepth 1 -type l | wc -l)" = 1
    test ! -S /nix/var/nix/daemon-socket/socket
  '';
  refresh = fixture "klaffat-caretaker-refresh" ''
    test -n "''${KLAFFAT_CARETAKER_REFRESH_CREDENTIAL_FILE-}"
    test -r "$KLAFFAT_CARETAKER_REFRESH_CREDENTIAL_FILE"
    test "$1" -gt 0
    test "$(printf '%s' "$2" | wc -c)" = 40
    test "$(printf '%s' "$3" | wc -c)" = 40
    marker="$1:$2:$3"
    if ! grep -qxF "$marker" /var/lib/klaffat-dependabot-caretaker/state/refreshes 2>/dev/null; then
      printf '%s\n' "$marker" >> /var/lib/klaffat-dependabot-caretaker/state/refreshes
    fi
    if [ -e /var/lib/klaffat-dependabot-caretaker/state/pause-refresh ]; then
      touch /var/lib/klaffat-dependabot-caretaker/state/refresh-observed
      while [ -e /var/lib/klaffat-dependabot-caretaker/state/pause-refresh ]; do sleep 0.1; done
    fi
  '';
  secretScan = fixture "klaffat-caretaker-secret-scan" ''
    test -d "$1/.git"
    git -C "$1" merge-base --is-ancestor "$2" "$3"
    printf '%s:%s\n' "$2" "$3" >> /var/lib/klaffat-dependabot-caretaker/state/secret-scans
    ! git -C "$1" diff "$2" "$3" | grep -q DO_NOT_PUSH
  '';
  checks = fixture "klaffat-caretaker-checks" ''
    if [ -e /var/lib/klaffat-dependabot-caretaker/state/pause-checks ]; then
      touch /var/lib/klaffat-dependabot-caretaker/state/checks-observed
      while [ -e /var/lib/klaffat-dependabot-caretaker/state/pause-checks ]; do sleep 0.1; done
    fi
    test ! -e /var/lib/klaffat-dependabot-caretaker/state/fail-checks
  '';
  notifier = fixture "klaffat-caretaker-notifier" ''
    test ! -e /var/lib/klaffat-dependabot-caretaker/state/fail-notifier
    cat > /var/lib/klaffat-dependabot-caretaker/state/notified.json
  '';
  fixturePush = fixture "klaffat-caretaker-fixture-push" ''
    exec runuser -u klaffat-caretaker-publisher -- \
      git -c safe.directory=/var/lib/klaffat-caretaker/source \
      -C /var/lib/klaffat-caretaker/source push "$@"
  '';
  postReceiveHook = fixture "klaffat-caretaker-post-receive" ''
    repo="$(git rev-parse --absolute-git-dir)"
    if [ -e "$repo/pause-after-push" ]; then
      touch "$repo/push-observed"
      while [ -e "$repo/pause-after-push" ]; do sleep 0.1; done
    fi
  '';
in
common.mkMinimalTest {
  name = "klaffat-dependabot-caretaker";
  extraModules = [
    ../modules/nixos/klaffat-dependabot-caretaker.nix
    ({ config, ... }: {
      assertions = [
        {
          assertion = config.users.users ? klaffat-caretaker-repair
            && config.users.users ? klaffat-caretaker-verifier
            && config.users.users ? klaffat-caretaker-publisher;
          message = "untrusted caretaker stages must use fixed separate service identities";
        }
        {
          assertion = config.services.klaffatDependabotCaretaker.requiredContexts == [
            "refuse test-endpoints in release"
            "rust — fmt + clippy + test"
            "e2e — playwright"
            "race-condition harness (real-contention, file-backed WAL)"
            "infra — fmt + validate + guard tests"
            "supply-chain policy"
          ];
          message = "caretaker must require every authoritative Klaffat check";
        }
      ];
      environment.systemPackages = [
        pkgs.git
        pkgs.jq
        fixturePush
        config.services.klaffatDependabotCaretaker.repairMcpCommand
      ];
      environment.etc."klaffat-caretaker/repair-token" = { text = "test-only-repair"; mode = "0440"; group = "klaffat-caretaker-repair"; };
      environment.etc."klaffat-caretaker/git-token" = { text = "test-only-git"; mode = "0440"; group = "klaffat-caretaker-publisher"; };
      environment.etc."klaffat-caretaker/refresh-token" = { text = "test-only-refresh"; mode = "0400"; };
      environment.etc."klaffat-caretaker/metadata-token" = { text = "test-only-metadata"; mode = "0400"; };
      environment.etc."klaffat-caretaker/checks-token" = { text = "test-only-checks"; mode = "0400"; };
      services.klaffatDependabotCaretaker = {
        enable = true;
        schedule = "2099-01-01 00:00:00";
        repoRemoteUrl = "file:///var/lib/klaffat-caretaker/remote.git";
        metadataCommand = metadata;
        repairCommand = repair;
        dependencyPreparationCommand = dependencyPreparation;
        verifierCommand = verifier;
        refreshCommand = refresh;
        secretScanCommand = secretScan;
        requiredCheckCommand = checks;
        notifierCommand = notifier;
        repairCredentialFile = "/etc/klaffat-caretaker/repair-token";
        gitCredentialFile = "/etc/klaffat-caretaker/git-token";
        refreshCredentialFile = "/etc/klaffat-caretaker/refresh-token";
        metadataCredentialFile = "/etc/klaffat-caretaker/metadata-token";
        checksCredentialFile = "/etc/klaffat-caretaker/checks-token";
      };
    })
  ];
  testScript = ''
    import json, shlex

    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("klaffat-dependabot-caretaker-ready.path", "jonathan")
    dellan.succeed("date -s '2026-09-14 00:00:00' >/dev/null")
    dellan.succeed("runuser -u klaffat-caretaker-repair -- test -r /etc/klaffat-caretaker/repair-token")
    dellan.succeed("runuser -u klaffat-caretaker-repair -- test ! -r /etc/klaffat-caretaker/git-token")
    dellan.succeed("runuser -u klaffat-caretaker-verifier -- test ! -r /etc/klaffat-caretaker/repair-token")
    dellan.succeed("runuser -u klaffat-caretaker-verifier -- test ! -r /etc/klaffat-caretaker/git-token")
    dellan.succeed("runuser -u klaffat-caretaker-publisher -- test -r /etc/klaffat-caretaker/git-token")
    dellan.succeed("runuser -u klaffat-caretaker-publisher -- test ! -r /etc/klaffat-caretaker/repair-token")
    dellan.succeed("runuser -u klaffat-caretaker-publisher -- test ! -r /etc/klaffat-caretaker/refresh-token")
    dellan.succeed("runuser -u klaffat-caretaker-repair -- test ! -r /etc/klaffat-caretaker/metadata-token")
    dellan.succeed("runuser -u klaffat-caretaker-repair -- test ! -r /etc/klaffat-caretaker/refresh-token")
    dellan.succeed("runuser -u klaffat-caretaker-publisher -- test ! -r /etc/klaffat-caretaker/checks-token")
    dellan.succeed("mkdir -p /var/lib/klaffat-caretaker/source && git init -q /var/lib/klaffat-caretaker/source && git -C /var/lib/klaffat-caretaker/source config user.email test@example.invalid && git -C /var/lib/klaffat-caretaker/source config user.name test")
    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && mkdir -p .github/workflows crates/klaffat-web/src deploy/terraform/bootstrap deploy/terraform/nested tests/e2e tests/agent-e2e && echo base > tests/e2e/package-lock.json && echo base > tests/agent-e2e/package-lock.json && echo base > crates/klaffat-web/src/dependency_compat.rs && echo base > app.rs && echo jobs: > .github/workflows/ci.yml && echo base > deploy/terraform/main.tf && echo base > deploy/terraform/bootstrap/main.tf && echo base > deploy/terraform/nested/evil.tf && git add . && git commit -qm base && git branch -M main && git init -q --bare ../remote.git && git config --global --add safe.directory /var/lib/klaffat-caretaker/remote.git && chown -R klaffat-caretaker-publisher:klaffat-caretaker-publisher ../remote.git && git remote add origin ../remote.git && klaffat-caretaker-fixture-push -q origin main && git checkout -qb dependabot/npm_and_yarn/lodash-4.17.22 && echo update >> tests/e2e/package-lock.json && git commit -qam update && klaffat-caretaker-fixture-push -q origin HEAD'")
    dellan.succeed("install -o klaffat-caretaker-publisher -g klaffat-caretaker-publisher -m 0755 ${postReceiveHook}/bin/klaffat-caretaker-post-receive /var/lib/klaffat-caretaker/remote.git/hooks/post-receive")
    mcp_requests = "\n".join(json.dumps(value) for value in [
      {"jsonrpc":"2.0", "id":1, "method":"initialize", "params":{}},
      {"jsonrpc":"2.0", "id":2, "method":"tools/list", "params":{}},
      {"jsonrpc":"2.0", "id":3, "method":"tools/call", "params":{"name":"read_failure", "arguments":{}}},
      {"jsonrpc":"2.0", "id":4, "method":"tools/call", "params":{"name":"read_source", "arguments":{"path":"/proc/self/environ"}}},
      {"jsonrpc":"2.0", "id":5, "method":"tools/call", "params":{"name":"write_source", "arguments":{"path":"crates/klaffat-web/src/nested/CLAUDE.md", "content":"bad"}}},
      {"jsonrpc":"2.0", "id":6, "method":"tools/call", "params":{"name":"write_source", "arguments":{"path":"crates/klaffat-web/src/new.rs", "content":"bad"}}},
      {"jsonrpc":"2.0", "id":7, "method":"tools/call", "params":{"name":"write_source", "arguments":{"path":"crates/klaffat-web/src/dependency_compat.rs", "content":"mcp-write\\n"}}},
    ]) + "\n"
    dellan.succeed("cp -a /var/lib/klaffat-caretaker/source /tmp/mcp-repo && printf failure-safe > /tmp/mcp-failure && chown -R klaffat-caretaker-repair:klaffat-caretaker-repair /tmp/mcp-repo /tmp/mcp-failure")
    dellan.succeed("printf %s | runuser -u klaffat-caretaker-repair -- env ANTHROPIC_API_KEY=do-not-leak klaffat-caretaker-repair-mcp --repo /tmp/mcp-repo --failure-log /tmp/mcp-failure > /tmp/mcp-results" % shlex.quote(mcp_requests))
    dellan.succeed("jq -se 'length == 7 and .[0].result.serverInfo.name == \"klaffat-repair\" and (.[1].result.tools | length) == 4 and .[2].result.content[0].text == \"failure-safe\" and .[3].result.isError == true and .[4].result.isError == true and .[5].result.isError == true and .[6].result.isError == false' /tmp/mcp-results")
    dellan.succeed("grep -qx mcp-write /tmp/mcp-repo/crates/klaffat-web/src/dependency_compat.rs")
    dellan.fail("grep -F do-not-leak /tmp/mcp-results")
    base_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse main").strip()
    head_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    valid = {"state":"open", "author":"dependabot[bot]", "base":"main", "head_repo":"jonathanmoregard/klaffat", "pr":42, "head_ref":"dependabot/npm_and_yarn/lodash-4.17.22", "head_sha":head_sha, "base_sha":base_sha}
    def write_metadata(value):
      values = value if isinstance(value, list) else [value]
      dellan.succeed("printf %s > /var/lib/klaffat-caretaker/metadata.json" % shlex.quote(json.dumps(values)))
    def next_caretaker_day():
      dellan.succeed("date -s '+1 day' >/dev/null")

    dellan.succeed("touch /var/lib/klaffat-dependabot-caretaker/state/fail-checks")
    write_metadata(valid)
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    published_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/lodash-4.17.22").strip()
    dellan.succeed("git -C /var/lib/klaffat-caretaker/remote.git show %s:crates/klaffat-web/src/dependency_compat.rs | grep -qx repaired-dirty" % shlex.quote(published_sha))
    dellan.succeed("rm /var/lib/klaffat-dependabot-caretaker/state/fail-checks")
    write_metadata(valid | {"head_sha":published_sha})
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test ! -f /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    dellan.succeed("test \"$(jq -s '[map(.attempts)[]] | add' /var/lib/klaffat-dependabot-caretaker/state/attempts/*.json)\" = 1")
    dellan.succeed("jq -s -e 'any(.[]; .stage == \"daily-limit\")' /var/lib/klaffat-dependabot-caretaker/state/audit/events.jsonl")
    next_caretaker_day()
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test -f /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    dellan.succeed("jq -e '.state == \"ready\" and .pr == 42 and .url == \"https://github.com/jonathanmoregard/klaffat/pull/42\"' /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    dellan.succeed("test \"$(stat -c '%U:%G:%a' /var/lib/klaffat-dependabot-caretaker/notification/ready.json)\" = root:root:644")
    dellan.succeed("cmp /var/lib/klaffat-dependabot-caretaker/state/ready.json /var/lib/klaffat-dependabot-caretaker/notification/ready.json")
    dellan.succeed("test -f /var/lib/klaffat-dependabot-caretaker/notification/ready")
    user_systemctl = "runuser -u jonathan -- env XDG_RUNTIME_DIR=/run/user/1000 systemctl --user"
    dellan.succeed(f"test \"$({user_systemctl} show -P Restart klaffat-dependabot-caretaker-ready.service)\" = on-failure")
    dellan.succeed(f"test \"$({user_systemctl} show -P RestartUSec klaffat-dependabot-caretaker-ready.service)\" = 1min")
    dellan.succeed(f"test \"$({user_systemctl} show -P StartLimitIntervalUSec klaffat-dependabot-caretaker-ready.service)\" = 0")
    dellan.wait_until_succeeds(f"test \"$({user_systemctl} show -P SubState klaffat-dependabot-caretaker-ready.service)\" = auto-restart")
    ready_sha = dellan.succeed("jq -r .sha /var/lib/klaffat-dependabot-caretaker/state/ready.json").strip()
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/lodash-4.17.22)\" = %s" % shlex.quote(ready_sha))
    dellan.succeed("git -C /var/lib/klaffat-caretaker/remote.git show %s:crates/klaffat-web/src/dependency_compat.rs | grep -qx repaired-dirty" % shlex.quote(ready_sha))
    dellan.succeed("! grep -Ei 'merge|approve' /var/lib/klaffat-dependabot-caretaker/state/notified.json")
    write_metadata(valid | {"head_sha":ready_sha})
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed('test "$(jq -s \'[.[] | select(.stage == "ready")] | length\' /var/lib/klaffat-dependabot-caretaker/state/audit/events.jsonl)" = 1')
    dellan.succeed("jq -e --arg sha %s '.sha == $sha' /var/lib/klaffat-dependabot-caretaker/state/ready.json" % shlex.quote(ready_sha))
    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/held-1.0.0 main && echo already-compatible >> tests/e2e/package-lock.json && git commit -qam held && klaffat-caretaker-fixture-push -q origin HEAD'")
    held_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    held_pr = valid | {"pr":142, "head_ref":"dependabot/npm_and_yarn/held-1.0.0", "head_sha":held_sha}
    write_metadata([valid | {"head_sha":ready_sha}, held_pr])
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("jq -e '.pr == 42' /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    dellan.succeed("jq -s -e 'any(.[]; .stage == \"awaiting-human\")' /var/lib/klaffat-dependabot-caretaker/state/audit/events.jsonl")

    for patch in [{"head_repo":"mallory/klaffat"}, {"head_ref":"main"}, {"head_sha":"A" * 40}]:
      write_metadata(valid | patch)
      dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed('test "$(jq -s \'[.[] | select(.stage == "ready")] | length\' /var/lib/klaffat-dependabot-caretaker/state/audit/events.jsonl)" = 1')
    write_metadata(valid)
    next_caretaker_day()
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    write_metadata(valid | {"author":"mallory"})
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")

    dellan.succeed("systemd-run --unit=caretaker-lock-holder.service flock /var/lib/klaffat-dependabot-caretaker/state/controller.lock -c '${pkgs.coreutils}/bin/touch /run/caretaker-lock-held; ${pkgs.coreutils}/bin/sleep 30'")
    dellan.wait_until_succeeds("test -f /run/caretaker-lock-held")
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("systemctl stop caretaker-lock-holder.service")
    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/broken-1.0.0 main && echo fail-verify >> tests/e2e/package-lock.json && git commit -qam broken && klaffat-caretaker-fixture-push -q origin HEAD'")
    next_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    failed_pr = valid | {"pr":43, "head_ref":"dependabot/npm_and_yarn/broken-1.0.0", "head_sha":next_sha}
    write_metadata(failed_pr)
    for _ in range(3):
      next_caretaker_day()
      dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/broken-1.0.0)\" = %s" % shlex.quote(next_sha))
    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/axios-1.8.0 main && echo axios >> tests/e2e/package-lock.json && git commit -qam axios && klaffat-caretaker-fixture-push -q origin HEAD'")
    final_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    next_pr = valid | {"pr":44, "head_ref":"dependabot/npm_and_yarn/axios-1.8.0", "head_sha":final_sha}
    write_metadata([failed_pr, next_pr])
    next_caretaker_day()
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("jq -e '.pr == 44' /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    dellan.succeed("jq -s -e '[.[] | select(.stage == \"failure\")] | length >= 3' /var/lib/klaffat-dependabot-caretaker/state/audit/events.jsonl")
    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/protected-1.0.0 main && echo trigger-protected >> tests/e2e/package-lock.json && git commit -qam protected && klaffat-caretaker-fixture-push -q origin HEAD'")
    protected_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    protected_pr = valid | {"pr":45, "head_ref":"dependabot/npm_and_yarn/protected-1.0.0", "head_sha":protected_sha}
    write_metadata(protected_pr)
    next_caretaker_day()
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/protected-1.0.0)\" = %s" % shlex.quote(protected_sha))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/symlink-1.0.0 main && echo trigger-symlink >> tests/e2e/package-lock.json && git commit -qam symlink && klaffat-caretaker-fixture-push -q origin HEAD'")
    symlink_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    write_metadata(valid | {"pr":46, "head_ref":"dependabot/npm_and_yarn/symlink-1.0.0", "head_sha":symlink_sha})
    next_caretaker_day()
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/symlink-1.0.0)\" = %s" % shlex.quote(symlink_sha))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/instructions-1.0.0 main && echo trigger-instructions >> tests/e2e/package-lock.json && git commit -qam instructions && klaffat-caretaker-fixture-push -q origin HEAD'")
    instructions_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    write_metadata(valid | {"pr":52, "head_ref":"dependabot/npm_and_yarn/instructions-1.0.0", "head_sha":instructions_sha})
    next_caretaker_day()
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/instructions-1.0.0)\" = %s" % shlex.quote(instructions_sha))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/delete-1.0.0 main && echo trigger-delete >> tests/e2e/package-lock.json && git commit -qam delete && klaffat-caretaker-fixture-push -q origin HEAD'")
    delete_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    write_metadata(valid | {"pr":55, "head_ref":"dependabot/npm_and_yarn/delete-1.0.0", "head_sha":delete_sha})
    next_caretaker_day()
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/delete-1.0.0)\" = %s" % shlex.quote(delete_sha))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/secret-1.0.0 main && echo trigger-secret >> tests/e2e/package-lock.json && git commit -qam secret && klaffat-caretaker-fixture-push -q origin HEAD'")
    secret_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    write_metadata(valid | {"pr":54, "head_ref":"dependabot/npm_and_yarn/secret-1.0.0", "head_sha":secret_sha})
    next_caretaker_day()
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/secret-1.0.0)\" = %s" % shlex.quote(secret_sha))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/nonmechanical-1.0.0 main && echo bad > app.rs && git add app.rs && git commit -qm nonmechanical && klaffat-caretaker-fixture-push -q origin HEAD'")
    nonmechanical_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    write_metadata(valid | {"pr":47, "head_ref":"dependabot/npm_and_yarn/nonmechanical-1.0.0", "head_sha":nonmechanical_sha})
    next_caretaker_day()
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/nonmechanical-1.0.0)\" = %s" % shlex.quote(nonmechanical_sha))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/terraform/deep-path-1.0.0 main && echo changed >> deploy/terraform/nested/evil.tf && git commit -qam deep-path && klaffat-caretaker-fixture-push -q origin HEAD'")
    deep_path_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    write_metadata(valid | {"pr":49, "head_ref":"dependabot/terraform/deep-path-1.0.0", "head_sha":deep_path_sha})
    next_caretaker_day()
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/terraform/deep-path-1.0.0)\" = %s" % shlex.quote(deep_path_sha))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/github_actions/unsafe-1.0.0 main && echo name: unsafe >> .github/workflows/ci.yml && git commit -qam unsafe-actions && klaffat-caretaker-fixture-push -q origin HEAD'")
    unsafe_actions_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    write_metadata(valid | {"pr":50, "head_ref":"dependabot/github_actions/unsafe-1.0.0", "head_sha":unsafe_actions_sha})
    next_caretaker_day()
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/github_actions/unsafe-1.0.0)\" = %s" % shlex.quote(unsafe_actions_sha))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/mode-change-1.0.0 main && chmod +x tests/e2e/package-lock.json && git add tests/e2e/package-lock.json && git commit -qm mode-change && klaffat-caretaker-fixture-push -q origin HEAD'")
    mode_change_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    write_metadata(valid | {"pr":51, "head_ref":"dependabot/npm_and_yarn/mode-change-1.0.0", "head_sha":mode_change_sha})
    next_caretaker_day()
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/mode-change-1.0.0)\" = %s" % shlex.quote(mode_change_sha))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/compatible-1.0.0 main && echo already-compatible >> tests/e2e/package-lock.json && git commit -qam compatible && klaffat-caretaker-fixture-push -q origin HEAD'")
    compatible_sha = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    write_metadata(valid | {"pr":48, "head_ref":"dependabot/npm_and_yarn/compatible-1.0.0", "head_sha":compatible_sha})
    next_caretaker_day()
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("git -C /var/lib/klaffat-caretaker/remote.git show refs/heads/dependabot/npm_and_yarn/compatible-1.0.0:tests/e2e/package-lock.json | grep -qx already-compatible")
    dellan.succeed("git -C /var/lib/klaffat-caretaker/remote.git show refs/heads/dependabot/npm_and_yarn/compatible-1.0.0:crates/klaffat-web/src/dependency_compat.rs | grep -qx base")
    compatible_ready = dellan.succeed("jq -r .sha /var/lib/klaffat-dependabot-caretaker/state/ready.json").strip()
    dellan.succeed("grep -qx %s /var/lib/klaffat-dependabot-caretaker/state/secret-scans" % shlex.quote(f"{base_sha}:{compatible_ready}"))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/conflict-1.0.0 main && echo bot > tests/e2e/package-lock.json && git commit -qam bot-conflict && klaffat-caretaker-fixture-push -q origin HEAD && git checkout -q main && echo main > tests/e2e/package-lock.json && git commit -qam main-conflict && klaffat-caretaker-fixture-push -q origin main'")
    conflict_head = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse dependabot/npm_and_yarn/conflict-1.0.0").strip()
    conflict_base = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse main").strip()
    write_metadata(valid | {"pr":53, "head_ref":"dependabot/npm_and_yarn/conflict-1.0.0", "head_sha":conflict_head, "base_sha":conflict_base})
    next_caretaker_day()
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(wc -l < /var/lib/klaffat-dependabot-caretaker/state/refreshes)\" = 1")
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(wc -l < /var/lib/klaffat-dependabot-caretaker/state/refreshes)\" = 1")
    dellan.succeed("jq -s -e 'any(.[]; .stage == \"waiting-for-refresh\")' /var/lib/klaffat-dependabot-caretaker/state/audit/events.jsonl")

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/stale-ready-1.0.0 main && echo already-compatible >> tests/e2e/package-lock.json && git commit -qam stale-ready && klaffat-caretaker-fixture-push -q origin HEAD'")
    stale_head = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    stale_pr = valid | {"pr":56, "head_ref":"dependabot/npm_and_yarn/stale-ready-1.0.0", "head_sha":stale_head, "base_sha":conflict_base}
    write_metadata(stale_pr)
    next_caretaker_day()
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    stale_ready = dellan.succeed("jq -r .sha /var/lib/klaffat-dependabot-caretaker/state/ready.json").strip()
    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -q main && echo base-advanced >> app.rs && git commit -qam base-advanced && klaffat-caretaker-fixture-push -q origin main'")
    advanced_base = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse main").strip()
    write_metadata(stale_pr | {"head_sha":stale_ready, "base_sha":advanced_base})
    next_caretaker_day()
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("jq -e --arg old %s --arg base %s '.base_sha == $base and .sha != $old' /var/lib/klaffat-dependabot-caretaker/state/ready.json" % (shlex.quote(stale_ready), shlex.quote(advanced_base)))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/crash-recovery-1.0.0 main && echo crash-recovery >> tests/e2e/package-lock.json && git commit -qam crash-recovery && klaffat-caretaker-fixture-push -q origin HEAD'")
    crash_head = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    crash_pr = valid | {"pr":57, "head_ref":"dependabot/npm_and_yarn/crash-recovery-1.0.0", "head_sha":crash_head, "base_sha":advanced_base}
    write_metadata(crash_pr)
    next_caretaker_day()
    dellan.succeed("touch /var/lib/klaffat-caretaker/remote.git/pause-after-push && chown klaffat-caretaker-publisher:klaffat-caretaker-publisher /var/lib/klaffat-caretaker/remote.git/pause-after-push")
    dellan.succeed("systemctl start --no-block klaffat-dependabot-caretaker.service")
    dellan.wait_until_succeeds("test -e /var/lib/klaffat-caretaker/remote.git/push-observed")
    crash_published = dellan.succeed("git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/crash-recovery-1.0.0").strip()
    dellan.succeed("test -f /var/lib/klaffat-dependabot-caretaker/state/approved-heads/%s" % shlex.quote(crash_published))
    dellan.succeed("systemctl kill --signal=KILL klaffat-dependabot-caretaker.service")
    dellan.succeed("rm -f /var/lib/klaffat-caretaker/remote.git/pause-after-push")
    dellan.wait_until_succeeds("! systemctl is-active --quiet klaffat-dependabot-caretaker.service")
    dellan.succeed("systemctl reset-failed klaffat-dependabot-caretaker.service")
    write_metadata(crash_pr | {"head_sha":crash_published})
    next_caretaker_day()
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("jq -e --arg sha %s '.pr == 57 and .sha == $sha' /var/lib/klaffat-dependabot-caretaker/state/ready.json" % shlex.quote(crash_published))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/notifier-recovery-1.0.0 main && echo already-compatible >> tests/e2e/package-lock.json && git commit -qam notifier-recovery && klaffat-caretaker-fixture-push -q origin HEAD'")
    notifier_head = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    notifier_pr = valid | {"pr":58, "head_ref":"dependabot/npm_and_yarn/notifier-recovery-1.0.0", "head_sha":notifier_head, "base_sha":advanced_base}
    write_metadata(notifier_pr)
    next_caretaker_day()
    dellan.succeed("touch /var/lib/klaffat-dependabot-caretaker/state/fail-notifier")
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test ! -e /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    dellan.succeed("rm /var/lib/klaffat-dependabot-caretaker/state/fail-notifier")
    next_caretaker_day()
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("jq -e '.pr == 58' /var/lib/klaffat-dependabot-caretaker/state/ready.json")
    dellan.succeed("cmp /var/lib/klaffat-dependabot-caretaker/state/ready.json /var/lib/klaffat-dependabot-caretaker/notification/ready.json")
    dellan.succeed("cmp /var/lib/klaffat-dependabot-caretaker/state/ready.json /var/lib/klaffat-dependabot-caretaker/state/notified.json")

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/agent-harness-1.0.0 main && echo unverified-update >> tests/agent-e2e/package-lock.json && git commit -qam agent-harness && klaffat-caretaker-fixture-push -q origin HEAD'")
    agent_harness_head = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    write_metadata(valid | {"pr":59, "head_ref":"dependabot/npm_and_yarn/agent-harness-1.0.0", "head_sha":agent_harness_head, "base_sha":advanced_base})
    next_caretaker_day()
    dellan.fail("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(git -C /var/lib/klaffat-caretaker/remote.git rev-parse refs/heads/dependabot/npm_and_yarn/agent-harness-1.0.0)\" = %s" % shlex.quote(agent_harness_head))

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/base-race-1.0.0 main && echo already-compatible >> tests/e2e/package-lock.json && git commit -qam base-race && klaffat-caretaker-fixture-push -q origin HEAD'")
    base_race_head = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse HEAD").strip()
    write_metadata(valid | {"pr":60, "head_ref":"dependabot/npm_and_yarn/base-race-1.0.0", "head_sha":base_race_head, "base_sha":advanced_base})
    next_caretaker_day()
    dellan.succeed("touch /var/lib/klaffat-dependabot-caretaker/state/pause-checks")
    dellan.succeed("systemctl start --no-block klaffat-dependabot-caretaker.service")
    dellan.wait_until_succeeds("test -e /var/lib/klaffat-dependabot-caretaker/state/checks-observed")
    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -q main && echo checks-base-advanced >> app.rs && git commit -qam checks-base-advanced && klaffat-caretaker-fixture-push -q origin main'")
    dellan.succeed("rm /var/lib/klaffat-dependabot-caretaker/state/pause-checks")
    dellan.succeed("for _ in $(seq 1 100); do systemctl is-failed --quiet klaffat-dependabot-caretaker.service && exit 0; sleep 0.1; done; exit 1")
    dellan.succeed("test ! -e /var/lib/klaffat-dependabot-caretaker/state/ready.json")

    dellan.succeed("sh -c 'cd /var/lib/klaffat-caretaker/source && git checkout -qb dependabot/npm_and_yarn/refresh-crash-1.0.0 main && echo bot-refresh-crash > tests/e2e/package-lock.json && git commit -qam bot-refresh-crash && klaffat-caretaker-fixture-push -q origin HEAD && git checkout -q main && echo main-refresh-crash > tests/e2e/package-lock.json && git commit -qam main-refresh-crash && klaffat-caretaker-fixture-push -q origin main'")
    refresh_crash_head = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse dependabot/npm_and_yarn/refresh-crash-1.0.0").strip()
    refresh_crash_base = dellan.succeed("git -C /var/lib/klaffat-caretaker/source rev-parse main").strip()
    refresh_crash_pr = valid | {"pr":61, "head_ref":"dependabot/npm_and_yarn/refresh-crash-1.0.0", "head_sha":refresh_crash_head, "base_sha":refresh_crash_base}
    write_metadata(refresh_crash_pr)
    next_caretaker_day()
    dellan.succeed("touch /var/lib/klaffat-dependabot-caretaker/state/pause-refresh")
    dellan.succeed("systemctl reset-failed klaffat-dependabot-caretaker.service")
    dellan.succeed("systemctl start --no-block klaffat-dependabot-caretaker.service")
    dellan.wait_until_succeeds("test -e /var/lib/klaffat-dependabot-caretaker/state/refresh-observed")
    dellan.succeed("systemctl kill --signal=KILL klaffat-dependabot-caretaker.service")
    dellan.succeed("rm /var/lib/klaffat-dependabot-caretaker/state/pause-refresh")
    dellan.wait_until_succeeds("! systemctl is-active --quiet klaffat-dependabot-caretaker.service")
    dellan.succeed("systemctl reset-failed klaffat-dependabot-caretaker.service")
    next_caretaker_day()
    dellan.succeed("systemctl start klaffat-dependabot-caretaker.service")
    dellan.succeed("test \"$(grep -c '^61:' /var/lib/klaffat-dependabot-caretaker/state/refreshes)\" = 1")
    dellan.succeed("jq -s -e 'any(.[]; .stage == \"waiting-for-refresh\")' /var/lib/klaffat-dependabot-caretaker/state/audit/events.jsonl")
  '';
}
