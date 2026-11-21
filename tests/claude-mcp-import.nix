# vm-claude-mcp-import: a server merged into claude-config's mcp-servers.json
# reaches ~/.claude.json after a deploy tick, without touching live-only state.
#
# Same offline chain as vm-claude-settings-sync: a commit lands in a local
# remote, the real claude-runtime-deploy.service fast-forwards its clone, and
# its OnSuccess= runs the import. The import is never started by hand, so a
# broken trigger fails the lane.
#
# Run: nix build .#checks.x86_64-linux.vm-claude-mcp-import -L
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
  name = "vm-claude-mcp-import";
  extraModules = [
    ../modules/nixos/claude-runtime-deploy.nix
    ../modules/nixos/claude-mcp-import.nix
  ];
  testScript = ''
    import datetime
    import json
    import shlex

    seed = "/var/lib/claude-runtime-seed"
    served = f"{seed}/runtime/mcp-servers.json"
    live = "/home/jonathan/.claude.json"
    record = "/var/lib/unit-failures/claude-mcp-import.json"

    GITHUB = {"type": "stdio", "command": "github-mcp", "args": ["stdio"], "env": {}}
    BROKER = {"type": "stdio", "command": "agent-e2e-broker", "args": [], "env": {}}
    SCRATCH = {"type": "stdio", "command": "scratch-mcp", "args": [], "env": {}}

    def as_deploy(cmd):
        return workstation.succeed(f"su claude-deploy -s /bin/sh -c {shlex.quote(cmd)}")

    def as_jonathan(cmd):
        return workstation.succeed(f"su jonathan -c {shlex.quote(cmd)}")

    def publish(text, message):
        as_deploy(f"cat > {served} <<'EOF'\n{text}\nEOF")
        as_deploy(f"cd {seed} && ${git} -c user.name=t -c user.email=t@t.invalid "
                  f"-c commit.gpgsign=false commit -qam {shlex.quote(message)}")

    def invocation():
        return workstation.succeed(
            "systemctl show -P InvocationID claude-mcp-import.service").strip()

    def tick():
        """One deploy tick; returns the import unit's Result once it has run."""
        before = invocation()
        workstation.execute("systemctl reset-failed claude-runtime-deploy.service")
        workstation.succeed("systemctl start claude-runtime-deploy.service")
        workstation.wait_until_succeeds(
            f"[ \"$(systemctl show -P InvocationID claude-mcp-import.service)\" != {shlex.quote(before)} ] && "
            "systemctl show -P ActiveState claude-mcp-import.service | grep -qx -e inactive -e failed",
            timeout=datetime.timedelta(seconds=60))
        return workstation.succeed(
            "systemctl show -P Result claude-mcp-import.service").strip()

    def read_live():
        return json.loads(workstation.succeed(f"cat {live}"))

    workstation.wait_for_unit("multi-user.target")
    workstation.succeed("systemctl stop claude-runtime-deploy.timer")

    workstation.succeed(
        f"install -d -o claude-deploy -g claude-deploy {seed}/runtime/scripts && "
        f"install -m 0755 -o claude-deploy -g claude-deploy ${puller} {seed}/runtime/scripts/claude-pull.sh && "
        f"chown -R claude-deploy:claude-deploy {seed}")
    as_deploy(f"cd {seed} && ${git} -c init.defaultBranch=master init -q")
    as_deploy(f"cat > {served} <<'EOF'\n{json.dumps({'github': GITHUB}, indent=2)}\nEOF")
    as_deploy(f"cd {seed} && ${git} add -A && ${git} -c user.name=t -c user.email=t@t.invalid "
              "-c commit.gpgsign=false commit -qm seed")
    workstation.succeed(
        "install -d /run/systemd/system/claude-runtime-deploy.service.d && "
        f"printf '[Service]\\nEnvironment=CLAUDE_RUNTIME_DEPLOY_REMOTE=file://%s\\n' {seed} > "
        "/run/systemd/system/claude-runtime-deploy.service.d/99-local-remote.conf && "
        "systemctl daemon-reload")
    workstation.execute("systemctl reset-failed claude-runtime-deploy.service")

    # ── Live state as Claude Code keeps it: a hand-added server and a hand-set env key ──
    github_live = json.loads(json.dumps(GITHUB))
    github_live["env"]["GITHUB_TOKEN"] = "live-only"
    live_doc = {"numStartups": 7, "projects": {"/home/jonathan": {}},
                "mcpServers": {"github": github_live, "scratch": SCRATCH}}
    as_jonathan("mkdir -p ~/.claude && touch ~/.claude/.projection-enabled")
    as_jonathan(f"cat > {live} <<'EOF'\n{json.dumps(live_doc, indent=2)}\nEOF")
    as_jonathan(f"chmod 640 {live}")

    # ── A broker merged upstream goes live on the next tick ──
    publish(json.dumps({"github": GITHUB, "agent_e2e_broker": BROKER}, indent=2), "add broker")
    assert tick() == "success", workstation.succeed(
        "journalctl -u claude-mcp-import.service --no-pager | tail -20")
    got = read_live()
    assert got["mcpServers"]["agent_e2e_broker"] == BROKER, got
    assert got["mcpServers"]["scratch"] == SCRATCH, got
    assert got["mcpServers"]["github"]["env"] == {"GITHUB_TOKEN": "live-only"}, got
    assert got["numStartups"] == 7 and got["projects"] == {"/home/jonathan": {}}, got
    owner = workstation.succeed(f"stat -c '%U:%G %a' {live}").strip()
    assert owner == "jonathan:users 640", owner
    workstation.fail(f"test -e {live}.lock")
    workstation.fail(f"test -e {record}")

    # ── An unusable served file fails loudly and leaves the live one alone ──
    before = workstation.succeed(f"sha256sum {live}").split()[0]
    publish("{ truncated", "unparseable")
    assert tick() == "exit-code"
    assert workstation.succeed(f"sha256sum {live}").split()[0] == before
    workstation.wait_for_file(record)
    rec = json.loads(workstation.succeed(f"cat {record}"))
    assert rec["unit"] == "claude-mcp-import.service", rec
    log = workstation.succeed("journalctl -u claude-mcp-import.service --no-pager")
    assert "is not valid JSON" in log, log

    # ── Repaired upstream: the next tick succeeds and clears the record ──
    repaired = {"type": "stdio", "command": "jobs-broker", "args": [], "env": {}}
    publish(json.dumps({"github": GITHUB, "agent_e2e_broker": BROKER,
                        "jobs_broker": repaired}, indent=2), "repair")
    assert tick() == "success"
    workstation.fail(f"test -e {record}")
    assert read_live()["mcpServers"]["jobs_broker"] == repaired
  '';
}
