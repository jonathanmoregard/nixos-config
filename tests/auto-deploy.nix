# vm-auto-deploy: the CD path cannot wedge forever, a failed fetch is
# handled cleanly, success/failure bookkeeping lands in `last-good`, and
# the fetch/apply privilege split (issue #389) actually holds.
#
# Guards the 2026-06-14 incident: nixos-deploy's `git fetch` stalled on
# a half-open ssh connection (no ConnectTimeout / keepalive / overall
# timeout), the oneshot had no TimeoutStartSec, so the unit sat in
# "activating (start)" for 17h holding the flock. Every later timer
# tick hit `flock -n` and silently no-op'd — so a merged PR (the camera
# fix, #125) never reached the host and looked like the fix "didn't
# work".
#
# Coverage, honest about its limits:
#   - STATIC (presence): the unit carries TimeoutStartSec; the rendered
#     fetch script carries ssh ConnectTimeout + ServerAlive*, and wraps
#     the fetch in `timeout <positive>` (the regex rejects `timeout 0`,
#     which would disable the bound); root's ref read is bounded the same
#     way.
#   - BEHAVIOURAL (runs the REAL rendered script): point the deploy at a
#     missing origin and run the actual nixos-deploy script; assert it
#     exits non-zero, returns promptly (no hang), and does NOT latch the
#     (never-computed) SHA as poisoned.
#   - BEHAVIOURAL (success/failure bookkeeping): re-run the rendered
#     script against a REAL local origin with ONLY the `nixos-rebuild
#     switch` invocation stubbed (`true` / `false` / `exit 75`); assert
#     the success tail records the deployed SHA in `last-good` (and
#     migrates away the pre-rename `last-deployed-sha` file), and that a
#     failed deploy latches without advancing `last-good`.
#   - BEHAVIOURAL (privilege split, #389). Each of these fails if the
#     property it names is lost, not merely if a unit goes missing:
#       a. the fetch half is NOT root: an origin readable only by root
#          cannot be fetched by it (a fetch that regained root would read
#          it and the deploy would go through), and everything it writes
#          is owned by nixos-fetch;
#       b. root does not apply what the fetch half hands it: a hostile
#          fetch stage (ExecStartPost running as the fetch user, inside
#          its real unit) advances its own branch tip to a commit that
#          descends from the real target. Root must deploy the SHA it
#          resolved itself, and the hostile commit must not even reach
#          root's object store;
#       c. the fetch user cannot write the tree root builds from, and
#          root refuses to build a tree that any other uid owns.
#
# What the VM canNOT model: a genuine network *stall* to github (the
# literal incident) and GitHub's TLS identity. That a hung fetch is
# aborted rests on the `timeout <positive>` wraps (asserted statically)
# + coreutils `timeout` semantics, and is verified on the live host at
# deploy time.
#
# mkMinimalTest + the module under test enabled with a no-secret config
# (sshKeyFile null, webhook off, notifyUser null) so the unit renders
# without agenix. workingDir and remote are redirected to scratch repos
# so the real script runs without touching a real /etc/nixos clone or
# the network.
#
# Run: nix build .#checks.x86_64-linux.vm-auto-deploy -L
{ pkgs, inputs }:
let
  origin = "/srv/deploy-origin";
  workingDir = "/var/lib/deploy-repo";
  fetchState = "/var/lib/nixos-deploy-fetch";

  # A compromised fetch stage, as it would actually run: inside the real
  # nixos-deploy-fetch unit, as the fetch user, after the honest fetch.
  # Installed as a runtime drop-in only for the tamper step.
  hostileFetch = pkgs.writeShellScript "hostile-fetch-stage" ''
    set -eu
    export GIT_CONFIG_GLOBAL=/dev/null
    g() { ${pkgs.git}/bin/git --git-dir=${fetchState}/source.git "$@"; }
    tip=$(g rev-parse refs/heads/main)
    blob=$(printf 'owned\n' | g hash-object -w --stdin)
    tree=$( { g ls-tree "$tip"; printf '100644 blob %s\tpwned\n' "$blob"; } | g mktree )
    evil=$(g -c user.name=evil -c user.email=evil@invalid commit-tree -p "$tip" -m evil "$tree")
    g update-ref refs/heads/main "$evil"
    printf '%s\n' "$evil" > ${fetchState}/evil-sha
    # And straight at the tree root builds from. Must fail.
    if ${pkgs.coreutils}/bin/touch ${workingDir}/pwned-by-fetch 2>/dev/null; then
      echo wrote > ${fetchState}/wrote-working-dir
    fi
  '';
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-auto-deploy";
  extraModules = [
    ../modules/nixos/build-coordination.nix
    ../modules/nixos/nixos-auto-deploy.nix
    ({ lib, pkgs, ... }: {
      services.buildCoordination.enable = true;
      services.nixos-auto-deploy = {
        enable = true;
        notifyUser = null;
        inherit workingDir;
        # A local path instead of GitHub: both halves resolve it the same
        # way they resolve the production URL.
        remote = origin;
      };

      # The test origin is root-owned and the fetch user reads it, which
      # git's ownership check would refuse. Production's origin is a URL,
      # where no such check applies.
      programs.git = {
        enable = true;
        config.safe.directory = origin;
      };

      environment.etc."deploy-hostile-fetch".source = hostileFetch;

      # Keep the real deploy service in its start phase while a candidate
      # configuration changes its unit. This reproduces the production
      # self-update path without running a nested rebuild from the test unit.
      systemd.services.nixos-deploy.serviceConfig.ExecStartPre =
        "${pkgs.coreutils}/bin/sleep 300";

      # Negative control: unlike nixos-deploy, an ordinary changed service
      # must restart, proving the switch exercised changed-unit handling.
      systemd.services.deploy-restart-canary = {
        description = "Deploy restart canary v1";
        serviceConfig = {
          Type = "simple";
          ExecStart = "${pkgs.writeShellScript "deploy-restart-canary-v1" ''
            exec ${pkgs.coreutils}/bin/sleep 300
          ''}";
        };
      };

      specialisation.deploy-self-update.configuration = {
        systemd.services.nixos-deploy.serviceConfig = {
          ExecStartPre = lib.mkForce [ ];
          ExecStart = lib.mkForce "${pkgs.coreutils}/bin/false";
        };
        systemd.services.deploy-restart-canary.serviceConfig.ExecStart =
          lib.mkForce "${pkgs.writeShellScript "deploy-restart-canary-v2" ''
            exec ${pkgs.coreutils}/bin/sleep 300
          ''}";
      };
    })
  ];
  testScript = ''
    ORIGIN = "${origin}"
    WD = "${workingDir}"
    FETCH_STATE = "${fetchState}"

    def commit(msg, content=None):
        if content is not None:
            workstation.succeed(f"printf '%s\\n' '{content}' > /root/origin-wt/marker")
        workstation.succeed(
            "git -C /root/origin-wt add -A "
            "&& git -C /root/origin-wt -c user.email=t@test -c user.name=t "
            f"commit -q --allow-empty -m {msg} "
            f"&& git -C /root/origin-wt push -q {ORIGIN} HEAD:main"
        )
        return workstation.succeed(f"git -C {ORIGIN} rev-parse main").strip()

    def head():
        return workstation.succeed(f"git -C {WD} rev-parse HEAD").strip()

    def last_good():
        return workstation.succeed(
            "cat /var/lib/nixos-deploy/last-good 2>/dev/null || echo MISSING"
        ).strip()

    def latch():
        return workstation.succeed("cat /var/lib/nixos-deploy/poison-latch").strip()

    workstation.wait_for_unit("multi-user.target")

    # 1. Unit backstop: the whole run is time-bounded.
    workstation.succeed(
        "systemctl cat nixos-deploy.service | grep -q 'TimeoutStartSec=60min'"
    )

    # Resolve the original scripts before switching to the deliberately
    # broken candidate, whose ExecStart is /bin/false by construction.
    script = workstation.succeed(
        "systemctl cat nixos-deploy.service "
        "| awk -F= '/^ExecStart=/{print $2}'"
    ).strip()
    fetch_script = workstation.succeed(
        "systemctl cat nixos-deploy-fetch.service "
        "| awk -F= '/^ExecStart=/{print $2}'"
    ).strip()
    assert fetch_script, "nixos-deploy-fetch.service has no ExecStart"

    # A deploy changes this unit whenever its rendered script changes. The
    # running oneshot must survive its own switch; otherwise its parent dies,
    # bookkeeping never reaches last-good, and a timer retry collides with the
    # still-running switch-to-configuration transient unit.
    workstation.succeed("systemctl start --no-block nixos-deploy.service")
    workstation.wait_until_succeeds(
        "test \"$(systemctl show -P ActiveState nixos-deploy.service)\" = activating"
    )
    workstation.succeed("systemctl start deploy-restart-canary.service")
    deploy_invocation_before = workstation.succeed(
        "systemctl show -P InvocationID nixos-deploy.service"
    ).strip()
    canary_invocation_before = workstation.succeed(
        "systemctl show -P InvocationID deploy-restart-canary.service"
    ).strip()
    rc, switch_out = workstation.execute(
        "timeout 30 /run/current-system/specialisation/deploy-self-update/"
        "bin/switch-to-configuration test 2>&1"
    )
    print(f"[diag] deploy self-update switch rc={rc} out={switch_out!r}")
    assert rc == 0, switch_out
    deploy_invocation_after = workstation.succeed(
        "systemctl show -P InvocationID nixos-deploy.service"
    ).strip()
    canary_invocation_after = workstation.succeed(
        "systemctl show -P InvocationID deploy-restart-canary.service"
    ).strip()
    assert deploy_invocation_after == deploy_invocation_before, (
        "nixos-deploy stopped itself during its own configuration switch: "
        f"{deploy_invocation_before} -> {deploy_invocation_after}"
    )
    assert canary_invocation_after != canary_invocation_before, (
        "negative control did not restart, so candidate switch did not "
        "exercise changed-unit handling"
    )
    workstation.succeed("systemctl stop nixos-deploy.service deploy-restart-canary.service")

    # 2. Network bounds: a stalled connection must abort, in both halves.
    workstation.succeed(f"grep -q 'ConnectTimeout=15' {fetch_script}")
    workstation.succeed(f"grep -q 'ServerAliveInterval=15' {fetch_script}")
    workstation.succeed(f"grep -q 'ServerAliveCountMax=4' {fetch_script}")
    # POSITIVE bounds — the regex rejects `timeout 0`, which disables it.
    workstation.succeed(f"grep -qE 'timeout [1-9][0-9]* git .*fetch' {fetch_script}")
    workstation.succeed(f"grep -qE 'timeout [1-9][0-9]* git ls-remote' {script}")

    # 3. Behavioural: run the REAL script against a missing origin. The
    #    ref read fails fast; the script must exit non-zero, return
    #    promptly, and NOT latch anything (a transient network failure is
    #    not a bad commit).
    workstation.succeed(f"git init -q {WD}")
    rc, out = workstation.execute(f"{script} 2>&1")
    print(f"[diag] deploy script rc={rc} out={out!r}")
    assert rc != 0, f"script should exit non-zero on a dead origin, got rc={rc}"
    assert "git ls-remote failed" in out, (
        f"script did not reach/handle the ref-read failure branch: {out!r}"
    )
    workstation.succeed("test -e /var/lib/nixos-deploy/poison-latch")
    assert latch() == "", f"a dead origin must NOT latch a SHA; poison-latch={latch()!r}"
    # The lock was released on exit: a re-run reaches the same branch.
    rc2, out2 = workstation.execute(f"{script} 2>&1")
    assert rc2 != 0 and "another run in progress" not in out2 and "git ls-remote failed" in out2, (
        f"lock not released / didn't re-reach the ref-read branch (rc2={rc2}): {out2!r}"
    )

    # 4. Success-path bookkeeping: a successful deploy records the
    #    deployed SHA in last-good. Runs the REAL rendered script with
    #    ONLY the `nixos-rebuild switch` invocation stubbed to `true`.
    workstation.succeed(
        f"git init -q --bare -b main {ORIGIN} "
        "&& git init -q -b main /root/origin-wt"
    )
    target = commit("seed", "v1")
    workstation.succeed(
        f"sed 's|nixos-rebuild switch --flake|true --flake|' {script} "
        "> /tmp/deploy-stub-ok "
        "&& grep -q 'true --flake' /tmp/deploy-stub-ok "
        "&& chmod +x /tmp/deploy-stub-ok"
    )
    # Memory admission is a clean deferral, not a failed target. Hold the
    # production lock, run the real script with only rebuild stubbed, and
    # require no success record and no poison latch entry.
    holder = workstation.succeed(
        "sh -c 'exec 9>/home/jonathan/.nix-memory-pressure/lock; "
        "flock 9; "
        "echo locked >/tmp/deploy-memory-lock-held; sleep 60' "
        ">/tmp/deploy-memory-lock-holder.log 2>&1 & echo $!"
    ).strip()
    workstation.wait_until_succeeds("test -f /tmp/deploy-memory-lock-held")
    rc, out = workstation.execute("/tmp/deploy-stub-ok 2>&1")
    assert rc == 0 and "deploy deferred" in out, (rc, out)
    workstation.fail("test -e /var/lib/nixos-deploy/last-good")
    assert latch() == "", latch()
    workstation.succeed(f"kill {holder}")
    workstation.wait_until_succeeds(f"test ! -e /proc/{holder}")

    # Seed the pre-rename state file: the script must migrate it to
    # last-good (mv), not leave a second, permanently-stale record.
    workstation.succeed("printf 'deadbeef\\n' > /var/lib/nixos-deploy/last-deployed-sha")
    rc, out = workstation.execute("/tmp/deploy-stub-ok 2>&1")
    print(f"[diag] success-path rc={rc} out={out!r}")
    assert rc == 0 and f"deploy success: {target}" in out, (
        f"stubbed success run did not reach the success tail (rc={rc}): {out!r}"
    )
    assert last_good() == target, (last_good(), target)
    assert head() == target, (head(), target)
    workstation.succeed(f"grep -qx v1 {WD}/marker")
    workstation.succeed("test ! -e /var/lib/nixos-deploy/last-deployed-sha")

    # 4b. Idempotency: an unchanged origin is a no-op.
    rc, out = workstation.execute("/tmp/deploy-stub-ok 2>&1")
    assert rc == 0 and f"already at {target}; no-op" in out, (rc, out)

    # 5. Exit 75 from a rebuild is a real build failure, not lock contention.
    target2 = commit("exit-75")
    workstation.succeed(
        f"sed \"s|nixos-rebuild switch --flake|sh -c 'exit 75' --|\" {script} "
        "> /tmp/deploy-stub-75 "
        "&& grep -q \"sh -c 'exit 75'\" /tmp/deploy-stub-75 "
        "&& chmod +x /tmp/deploy-stub-75"
    )
    rc, out = workstation.execute("/tmp/deploy-stub-75 2>&1")
    print(f"[diag] exit-75-path rc={rc} out={out!r}")
    assert rc != 0 and "latched as poisoned" in out and "deferred" not in out, (
        f"a started rebuild exiting 75 was mistaken for contention (rc={rc}): {out!r}"
    )
    assert last_good() == target, (last_good(), target)
    assert latch() == target2, (latch(), target2)

    # 6. Failure path must NOT advance last-good.
    target3 = commit("next")
    workstation.succeed(
        f"sed 's|nixos-rebuild switch --flake|false --flake|' {script} "
        "> /tmp/deploy-stub-fail "
        "&& grep -q 'false --flake' /tmp/deploy-stub-fail "
        "&& chmod +x /tmp/deploy-stub-fail"
    )
    rc, out = workstation.execute("/tmp/deploy-stub-fail 2>&1")
    print(f"[diag] failure-path rc={rc} out={out!r}")
    assert rc != 0 and "latched as poisoned" in out, (
        f"stubbed failure run should latch + exit non-zero (rc={rc}): {out!r}"
    )
    assert last_good() == target, (last_good(), target)
    # target2 is an ancestor of target3, so the auto-clear dropped it.
    assert latch() == target3, latch()

    # 7a. The fetch half is not root. Make the origin readable by root
    #     only: root's own ref read still works, the fetch must not. A
    #     fetch stage that regained root would read it and this deploy
    #     would succeed. A failed fetch is a retry, never a poisoned SHA.
    target4 = commit("root-only-origin", "v4")
    workstation.succeed(f"chmod 0700 {ORIGIN}")
    rc, out = workstation.execute("/tmp/deploy-stub-ok 2>&1")
    print(f"[diag] root-only-origin rc={rc} out={out!r}")
    workstation.succeed(f"chmod 0755 {ORIGIN}")
    assert rc != 0 and "fetch stage failed" in out, (
        f"the fetch stage read a root-only origin, or failed elsewhere (rc={rc}): {out!r}"
    )
    assert last_good() == target, (last_good(), target)
    assert target4 not in latch(), latch()
    # Everything the fetch half has ever written is the fetch user's.
    workstation.succeed(f"test -d {FETCH_STATE}/source.git/objects")
    not_fetch_owned = workstation.succeed(
        f"find {FETCH_STATE} ! -user nixos-fetch -print"
    ).strip()
    assert not_fetch_owned == "", f"fetch stage wrote as another uid: {not_fetch_owned!r}"

    # 7b. A hostile fetch stage cannot choose what root deploys. It runs
    #     inside the real fetch unit, as the fetch user, after the honest
    #     fetch, and moves its branch tip to a commit that DESCENDS from
    #     the real target (so an ancestry check alone would accept it).
    target5 = commit("real-target", "v5")
    workstation.succeed(
        "mkdir -p /run/systemd/system/nixos-deploy-fetch.service.d "
        "&& printf '[Service]\\nExecStartPost=/etc/deploy-hostile-fetch\\n' "
        "> /run/systemd/system/nixos-deploy-fetch.service.d/hostile.conf "
        "&& systemctl daemon-reload"
    )
    rc, out = workstation.execute("/tmp/deploy-stub-ok 2>&1")
    print(f"[diag] hostile-fetch rc={rc} out={out!r}")
    evil = workstation.succeed(f"cat {FETCH_STATE}/evil-sha").strip()
    workstation.succeed(
        "rm -r /run/systemd/system/nixos-deploy-fetch.service.d && systemctl daemon-reload"
    )
    assert evil and evil != target5, (evil, target5)
    assert rc == 0 and f"deploy success: {target5}" in out, (rc, out)
    assert head() == target5, f"root built {head()}, not the SHA it resolved ({target5})"
    assert last_good() == target5, (last_good(), target5)
    workstation.fail(f"test -e {WD}/pwned")
    workstation.fail(f"git -C {WD} cat-file -e {evil}")
    # The poison entries were ancestors of the new target: auto-cleared.
    assert latch() == "", latch()

    # 7c. The fetch user cannot write the tree root builds from — neither
    #     from inside its unit (above) nor as a plain process.
    workstation.fail(f"test -e {FETCH_STATE}/wrote-working-dir")
    workstation.fail(f"test -e {WD}/pwned-by-fetch")
    workstation.fail(f"runuser -u nixos-fetch -- touch {WD}/x")
    workstation.fail(f"runuser -u nixos-fetch -- sh -c 'echo x >> {WD}/marker'")
    workstation.fail(f"runuser -u nixos-fetch -- touch {WD}/.git/x")

    # 7d. Root refuses to build a tree another uid could have modified,
    #     and that refusal is not the commit's fault: no poison.
    target6 = commit("after-tamper", "v6")
    workstation.succeed(f"chown nixos-fetch {WD}/marker")
    rc, out = workstation.execute("/tmp/deploy-stub-ok 2>&1")
    print(f"[diag] foreign-owned-tree rc={rc} out={out!r}")
    assert rc != 0 and "refusing to build" in out, (rc, out)
    assert head() == target5 and last_good() == target5, (head(), last_good())
    assert latch() == "", latch()
    workstation.succeed(f"chown root {WD}/marker && chmod g+w {WD}/marker")
    rc, out = workstation.execute("/tmp/deploy-stub-ok 2>&1")
    assert rc != 0 and "refusing to build" in out, (rc, out)
    workstation.succeed(f"chmod g-w {WD}/marker")
    rc, out = workstation.execute("/tmp/deploy-stub-ok 2>&1")
    assert rc == 0 and f"deploy success: {target6}" in out, (rc, out)
    assert head() == target6, (head(), target6)
  '';
}
