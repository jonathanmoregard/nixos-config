# vm-auto-deploy: the CD path cannot wedge forever, a failed fetch is
# handled cleanly, and success/failure bookkeeping lands in `last-good`.
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
#     script carries ssh ConnectTimeout + ServerAlive*, and wraps the
#     fetch in `timeout <positive>` (the regex rejects `timeout 0`,
#     which would disable the bound).
#   - BEHAVIOURAL (runs the REAL rendered script): point the deploy
#     repo at a bogus origin and run the actual nixos-deploy script;
#     assert it exits non-zero on the fetch failure, returns promptly
#     (no hang), and — critically — does NOT latch the (never-computed)
#     SHA as poisoned. This exercises the real fetch-failure branch,
#     not a hand-typed analogue.
#   - BEHAVIOURAL (success/failure bookkeeping): re-run the rendered
#     script against a REAL local origin with ONLY the `nixos-rebuild
#     switch` invocation stubbed (`if true` / `if false`); assert the
#     success tail records the deployed SHA in `last-good` (and
#     migrates away the pre-rename `last-deployed-sha` file), and that
#     a failed deploy latches without advancing `last-good`. Guards
#     the stale-last-good bug: 4ad9306 (2026-05-06) renamed the old
#     module's `last-good` state file to `last-deployed-sha`, so the
#     on-disk `last-good` the docs advertise froze at the old module's
#     final deploy (64fc3c4, 2026-05-05) while deploys kept succeeding.
#
# What the VM canNOT model: a genuine network *stall* to github over
# ssh (the literal incident). That a hung fetch is aborted rests on
# the `timeout <positive>` wrap (asserted statically) + coreutils
# `timeout` semantics, and is verified on the live host at deploy time.
#
# mkMinimalTest + the module under test enabled with a no-secret config
# (sshKeyFile null, webhook off, notifyUser null) so the unit renders
# without agenix. workingDir is redirected to a scratch repo so the
# real script can run without touching a real /etc/nixos clone.
#
# Run: nix build .#checks.x86_64-linux.vm-auto-deploy -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-auto-deploy";
  extraModules = [
    ../modules/nixos/nixos-auto-deploy.nix
    {
      services.nixos-auto-deploy = {
        enable = true;
        notifyUser = null;
        # Scratch repo (created in testScript) so the real script can be
        # invoked without a populated /etc/nixos git clone.
        workingDir = "/tmp/deploy-repo";
      };
    }
    # git for the testScript's scratch-repo setup (the deploy script
    # brings its own via runtimeInputs; this is for the test harness).
    { environment.systemPackages = [ pkgs.git ]; }
  ];
  testScript = ''
    dellan.wait_for_unit("multi-user.target")

    # 1. Unit backstop: the whole run is time-bounded.
    dellan.succeed(
        "systemctl cat nixos-deploy.service | grep -q 'TimeoutStartSec=60min'"
    )

    # Resolve the deploy script from the unit's ExecStart.
    script = dellan.succeed(
        "systemctl cat nixos-deploy.service "
        "| awk -F= '/^ExecStart=/{print $2}'"
    ).strip()

    # 2. Script-level network bounds: a stalled connection must abort.
    dellan.succeed(f"grep -q 'ConnectTimeout=15' {script}")
    dellan.succeed(f"grep -q 'ServerAliveInterval=15' {script}")
    dellan.succeed(f"grep -q 'ServerAliveCountMax=4' {script}")
    # The fetch is wrapped in `timeout` with a POSITIVE bound — the
    # regex rejects `timeout 0 git fetch`, which would disable it.
    dellan.succeed(f"grep -qE 'timeout [1-9][0-9]* git fetch' {script}")

    # 3. Behavioural: run the REAL script against a bogus origin. The
    #    fetch fails fast; the script must exit non-zero, return
    #    promptly, and NOT latch the commit as poisoned (a transient
    #    network failure is not a bad commit).
    dellan.succeed(
        "git init -q /tmp/deploy-repo "
        "&& git -C /tmp/deploy-repo remote add origin /tmp/nonexistent-origin"
    )
    rc, out = dellan.execute(f"{script} 2>&1")
    print(f"[diag] deploy script rc={rc} out={out!r}")
    assert rc != 0, f"script should exit non-zero on fetch failure, got rc={rc}"
    # Prove it exited AT THE FETCH, not via some other nonzero branch
    # (manual-hold, etc.) — otherwise rc!=0 alone is hollow.
    assert "git fetch failed" in out, (
        f"script did not reach/handle the fetch-failure branch: {out!r}"
    )
    # poison-latch must exist (touched at start) but be EMPTY — nothing
    # latched, because target_sha is never reached on a fetch failure.
    dellan.succeed("test -e /var/lib/nixos-deploy/poison-latch")
    latch = dellan.succeed("cat /var/lib/nixos-deploy/poison-latch")
    assert latch.strip() == "", (
        f"fetch failure must NOT latch a poisoned SHA; poison-latch={latch!r}"
    )
    # And the next run can still acquire the lock (it was released on
    # exit) — re-running reaches the same fetch-failure path, not a
    # "another run in progress" no-op.
    rc2, out2 = dellan.execute(f"{script} 2>&1")
    assert rc2 != 0 and "another run in progress" not in out2 and "git fetch failed" in out2, (
        f"lock not released / didn't re-reach fetch branch (rc2={rc2}): {out2!r}"
    )

    # 4. Success-path bookkeeping: a successful deploy must record the
    #    deployed SHA in /var/lib/nixos-deploy/last-good. Runs the REAL
    #    rendered script with ONLY the `nixos-rebuild switch` invocation
    #    stubbed to `true` (the VM cannot run a real switch); fetch,
    #    poison-latch handling and the bookkeeping tail are untouched.
    dellan.succeed(
        "git init -q -b main /tmp/origin-repo "
        "&& git -C /tmp/origin-repo -c user.email=t@test -c user.name=t "
        "commit -q --allow-empty -m seed"
    )
    target = dellan.succeed("git -C /tmp/origin-repo rev-parse main").strip()
    dellan.succeed("git -C /tmp/deploy-repo remote set-url origin /tmp/origin-repo")
    dellan.succeed(
        f"sed 's|if nixos-rebuild switch --flake|if true --flake|' {script} "
        "> /tmp/deploy-stub-ok "
        "&& grep -q 'if true --flake' /tmp/deploy-stub-ok "
        "&& chmod +x /tmp/deploy-stub-ok"
    )
    # Seed the pre-rename state file: the script must migrate it to
    # last-good (mv), not leave a second, permanently-stale record —
    # an orphaned state file is exactly the bug class under test.
    dellan.succeed("printf 'deadbeef\\n' > /var/lib/nixos-deploy/last-deployed-sha")
    rc, out = dellan.execute("/tmp/deploy-stub-ok 2>&1")
    print(f"[diag] success-path rc={rc} out={out!r}")
    assert rc == 0 and f"deploy success: {target}" in out, (
        f"stubbed success run did not reach the success tail (rc={rc}): {out!r}"
    )
    last_good = dellan.succeed(
        "cat /var/lib/nixos-deploy/last-good 2>/dev/null || echo MISSING"
    ).strip()
    assert last_good == target, (
        f"last-good must equal the deployed SHA; got {last_good!r}, want {target!r}"
    )
    dellan.succeed("test ! -e /var/lib/nixos-deploy/last-deployed-sha")

    # 5. Failure path must NOT advance last-good (it is last-GOOD, not
    #    last-attempted): a new commit whose rebuild fails is latched
    #    as poisoned while last-good keeps the previously-deployed SHA.
    dellan.succeed(
        "git -C /tmp/origin-repo -c user.email=t@test -c user.name=t "
        "commit -q --allow-empty -m next"
    )
    target2 = dellan.succeed("git -C /tmp/origin-repo rev-parse main").strip()
    dellan.succeed(
        f"sed 's|if nixos-rebuild switch --flake|if false --flake|' {script} "
        "> /tmp/deploy-stub-fail "
        "&& grep -q 'if false --flake' /tmp/deploy-stub-fail "
        "&& chmod +x /tmp/deploy-stub-fail"
    )
    rc, out = dellan.execute("/tmp/deploy-stub-fail 2>&1")
    print(f"[diag] failure-path rc={rc} out={out!r}")
    assert rc != 0 and "latched as poisoned" in out, (
        f"stubbed failure run should latch + exit non-zero (rc={rc}): {out!r}"
    )
    last_good = dellan.succeed("cat /var/lib/nixos-deploy/last-good").strip()
    assert last_good == target, (
        f"failed deploy must not advance last-good; got {last_good!r}, want {target!r}"
    )
    latch = dellan.succeed("cat /var/lib/nixos-deploy/poison-latch").strip()
    assert latch == target2, f"poison-latch should hold {target2!r}; got {latch!r}"
  '';
}
