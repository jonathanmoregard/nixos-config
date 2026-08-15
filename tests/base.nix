# vm-base: boot + HM activation smoke test.
#
# Asserts the absolute minimum every other lane inherits:
#   - multi-user.target reached
#   - home-manager activation completed for jonathan
#   - systemd --user (via linger) reached default.target for jonathan
#   - X server up (autoLogin path; catches LightDM regressions in
#     the lightest lane before they trip the heavier ones)
#   - kindle udev rule file present with the expected unset clauses
#     (vm-base-only by design: this is the lane that imports the full
#     dellan host config via mkTest, and we only need to verify the
#     payload once per build — mkMinimalTest / mkFeatureTest lanes
#     don't include kindle.nix)
#
# Run: nix build .#checks.x86_64-linux.vm-base -L
{ pkgs, inputs }:
(import ./lib/common.nix { inherit pkgs inputs; }).mkTest {
  name = "vm-base";
  testScript = ''
    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")
    # systemd --user for jonathan comes up via linger
    dellan.wait_for_unit("default.target", "jonathan")

    # home-manager-jonathan TimeoutStartSec floor.
    #
    # systemd's default TimeoutStartSec is 5min; jonathan's HM closure
    # activation on the 4 GiB / 2-core CI VM has repeatedly hit that
    # ceiling (PR #171 moved claude-desktop to environment.systemPackages
    # to fit; PR #175 vm-autodoro re-hit at 316s). modules/common.nix
    # pins the ceiling at 20min. This assertion guards against the
    # override silently dropping — either via a bad merge or a module
    # that overwrites the whole serviceConfig.
    #
    # Pattern mirrors tests/auto-deploy.nix (which grep-locks
    # nixos-deploy.service's TimeoutStartSec=60min against the same
    # incident class).
    dellan.succeed(
        "systemctl cat home-manager-jonathan.service "
        "| grep -q 'TimeoutStartSec=20min'"
    )
    # Belt-and-braces floor check: parse systemd's normalised value and
    # assert >= 15min (900s). Catches an override that keeps a
    # `TimeoutStartSec=` line but lowers it below the floor. systemctl
    # show renders "20min" for 1200s, "1h" for 3600s, "infinity" for
    # unlimited — accept any of those; reject anything below 15min.
    raw = dellan.succeed(
        "systemctl show -P TimeoutStartUSec home-manager-jonathan.service"
    ).strip()
    def _parse_systemd_time(s):
        if s == "infinity":
            return float("inf")
        import re
        units = {"h": 3600, "min": 60, "s": 1, "ms": 0.001, "us": 0.000001}
        total = 0.0
        for m in re.finditer(r"(\d+)(h|min|ms|us|s)", s):
            total += int(m.group(1)) * units[m.group(2)]
        return total
    seconds = _parse_systemd_time(raw)
    assert seconds >= 900, (
        f"home-manager-jonathan TimeoutStartSec={raw!r} ({seconds}s) is below "
        f"the 15min floor — the modules/common.nix override was dropped or "
        f"lowered. See PR #175 for the incident context."
    )
    # X session must come up too — every lane inherits autoLogin from
    # tests/lib/common.nix, so a LightDM regression should fail here
    # rather than masquerade as a kitty/desktop-lane failure later.
    dellan.wait_for_x()

    # Crontab source includes the bare-repo main-fetch line so worktrees
    # branched off ~/Repos/nixos-config/main don't start behind origin/main.
    # Assert on the home.file source rather than `crontab -l`: the live
    # crontab is installed by an activation hook whose timing relative to
    # /run/wrappers/bin/crontab in this VM image isn't load-bearing for
    # production (real hardware activates after setuid-wrappers).
    crontab_src = dellan.succeed(
        "cat /home/jonathan/.config/crontab"
    )
    # Must fast-forward THROUGH the main worktree. The old
    # `fetch origin main:main` against the bare repo failed every run
    # ("refusing to fetch into branch 'main' checked out at ...") and left
    # local main 99 files behind, so new worktrees started stale.
    assert (
        "git -C /home/jonathan/Repos/nixos-config-worktrees/main pull --ff-only origin main"
        in crontab_src
    ), f"nixos-config main-sync line missing from crontab source:\n{crontab_src}"
    # Comments in this crontab quote the broken form on purpose, so
    # only the executable half of each non-comment line counts. Split on
    # `#` after stripping so inline trailing comments are dropped too
    # (a future edit like `KEY=val # fetch origin main:main` should not
    # spuriously fail this assertion).
    def _cron_command(line):
        s = line.strip()
        if not s or s.startswith("#"):
            return ""
        return s.split("#", 1)[0]

    active_commands = [_cron_command(l) for l in crontab_src.splitlines()]
    assert not any("fetch origin main:main" in c for c in active_commands), (
        "the bare-repo fetch form cannot move a ref a worktree has checked out; "
        f"it must not come back as a live entry:\n{crontab_src}"
    )

    # The research-agent MCP server runs straight out of ~/Repos/research-agent
    # (`uv run --project`), and the research microvm bind-mounts that same
    # directory read-only at /workspace. An unpulled merge therefore means
    # every freshly spawned server AND every jailed agent runs stale code.
    # 2026-07-29..31: a merged model-fallback fix sat unpulled for three days
    # while every research call failed 429 — the processes churned constantly,
    # the checkout did not. --ff-only so a dirty or diverged tree fails loudly
    # in the log rather than fabricating a merge commit.
    assert (
        "git -C /home/jonathan/Repos/research-agent pull --ff-only"
        in crontab_src
    ), f"research-agent auto-pull line missing from crontab source:\n{crontab_src}"

    # RSI daily-reviewer cron. Live again as of 2026-08-03 after the
    # 2026-08-02 usage-cap disable, but the on/off decision no longer
    # lives in this file: the wrapper reads components.daily_review from
    # ~/.claude/recursive-self-improvement/config/config.json and exits
    # before starting a model unless it is exactly true. A live entry is
    # therefore not the same claim it used to be — the cost gate is the
    # JSON key, asserted behaviourally below.
    #
    # The history this still guards: the plugin's install.sh installs the
    # entry via `crontab -e`, which loses on every rebuild and every
    # Monday backup-crontab.sh run — that is why review-agent.log went
    # silent 2026-04-17 and stayed silent for four months.
    # home/jonathan-linux.nix is the only durable install path on dellan.
    assert any(
        "rsi-daily-review" in c for c in active_commands
    ), f"RSI daily-reviewer cron entry missing from crontab source:\n{crontab_src}"
    assert (
        "# recursive-self-improvement-analysis" in crontab_src
    ), f"the RSI cron line should keep its tag comment (install.sh keys idempotency on it):\n{crontab_src}"

    # The gate itself, exercised rather than grepped. The VM has no
    # ~/.claude/recursive-self-improvement/config/config.json (that tree
    # is user runtime state, not flake content), which is precisely the
    # absent-config case: it must read as OFF and cost nothing. Then with
    # the switch on, the wrapper must get past the gate and fail on one
    # of its later preflight checks instead — which one depends on what
    # the VM happens to have (claude resolves on PATH here, the prompt
    # file does not), so assert on leaving the gate rather than on the
    # specific downstream complaint.
    rsi_bin = dellan.succeed(
        "grep -o '/nix/store/[^ ]*/bin/rsi-daily-review' /home/jonathan/.config/crontab | head -1"
    ).strip()
    rsi_cfg_dir = "/home/jonathan/.claude/recursive-self-improvement/config"

    def run_rsi(expect_ok=True):
        cmd = f"su - jonathan -c {rsi_bin} 2>&1"
        return dellan.succeed(cmd) if expect_ok else dellan.fail(cmd)

    def set_daily_review(value):
        dellan.succeed(f"mkdir -p {rsi_cfg_dir}")
        dellan.succeed(
            "echo '{\"components\": {\"daily_review\": %s}}' > %s/config.json"
            % (value, rsi_cfg_dir)
        )
        dellan.succeed(
            "chown -R jonathan:users /home/jonathan/.claude/recursive-self-improvement"
        )

    off_absent = run_rsi()
    assert "skipping (no model call)" in off_absent, (
        f"absent config must gate the run off:\n{off_absent}"
    )
    set_daily_review("false")
    off_explicit = run_rsi()
    assert "skipping (no model call)" in off_explicit, (
        f"daily_review=false must gate the run off:\n{off_explicit}"
    )
    set_daily_review("true")
    on = run_rsi(expect_ok=False)
    assert "skipping (no model call)" not in on, (
        f"daily_review=true must get past the component gate:\n{on}"
    )
    assert "rsi-daily-review:" in on, (
        f"daily_review=true must reach the wrapper's own preflight:\n{on}"
    )
    dellan.succeed(f"rm -f {rsi_cfg_dir}/config.json")
    # Guard against reintroducing the dead-grant pattern: path-scoped
    # Write(...) grants passed via --allowedTools never register in
    # headless mode, and ~/.claude is behind Claude Code's built-in
    # sensitive-path gate which --print short-circuits into a deny
    # (both probed 2026-08-01). Any --allowedTools Write/Bash grant in
    # a cron line is therefore a silent no-op that misleads readers —
    # headless writers must go through a trusted sink instead (see
    # rsiProposalSink in home/jonathan-linux.nix). Also refuse the
    # opposite over-correction: permission-bypass flags on a cron
    # agent that reads untrusted transcript content.
    # Comment lines are exempt so prose ABOUT the pattern can't trip it.
    for cron_line in crontab_src.splitlines():
        cron_line = cron_line.strip()
        if not cron_line or cron_line.startswith("#"):
            continue
        assert (
            "--dangerously-skip-permissions" not in cron_line
        ), f"cron line bypasses permissions: {cron_line}"
        assert (
            "--permission-mode" not in cron_line
        ), f"cron line overrides permission mode: {cron_line}"
        if "--allowedTools" in cron_line:
            assert (
                "Write(" not in cron_line and "Bash(" not in cron_line
            ), f"cron line grants Write/Bash via --allowedTools (dead grant headless): {cron_line}"

    # Permission-ledger nightly evaluator. Shipped 2026-08-01 by a
    # separate session; its installer wrote only the LIVE crontab, which
    # the installCrontab activation hook overwrites from
    # home/jonathan-linux.nix on every rebuild. Without a declarative
    # copy, the first deploy after install silently kills the evaluator
    # — same failure shape as the RSI 2026-04-17 outage above.
    assert (
        "# permission-ledger-evaluate" in crontab_src
    ), f"permission-ledger cron entry missing from crontab source:\n{crontab_src}"
    assert (
        "permission-ledger/run-evaluate.sh" in crontab_src
    ), f"permission-ledger run-evaluate.sh reference missing from crontab source:\n{crontab_src}"

    # repo-autosync entries — third instance of the same trap. The
    # ~/.claude sync was installed with `crontab -` on 2026-08-08 and would
    # have survived exactly until the next rebuild, like the RSI reviewer
    # (four months dead) and the permission-ledger evaluator above.
    assert (
        "/home/jonathan/.claude/sync-agent.sh" in crontab_src
    ), f"~/.claude repo-autosync cron entry missing from crontab source:\n{crontab_src}"

    # superpowers is a PUBLIC fork of obra/superpowers and gitignores
    # sync-agent.sh so local automation cannot leak upstream. The in-repo
    # path therefore does not exist: pointing cron at it logged
    # `No such file or directory` on every run and synced nothing. It must
    # be driven through the canonical script via the SYNC_REPO override.
    assert (
        "SYNC_REPO=/home/jonathan/Repos/superpowers" in crontab_src
    ), f"superpowers autosync must run via the SYNC_REPO override:\n{crontab_src}"
    assert not any(
        "/home/jonathan/Repos/superpowers/sync-agent.sh" in c
        for c in [_cron_command(l) for l in crontab_src.splitlines()]
    ), (
        "superpowers gitignores sync-agent.sh (public fork), so this path "
        f"cannot exist; it must not come back as a live entry:\n{crontab_src}"
    )

    # modules/nixos/kindle.nix installs a udev rule that stops
    # gvfs-mtp-volume-monitor from claiming the kindle USB interface
    # (calibre needs libusb). Rule clears ID_MTP_DEVICE so
    # 69-libmtp.rules:10's early-exit symlink branch can't fire, but
    # leaves ID_MEDIA_PLAYER alone so 70-uaccess.rules:70 still grants
    # the user ACL on the /dev/bus/usb/N/M node (cleared by PR #108,
    # restored here). The VM can't model real USB so we only assert
    # the rule file is on disk with the right clauses — runtime
    # behaviour is verified on dellan by replugging the kindle.
    kindle_rule = dellan.succeed("cat /etc/udev/rules.d/60-kindle.rules")
    assert 'ATTR{idVendor}=="1949"' in kindle_rule, \
        f"kindle rule missing vendor match:\n{kindle_rule}"
    assert 'ATTR{idProduct}=="9981"' in kindle_rule, \
        f"kindle rule missing product (paperwhite) match:\n{kindle_rule}"
    assert 'ENV{ID_MTP_DEVICE}=""' in kindle_rule, \
        f"kindle rule missing ID_MTP_DEVICE unset:\n{kindle_rule}"
    # Regression guard for PR #108 → PR #109: must NOT clear
    # ID_MEDIA_PLAYER (breaks 70-uaccess.rules:70 user-ACL grant).
    # Substring match is safe here because writeTextFile only writes
    # the `text` field — Nix-source comments don't leak into the
    # deployed rule file. If a future edit adds rule-file comments via
    # writeTextFile body, tighten this to a regex/word-boundary check.
    assert 'ENV{ID_MEDIA_PLAYER}=""' not in kindle_rule, \
        f"kindle rule clears ID_MEDIA_PLAYER — breaks uaccess; see PR #108 regression:\n{kindle_rule}"

    # claude-agent-N users (modules/nixos/claude-agent-users.nix) must be
    # hidden from the LightDM greeter. slick-greeter builds its user list
    # from AccountsService, which drops accounts whose SystemAccount
    # property is true — assert the property the greeter actually filters
    # on, not just the keyfile on disk.
    def system_account(user):
        path = dellan.succeed(
            "busctl call org.freedesktop.Accounts /org/freedesktop/Accounts"
            f" org.freedesktop.Accounts FindUserByName s {user}"
            " | awk '{print $2}'"
        ).strip().strip('"')
        return dellan.succeed(
            f"busctl get-property org.freedesktop.Accounts {path}"
            " org.freedesktop.Accounts.User SystemAccount"
        ).strip()

    # Enumerate agents from /etc/passwd rather than hardcoding the list:
    # the module scales with services.claudeAgentUsers.count, and a
    # hardcoded list would silently skip claude-agent-4+ if count grows.
    agents = dellan.succeed(
        "getent passwd | awk -F: '/^claude-agent-/{print $1}'"
    ).split()
    # Floor assumes dellan keeps services.claudeAgentUsers.count >= 3
    # (testScript can't read cfg.count); lower the floor if count drops.
    assert len(agents) >= 3, \
        f"expected >=3 claude-agent users, found {agents}"
    for agent in agents:
        prop = system_account(agent)
        assert prop == "b true", \
            f"{agent} visible in greeter user list (SystemAccount={prop!r})"
    # jonathan must stay visible — guard against over-hiding.
    jprop = system_account("jonathan")
    assert jprop == "b false", \
        f"jonathan hidden from greeter (SystemAccount={jprop!r})"

    # The drift-warning banner (home/jonathan.nix loginExtra) is gated to
    # interactive shells; it must NOT leak into a non-interactive
    # `su - -c '…'`, or it pollutes scripted output (it previously broke
    # the GEMINI_API_KEY_FILE assertion below, and would break any su -c
    # parse like the camera-watchdog checks).
    drift_leak = dellan.succeed("su - jonathan -c 'true'")
    assert "drift warning" not in drift_leak, (
        f"drift banner leaked into non-interactive login shell:\n{drift_leak}"
    )

    # home.sessionVariables.GEMINI_API_KEY_FILE must reach jonathan's
    # interactive shell — prose-decorate --audio and any future Gemini
    # tool reads this env var to find the agenix-decrypted key. `su -`
    # loads jonathan's login shell, which sources the HM-generated env
    # files; assert the value matches the agenix path the host wires up.
    gemini_var = dellan.succeed(
        "su - jonathan -c 'echo $GEMINI_API_KEY_FILE'"
    ).strip()
    assert gemini_var == "/run/agenix/gemini-api-key", (
        f"GEMINI_API_KEY_FILE in jonathan's login shell = {gemini_var!r}, "
        f"expected '/run/agenix/gemini-api-key'"
    )

    # ── Lakera tuned-project pointer (home/lakera.nix) ──
    # All three injection-scanner call sites must export
    # LAKERA_PROJECT_ID from the single source in home/lakera.nix, so
    # injection_scanner/lakera.py pins Lakera Guard to the tuned L3
    # project policy instead of the account default. Assert on the
    # rendered wrapper text: a call site that drops the import would
    # silently fall back to the default policy with zero runtime error.
    lakera_marker = "export LAKERA_PROJECT_ID=project-5833252261"
    for wrapper in ["research-agent-mcp", "futuresearch-gate-mcp"]:
        wrapper_txt = dellan.succeed(
            f"su - jonathan -c 'cat $(command -v {wrapper})'"
        )
        assert lakera_marker in wrapper_txt, (
            f"{wrapper} wrapper lost the LAKERA_PROJECT_ID export:\n{wrapper_txt}"
        )
    # claude-cl-sync-wrap is not on PATH — resolve the store script from
    # the user unit's ExecStart (same extraction pattern as the camera
    # watchdog above; ExecStartPre doesn't match /^ExecStart=/).
    cl_sync_script = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat claude-cl-sync.service' "
        "| awk -F= '/^ExecStart=/{print $2}' | tr -d '\"'"
    ).strip()
    cl_sync_txt = dellan.succeed(f"cat {cl_sync_script}")
    assert lakera_marker in cl_sync_txt, (
        f"claude-cl-sync-wrap lost the LAKERA_PROJECT_ID export:\n{cl_sync_txt}"
    )

    # ── IPU6 camera self-heal watchdog (modules/nixos/laptop.nix) ──
    # The real recovery can't be modelled in a VM (no OV02C10 sensor /
    # IVSC), so — like the kindle udev rule above — this asserts the
    # wiring is installed correctly and that the script's healthy/no-op
    # path runs cleanly under real systemd. The state machine itself is
    # covered exhaustively by the runtime-invocation suite; full sensor
    # recovery is verified on dellan after deploy.
    dellan.succeed(
        "systemctl cat ipu6-camera-watchdog.timer "
        "| grep -q 'OnUnitActiveSec=15s'"
    )
    # The relay must carry the syslog log-sink env: with the default
    # stdout sink, CamHAL lines reach journald in multi-minute buffered
    # bursts and watchdog detection latency degrades from ~15-30s to the
    # flush interval.
    dellan.succeed(
        "systemctl cat v4l2-relayd-ipu6.service | grep -q 'logSink=SYSLOG'"
    )
    cam_script = dellan.succeed(
        "systemctl cat ipu6-camera-watchdog.service "
        "| awk -F= '/^ExecStart=/{print $2}' | tr -d '\"'"
    ).strip()
    # Recovery must restart the relay by name, non-blocking, and key off
    # both wedge signals (a rename of any silently breaks self-heal).
    dellan.succeed(f"grep -q 'systemctl restart --no-block' {cam_script}")
    dellan.succeed(f"grep -q 'v4l2-relayd-ipu6.service' {cam_script}")
    dellan.succeed(f"grep -q 'waitFrame, time out happens' {cam_script}")
    dellan.succeed(f"grep -q 'Scheduled restart job' {cam_script}")
    # Hard regression guard: the watchdog must NEVER touch the PCI bus.
    # Unbind/rebind of intel-ipu6 corrupts IVSC/CSE state and turns a
    # soft wedge into a reboot-only hard wedge (learned empirically).
    dellan.fail(f"grep -q 'unbind' {cam_script}")
    dellan.fail(f"grep -q 'intel-ipu6' {cam_script}")
    # Give-up latch + notify flag — regression guard against restart-
    # forever (same failure class as the microvm watchdog incident).
    dellan.succeed(f"grep -q 'restart-burst-count' {cam_script}")
    dellan.succeed(f"grep -q 'GIVING UP' {cam_script}")
    dellan.succeed(f"grep -q '/run/ipu6-camera-notify/wedged' {cam_script}")
    dellan.succeed("test -f /etc/systemd/user/ipu6-camera-watchdog-notify.path")
    dellan.succeed(
        "test -f /etc/systemd/user/ipu6-camera-watchdog-notify.service"
    )
    cam_notify_perms = dellan.succeed(
        "stat -c '%a %U' /run/ipu6-camera-notify"
    ).strip()
    assert cam_notify_perms == "755 root", (
        f"camera notify flag dir perms expected '755 root', got {cam_notify_perms!r}"
    )
    # No camera in the VM: the relay emits no waitFrame (quiet path) or
    # crash-loops without a sensor (thrash path → a harmless --no-block
    # restart). Either way a run must exit 0, never 'failed'.
    dellan.succeed("systemctl start ipu6-camera-watchdog.service")
    rc = dellan.succeed(
        "systemctl is-failed ipu6-camera-watchdog.service || true"
    ).strip()
    assert rc != "failed", (
        f"camera watchdog must no-op cleanly with no camera; got is-failed={rc!r}"
    )
    # Corrupt state file MUST NOT brick the watchdog (read_int clamp);
    # mirrors the microvm watchdog's corruption guard.
    dellan.succeed(
        "mkdir -p /run/ipu6-camera-watchdog "
        "&& printf 'abc\\n0\\n5garbage' > /run/ipu6-camera-watchdog/restart-burst-count"
    )
    dellan.succeed("systemctl start ipu6-camera-watchdog.service")
    rc = dellan.succeed(
        "systemctl is-failed ipu6-camera-watchdog.service || true"
    ).strip()
    assert rc != "failed", (
        f"camera watchdog must survive corrupted state; got is-failed={rc!r}"
    )

    # sota-watch daily timer — durable schedule for the SOTA-watch runner.
    # The runner script lives in ~/Repos/sota-watch/runner/run-watch.sh
    # (a separate userspace repo NOT present in this VM), so the wrapper
    # must guard: missing runner → log "skipping" and exit 0. This lane
    # asserts (a) the timer unit is loaded + active for the user, and
    # (b) starting the service exits cleanly and the run log records the
    # skip — the behavioural guard-path signal.
    timers = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user list-timers --all'"
    )
    assert "sota-watch.timer" in timers, \
        f"sota-watch.timer missing from user timer list:\n{timers}"

    # Start the service synchronously and assert it did NOT fail. `start`
    # with a oneshot unit blocks until ExecStart returns; a non-zero exit
    # (guard bug) surfaces as a failed unit.
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user start sota-watch.service'"
    )
    state = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user is-failed sota-watch.service || true'"
    ).strip()
    assert state != "failed", \
        f"sota-watch.service is in failed state after guard-path run: {state!r}"

    run_log = dellan.succeed(
        "cat /home/jonathan/.local/share/sota-watch/run.log"
    )
    assert "skipping" in run_log, \
        f"guard-path 'skipping' marker missing from run.log:\n{run_log}"

    # Swap: zram must activate on boot. Without any swap, memory pressure
    # OOM-kills instead of paging (2026-07-31 incident: 6 chrome OOM-kills
    # in 10 min on the zero-swap host, visible desktop freeze).
    #
    # The /var/lib/swapfile entry is NOT asserted here — nixpkgs' qemu-vm
    # module force-sets swapDevices=[] via mkVMOverride (priority 10) so
    # file-swap can't be exercised in nixosTest. Prod dellan's declaration
    # (hosts/dellan/swap.nix, 16 GiB swapfile) is verified via
    # `nix eval .#nixosConfigurations.dellan.config.swapDevices` pre-push
    # and by /proc/swaps on the real host post-deploy.
    swaps = dellan.succeed("cat /proc/swaps")
    assert "/dev/zram" in swaps, \
        f"zram swap device missing from /proc/swaps:\n{swaps}"

    # notify-send must resolve on jonathan's PATH: the runner's Claude
    # allowlist includes Bash(notify-send*) for medium/high findings,
    # and that entry was dead (exit 127) until libnotify landed in
    # home.packages — this assertion keeps it from regressing.
    dellan.succeed(
        "su - jonathan -c 'command -v notify-send'"
    )

    # Negative control BEFORE the failure lane: a clean guard-path run
    # must NOT have tripped the OnFailure notify unit. Without this, the
    # failure lane's journal grep below could pass vacuously if OnFailure
    # were mis-wired to fire on every run.
    notify_log = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "journalctl --user -u sota-watch-failure-notify.service --no-pager' "
        "|| true"
    )
    assert "SOTA-watch runner failed" not in notify_log, (
        "notify marker present after a SUCCESSFUL guard-path run — "
        f"OnFailure is mis-wired:\n{notify_log}"
    )

    # sota-watch OnFailure chain — a failing runner must trigger the
    # sota-watch-failure-notify user unit (the 2026-07 incident: expired
    # OAuth made the runner exit 1 daily for 11 days with zero signal).
    # Plant a fake runner that exits 1, start the service (expected to
    # fail), and assert the notify unit's guaranteed journal marker.
    # The desktop notify-send itself is best-effort (headless VM has no
    # notification daemon) — the marker line is the testable contract.
    # Created as ROOT with absolute paths: /home/jonathan/Repos is
    # pre-created root-owned in this VM by the microvm share plumbing,
    # so jonathan cannot mkdir under it (verified via driverInteractive:
    # "mkdir: cannot create directory ... Permission denied"). A root
    # 0755 file is still executable by the service user, which is all
    # the wrapper's `[ ! -x "$RUNNER" ]` guard needs.
    dellan.succeed(
        "mkdir -p /home/jonathan/Repos/sota-watch/runner && "
        "printf '#!/bin/sh\\nexit 1\\n' > /home/jonathan/Repos/sota-watch/runner/run-watch.sh && "
        "chmod 755 /home/jonathan/Repos/sota-watch/runner/run-watch.sh"
    )
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user start sota-watch.service; true'"
    )
    state = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user is-failed sota-watch.service || true'"
    ).strip()
    assert state == "failed", (
        "fake failing runner should leave sota-watch.service failed; "
        f"got is-failed={state!r}"
    )
    # OnFailure dispatch is asynchronous; poll the notify unit's journal
    # for the marker instead of asserting instantly.
    dellan.wait_until_succeeds(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "journalctl --user -u sota-watch-failure-notify.service --no-pager' "
        "| grep -q 'SOTA-watch runner failed'",
        timeout=60,
    )
    # Leave the VM state clean for any later lane: drop the fake runner
    # (as root — jonathan can't write under /home/jonathan/Repos here)
    # and clear the deliberately-failed unit.
    dellan.succeed("rm -rf /home/jonathan/Repos/sota-watch")
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user reset-failed sota-watch.service'"
    )

    # claude-idle-handoff — proactive mission.md writer + opus-5 autofork
    # for idle Claude Code sessions. Declared in home/claude-services.nix
    # after four months of the shipped-imperative footgun (RSI reviewer)
    # — same failure shape: units under ~/.config/systemd/user/ evaporate
    # on a fresh host. Unit + timer only; the SCRIPT
    # (~/.claude/scripts/idle-handoff.sh) is deliberately NOT nix-managed
    # because it iterates hot and lives in the ~/.claude git repo.
    #
    # This lane cannot run the real script — it lives outside the VM
    # closure — so we assert (a) the timer is loaded with the exact
    # cadence + jitter the design specifies, (b) the service is loaded
    # with the exact ExecStart the timer will call, and (c) the
    # resource-shape flags a stray tick can rely on
    # (Nice=15 / IOSchedulingClass=idle / TimeoutStartSec=180). A
    # rebuild that silently drops any of these puts the schedule back
    # in the same 5-min stampede window that motivated the caps.
    timers = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user list-timers --all'"
    )
    assert "claude-idle-handoff.timer" in timers, (
        "claude-idle-handoff.timer missing from user timer list:\n"
        f"{timers}"
    )
    handoff_timer = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat claude-idle-handoff.timer'"
    )
    for marker in [
        "OnBootSec=5min",
        "OnUnitActiveSec=5min",
        "AccuracySec=30s",
        "Unit=claude-idle-handoff.service",
    ]:
        assert marker in handoff_timer, (
            f"claude-idle-handoff.timer lost '{marker}':\n{handoff_timer}"
        )
    handoff_service = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat claude-idle-handoff.service'"
    )
    for marker in [
        "Type=oneshot",
        "ExecStart=%h/.claude/scripts/idle-handoff.sh",
        "Nice=15",
        "IOSchedulingClass=idle",
        "TimeoutStartSec=",
    ]:
        assert marker in handoff_service, (
            f"claude-idle-handoff.service lost '{marker}':\n{handoff_service}"
        )

    # sota-watch-refresh-roster — parallel unit + timer that refreshes
    # the AI power-users roster from the source Google Sheet ahead of
    # the research runner. Same guard-path shape as sota-watch: missing
    # refresh-roster.sh must produce a "skipping" log and exit 0 so a
    # fresh checkout or a VM without the userspace repo does not turn
    # the unit red. Same OnFailure notifier is reused; the failure lane
    # is exercised once (above) for the main service — asserting again
    # for the refresh unit would only test systemd's OnFailure wiring
    # a second time, so we cover only the loaded-and-guard-clean path
    # here to keep the lane fast.
    timers = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user list-timers --all'"
    )
    assert "sota-watch-refresh-roster.timer" in timers, (
        "sota-watch-refresh-roster.timer missing from user timer list:\n"
        f"{timers}"
    )
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user start sota-watch-refresh-roster.service'"
    )
    refresh_state = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user is-failed sota-watch-refresh-roster.service "
        "|| true'"
    ).strip()
    assert refresh_state != "failed", (
        "sota-watch-refresh-roster.service failed on guard-path run: "
        f"{refresh_state!r}"
    )
    refresh_log = dellan.succeed(
        "cat /home/jonathan/.local/share/sota-watch/refresh-roster.log"
    )
    assert "skipping" in refresh_log, (
        "guard-path 'skipping' marker missing from refresh-roster.log:\n"
        f"{refresh_log}"
    )

    # ── virtualisation-desktop (modules/nixos/virtualisation-desktop.nix) ──
    # Full libvirt/QEMU stack for desktop-grade guest VMs (Windows,
    # other-distro onboarding tests). Runtime cannot be exercised in
    # nixosTest — the test VM has no nested-KVM and libvirtd's default
    # network needs iptables/NAT scaffolding the framework doesn't
    # model — so we assert the wiring: unit loaded, jonathan in the
    # groups needed to drive libvirt without sudo, and the `win-vm`
    # wrapper resolves on PATH. Runtime boot of Windows itself is
    # verified on real dellan post-deploy via `win-vm fetch-iso <url>`
    # + `win-vm create` + `win-vm view`.
    dellan.succeed("systemctl cat libvirtd.service >/dev/null")
    # jonathan must be in libvirtd + kvm — without these the wrapper's
    # `require_group` guard fails and every virsh call needs sudo.
    groups = dellan.succeed("id -nG jonathan").split()
    for g in ["libvirtd", "kvm"]:
        assert g in groups, \
            f"jonathan missing from '{g}' group; libvirt access broken. groups={groups}"
    # win-vm on PATH — the CLI itself. Resolves at HM login shell
    # (system-wide package), so plain `command -v` under su - is enough.
    dellan.succeed("su - jonathan -c 'command -v win-vm'")
    # swtpm on PATH — Win11 install requirement for the TPM 2.0 device.
    # OVMF's presence is implicitly asserted by successful eval of
    # virtualisation.libvirtd.qemu.ovmf.packages, so we don't check
    # its firmware descriptor path (which drifts across nixpkgs).
    dellan.succeed("command -v swtpm")
    # /var/lib/libvirt/images must exist with group=libvirtd so
    # `win-vm fetch-iso` can drop ISOs in without sudo.
    img_perms = dellan.succeed("stat -c '%a %U %G' /var/lib/libvirt/images").strip()
    assert img_perms == "770 root libvirtd", (
        f"/var/lib/libvirt/images perms expected '770 root libvirtd', got {img_perms!r}"
    )

    # win-vm wrapper — runtime invocation of the case-dispatch layer +
    # adversarial argument handling. Skill mandates this for any module
    # shipping writeShellApplication: eval + PATH check don't prove the
    # script's error paths surface cleanly. The libvirt-touching
    # subcommands (create, view, start) can't run here — the CI VM
    # cannot nest KVM to boot a Windows guest — but the guard rails
    # around them still must.
    #
    # help: prints usage + exits 0. `2>&1` because the wrapper writes
    # usage to stderr (writeShellApplication convention).
    help_out = dellan.succeed("su - jonathan -c 'win-vm help 2>&1'")
    for marker in ["fetch-iso", "create", "view", "microsoft.com/software-download/windows11"]:
        assert marker in help_out, f"win-vm help lost '{marker}':\n{help_out}"
    # unknown subcommand: usage to stderr + non-zero exit.
    bogus = dellan.fail("su - jonathan -c 'win-vm nope-not-a-subcommand 2>&1'")
    assert "unknown subcommand" in bogus.lower() or "usage" in bogus.lower(), (
        f"win-vm bogus-subcommand should print usage/unknown message:\n{bogus}"
    )
    # fetch-iso without URL: dies with the MS download hint so a user
    # who forgets the arg gets a fix, not a hang.
    no_url = dellan.fail("su - jonathan -c 'win-vm fetch-iso 2>&1'")
    assert "microsoft.com" in no_url.lower() or "url" in no_url.lower(), (
        f"win-vm fetch-iso (no arg) should surface the MS URL hint:\n{no_url}"
    )
  '';
}
