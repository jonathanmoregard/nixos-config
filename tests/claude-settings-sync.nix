# vm-claude-settings-sync: the checked-in settings.json wins after a deploy
# tick. Each scenario is labelled in the test script below.
#
# Drives the real chain offline — a commit lands in a local remote, the real
# claude-runtime-deploy.service fast-forwards its clone, and its OnSuccess=
# runs the sync unit. The sync unit is never started by hand, so a broken
# trigger fails the lane.
#
# Run: nix build .#checks.x86_64-linux.vm-claude-settings-sync -L
{ pkgs, inputs }:
let
  git = "${pkgs.git}/bin/git";
  puller = pkgs.writeText "claude-pull.sh" ''
    #!/bin/sh
    set -eu
    exec git -C "$CLAUDE_PULL_REPO" pull --ff-only -q
  '';
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkMinimalTest {
  name = "vm-claude-settings-sync";
  extraModules = [
    ../modules/nixos/claude-runtime-deploy.nix
    ../modules/nixos/claude-settings-sync.nix
  ];
  testScript = ''
    import datetime
    import json
    import shlex

    seed = "/var/lib/claude-runtime-seed"
    served = f"{seed}/runtime/settings.json"
    clone = "/var/lib/claude-runtime/checkout/runtime/settings.json"
    live = "/home/jonathan/.claude/settings.json"
    record = "/var/lib/unit-failures/claude-settings-sync.json"

    DCG = {"matcher": "Bash|PowerShell",
           "hooks": [{"type": "command", "command": "/nix/store/x-dcg/bin/dcg"}]}
    GUARD = {"matcher": "Bash",
             "hooks": [{"type": "command", "command": "python3 bash-guard.py"}]}
    BASE = {"model": "opus[1m]", "env": {},
            "hooks": {"PreToolUse": [GUARD]},
            # Fixture settings for the VM's throwaway home, not a real grant.
            # arftl-allow: permission-widened
            "permissions": {"allow": ["Read(//a/**)"]}}

    def as_deploy(cmd):
        return workstation.succeed(f"su claude-deploy -s /bin/sh -c {shlex.quote(cmd)}")

    def as_jonathan(cmd):
        return workstation.succeed(f"su jonathan -c {shlex.quote(cmd)}")

    def publish(text, message):
        """Commit TEXT as the served settings.json in the remote."""
        as_deploy(f"cat > {served} <<'EOF'\n{text}\nEOF")
        as_deploy(f"cd {seed} && ${git} -c user.name=t -c user.email=t@t.invalid "
                  f"-c commit.gpgsign=false commit -qam {shlex.quote(message)}")

    def publish_doc(doc, message):
        publish(json.dumps(doc, indent=2), message)

    def sync_invocation():
        return workstation.succeed(
            "systemctl show -P InvocationID claude-settings-sync.service").strip()

    def tick():
        """One deploy tick; returns the sync unit's Result once it has run.

        The reset clears the deploy unit's START LIMIT, not a failure of it:
        this lane fires ticks back to back and exceeds systemd's default burst
        of 5, which production spacing never approaches.
        """
        before = sync_invocation()
        workstation.execute("systemctl reset-failed claude-runtime-deploy.service")
        workstation.succeed("systemctl start claude-runtime-deploy.service")
        workstation.wait_until_succeeds(
            f"[ \"$(systemctl show -P InvocationID claude-settings-sync.service)\" != {shlex.quote(before)} ] && "
            "systemctl show -P ActiveState claude-settings-sync.service | grep -qx -e inactive -e failed",
            timeout=datetime.timedelta(seconds=60))
        return workstation.succeed(
            "systemctl show -P Result claude-settings-sync.service").strip()

    def read_live():
        return json.loads(workstation.succeed(f"cat {live}"))

    def assert_live_is_served():
        """The whole contract. cmp exits non-zero on any difference."""
        workstation.succeed(f"cmp {live} {clone}")

    workstation.wait_for_unit("multi-user.target")
    workstation.succeed("systemctl stop claude-runtime-deploy.timer")

    # A remote holding the puller and the served settings.
    workstation.succeed(
        f"install -d -o claude-deploy -g claude-deploy {seed}/runtime/scripts && "
        f"install -m 0755 -o claude-deploy -g claude-deploy ${puller} {seed}/runtime/scripts/claude-pull.sh && "
        f"chown -R claude-deploy:claude-deploy {seed}")
    as_deploy(f"cd {seed} && ${git} -c init.defaultBranch=master init -q")
    as_deploy(f"cat > {served} <<'EOF'\n{json.dumps(BASE, indent=2)}\nEOF")
    as_deploy(f"cd {seed} && ${git} add -A && ${git} -c user.name=t -c user.email=t@t.invalid "
              "-c commit.gpgsign=false commit -qm seed")
    workstation.succeed(
        "install -d /run/systemd/system/claude-runtime-deploy.service.d && "
        f"printf '[Service]\\nEnvironment=CLAUDE_RUNTIME_DEPLOY_REMOTE=file://%s\\n' {seed} > "
        "/run/systemd/system/claude-runtime-deploy.service.d/99-local-remote.conf && "
        "systemctl daemon-reload")
    workstation.execute("systemctl reset-failed claude-runtime-deploy.service")

    # ── Before cutover the sync runs and does nothing ──
    assert tick() == "success"
    workstation.fail(f"test -e {live}")

    # ── The live file as tuxedo had it: a live-only dcg group and a model pin ──
    live_doc = json.loads(json.dumps(BASE))
    live_doc["model"] = "claude-opus-5"
    live_doc["hooks"]["PreToolUse"].insert(0, DCG)
    as_jonathan("mkdir -p ~/.claude && touch ~/.claude/.projection-enabled")
    as_jonathan(f"cat > {live} <<'EOF'\n{json.dumps(live_doc, indent=2)}\nEOF")

    # ── One tick and the checked-in file wins outright ──
    probe = json.loads(json.dumps(BASE))
    probe["env"]["SETTINGS_SYNC_PROBE"] = "arrived"
    assert "SETTINGS_SYNC_PROBE" not in read_live()["env"]
    publish_doc(probe, "probe")
    assert tick() == "success", workstation.succeed(
        "journalctl -u claude-settings-sync.service --no-pager | tail -20")
    assert_live_is_served()
    got = read_live()
    assert got["env"].get("SETTINGS_SYNC_PROBE") == "arrived", got
    assert DCG not in got["hooks"]["PreToolUse"], got
    assert GUARD in got["hooks"]["PreToolUse"], got
    assert got["model"] == "opus[1m]", got
    owner = workstation.succeed(f"stat -c '%U:%G %a' {live}").strip()
    assert owner == "jonathan:users 644", owner
    workstation.fail(f"test -e {record}")

    # ── A runtime write does not survive the next tick ──
    as_jonathan(
        "${pkgs.python3}/bin/python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); "
        "d[\"permissions\"][\"allow\"].append(\"Bash(ls:*)\"); "
        "json.dump(d, open(p, \"w\"), indent=2)' " + live)
    publish_doc(BASE, "drop probe")
    assert tick() == "success"
    assert_live_is_served()
    got = read_live()
    assert "SETTINGS_SYNC_PROBE" not in got["env"], got
    assert "Bash(ls:*)" not in got["permissions"]["allow"], got

    # ── Upstream deleting a key is a success, not a refusal ──
    pruned = json.loads(json.dumps(BASE))
    del pruned["hooks"]["PreToolUse"]
    publish_doc(pruned, "prune the hook key")
    assert tick() == "success"
    assert_live_is_served()
    assert "PreToolUse" not in read_live()["hooks"], read_live()

    # ── An unusable served file fails loudly and leaves the live one alone ──
    before = workstation.succeed(f"sha256sum {live}").split()[0]
    publish("{ truncated", "unparseable")
    assert tick() == "exit-code"
    assert workstation.succeed(f"sha256sum {live}").split()[0] == before
    # OnFailure's notifier is a separate unit, so the record is not there the
    # moment the sync unit is "failed". wait_for_unit cannot be used: the
    # notifier is a oneshot without RemainAfterExit, never observably active.
    workstation.wait_for_file(record)
    rec = json.loads(workstation.succeed(f"cat {record}"))
    assert rec["unit"] == "claude-settings-sync.service", rec
    log = workstation.succeed("journalctl -u claude-settings-sync.service --no-pager")
    assert "is not valid JSON" in log, log

    # ── Repaired upstream: the next tick succeeds and clears the record ──
    publish_doc(BASE, "repair")
    assert tick() == "success"
    workstation.fail(f"test -e {record}")
    assert_live_is_served()
  '';
}
