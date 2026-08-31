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
let
  # TLS trust-store probe for aggregator-ingest.service.
  #
  # Installed as an ExecStart drop-in on the REAL unit, so it runs inside
  # that unit's own execution environment — [Service] Environment= merged by
  # systemd, nothing re-derived by hand. The claim under test is not "the
  # module mentions a variable" but "the process systemd starts can load a
  # non-empty set of CA certificates", which is precisely what was missing on
  # 2026-08-15 (unit had no SSL_CERT_FILE; uv's python-build-standalone
  # CPython falls back to cafile=/etc/ssl/cert.pem, absent on NixOS, and
  # capath=/etc/ssl/certs, which holds symlinks rather than an OpenSSL hashed
  # CA dir → zero trusted roots → every HTTPS source reporting
  # CERTIFICATE_VERIFY_FAILED "self-signed certificate in certificate chain").
  #
  # Note the VM's own pkgs.python3 CANNOT reproduce that fallback: it is
  # compiled with cafile=/etc/ssl/certs/ca-certificates.crt, which NixOS does
  # provide, so `ssl.create_default_context()` would hold 172 CAs here even
  # with the fix reverted. That is why the probe reads the environment
  # variables explicitly and loads the file they name, instead of asserting
  # on the default context — the latter would be green on a broken unit.
  #
  # Kept in a writeText rather than inlined via `python3 -c`: python is
  # indentation-sensitive and a multi-line block fights the surrounding `''`
  # indent-strip (same trap documented in tests/kitty.nix).
  aggregatorCaProbePy = pkgs.writeText "vm-base-aggregator-ca-probe.py" ''
    import os
    import ssl
    import sys

    failures = []
    paths = {}

    for var in ("SSL_CERT_FILE", "NIX_SSL_CERT_FILE"):
        value = os.environ.get(var, "")
        print("[ca-probe] " + var + "=" + (value or "<unset>"))
        if not value:
            failures.append(
                var + " is not set in aggregator-ingest.service's environment"
            )
            continue
        paths[var] = value
        if not os.path.isfile(value):
            failures.append(var + "=" + value + " does not exist in the unit's view")

    # Both spellings must name the same bundle. A unit where they disagree is
    # a unit where half the process tree (openssl consumers) trusts a
    # different set of roots than the other half (nixpkgs cacert wrappers).
    if len(paths) == 2 and paths["SSL_CERT_FILE"] != paths["NIX_SSL_CERT_FILE"]:
        failures.append(
            "SSL_CERT_FILE and NIX_SSL_CERT_FILE name different bundles: "
            + paths["SSL_CERT_FILE"] + " vs " + paths["NIX_SSL_CERT_FILE"]
        )

    # The behavioural half: OpenSSL must actually parse the named file into
    # CA certificates. A path that exists but is empty, truncated, or a
    # non-PEM blob loads zero roots and fails exactly like no path at all.
    cafile = paths.get("SSL_CERT_FILE")
    if cafile and os.path.isfile(cafile):
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        ctx.load_verify_locations(cafile=cafile)
        loaded = ctx.cert_store_stats()["x509_ca"]
        print("[ca-probe] x509_ca loaded from " + cafile + ": " + str(loaded))
        if loaded < 1:
            failures.append(
                cafile + " parsed into " + str(loaded) + " CA certificates"
            )

    for line in failures:
        print("[ca-probe] FAIL: " + line, file=sys.stderr)
    if failures:
        sys.exit(1)
    print("[ca-probe] OK")
  '';

  # Stand-in for a hand-edited ~/.claude/dcg.toml inside the VM.
  #
  # NOT a copy of the real file, and deliberately no longer claimed to be
  # one. The real file lives in the ~/.claude repo, which this flake does
  # not contain and cannot read at eval time — so a "copied verbatim"
  # claim is one this lane has no way to keep, and the previous revision
  # had already drifted (its reason string was a truncation of the real
  # one) with nothing able to notice. What this fixture is FOR is proving
  # the mkOutOfStoreSymlink live-edit property: written straight to the
  # link's target with no rebuild, it must take effect on the very next
  # dcg invocation.
  #
  # The one thing that IS verbatim-checkable is home/dcg-fallback.toml —
  # it is in this flake, so the lane byte-compares the seeded copy against
  # it below (`cmp`) instead of asserting a promise about a file it cannot
  # see.
  #
  # `curl -X DELETE` is the probe because dcg's built-in packs do NOT
  # block it (measured: with no user config it is allowed, while `rm -rf /`
  # is denied by core.filesystem). Attribution is then nailed down
  # positively — the deny document must carry this exact reason string and
  # must carry NO ruleId/packId, which is how dcg distinguishes an
  # `[overrides]` match from a pack match.
  dcgVmBlockReason = "vm-base fixture rule, planted at the link target with no rebuild";
  dcgVmConfig = pkgs.writeText "vm-base-dcg-config.toml" ''
    [general]
    verbose = false

    # Pinned off for the same reason home/dcg-fallback.toml pins it: this
    # file gets planted at the link target and then probed with a denying
    # payload, which is precisely the invocation that reaches
    # ensure_hook_registered(). Omitting the key takes dcg's upstream
    # default of TRUE, so the probe would run with self-heal ARMED and
    # rewrite ~/.claude/settings.json. The version of this fixture that
    # omitted it was harmless only because settings.json happened to have
    # been deleted a few lines earlier in the lane — an ordering accident,
    # asserted nowhere, that any later edit could undo. The arm that probes
    # this fixture now plants settings.json first and asserts it comes back
    # byte-identical, so dropping this line fails the lane instead.
    #
    # Not to be confused with dcgSelfHealConfig below, which omits the key
    # DELIBERATELY and must keep omitting it.
    self_heal_hook = false

    [packs]
    enabled = []
    disabled = []

    [overrides]
    allow = []
    block = [
        { pattern = "curl.*-X\\s+(DELETE|PUT|PATCH)", reason = "${dcgVmBlockReason}" },
    ]
  '';

  # Deliberately broken TOML, for the malformed-config arm. `x=` is the
  # minimal input that makes dcg's loader report `invalid`; the shape that
  # actually happens in practice is a git conflict marker landing in a
  # hand-edited file, which produces the same status.
  dcgBrokenConfig = pkgs.writeText "vm-base-dcg-broken.toml" ''
    x=
  '';

  # An OLDER revision of home/dcg-fallback.toml, for the refresh arm (i).
  #
  # A store path cannot change inside a running VM, so that arm stages the
  # "the seed moved" state from the other end: it moves the TARGET
  # backwards to a fallback that is no longer the current one. Built by
  # APPENDING to the tracked file rather than by copying its text, so it
  # cannot drift away from the real fallback, stays valid TOML, and keeps
  # every rule in it — including the `self_heal_hook = false` pin, which
  # matters because a denying probe runs while this is planted at the link
  # target.
  dcgStaleFallback = pkgs.runCommand "vm-base-dcg-stale-fallback.toml" { } ''
    cat ${../home/dcg-fallback.toml} > $out
    echo "# an older revision of home/dcg-fallback.toml, planted by vm-base" >> $out
  '';

  # POSITIVE CONTROL for the self-heal arm (h). Identical in shape to the
  # seeded fallback in the only respect that arm is about, except that it
  # DELIBERATELY OMITS `self_heal_hook` under [general] — so it takes
  # dcg's upstream default of true.
  #
  # DO NOT ADD `self_heal_hook` TO THIS FILE. Its whole job is to be the
  # config that lets dcg rewrite settings.json, which is what proves the
  # negative assertion in (h) is capable of failing. Set the key here and
  # both arms go green while asserting nothing.
  #
  # It is a separate fixture rather than a reuse of dcgVmConfig on
  # purpose: dcgVmConfig exists to prove the mkOutOfStoreSymlink live-edit
  # property, so a future edit could reasonably add the key to it, and the
  # control would then silently stop controlling.
  dcgSelfHealReason = "vm-base self-heal CONTROL fixture, self_heal_hook deliberately unset";
  dcgSelfHealConfig = pkgs.writeText "vm-base-dcg-selfheal-control.toml" ''
    [general]
    verbose = false

    [overrides]
    allow = []
    block = [
        { pattern = "curl.*-X\\s+(DELETE|PUT|PATCH)", reason = "${dcgSelfHealReason}" },
    ]
  '';

  # Stand-in for the operator's ~/.claude/settings.json inside the VM, for
  # the self-heal arm (h).
  #
  # THE PLANT IS LOAD-BEARING. dcg's self-heal only rewrites a
  # settings.json that ALREADY EXISTS — measured on v0.12.5 with
  # self_heal_hook left at its upstream default of true and the file
  # absent, a denying bare-`dcg` invocation creates nothing
  # (cli.rs:13602). The ~/.claude repo is not cloned in the VM, so an arm
  # that skipped installing this would hash a file that was never there
  # and pass on a host where dcg rewrites everything it can reach.
  #
  # Shaped like the real thing in the one way that decides the outcome:
  # dcg is registered INDIRECTLY, through bash-guard.py under a "Bash"
  # matcher. The entry ensure_hook_registered() hunts for — matcher
  # "Bash|PowerShell", command equal to the running binary's own absolute
  # path — is therefore absent, which is what arms the repair branch. An
  # entry it inserts lands at PreToolUse[0], ahead of this one.
  dcgVmSettings = pkgs.writeText "vm-base-claude-settings.json" ''
    {
      "hooks": {
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "/home/jonathan/.claude/hooks/bash-guard.py"
              }
            ]
          }
        ]
      }
    }
  '';
in
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

    # Only boolean true may open this gate. The shapes below are the ones a
    # human typo actually produces, and the JSON STRING "true" is the one
    # that used to get through: the gate compared the shell against a
    # `jq -r` render, and `-r` prints the string "true" as the bare text
    # `true` — byte-identical to how it prints boolean true. A quoted value
    # in config.json therefore started a headless Opus pass over the whole
    # transcript corpus, cost unmeasured. Verified with
    # `jq -rn '"true" // false'` → `true`. Expensive fails off: the gate now
    # tests identity against boolean true inside jq and reads its exit code,
    # so anything that is not literally `true` costs nothing.
    for bad_value, label in [
        ('"true"', 'JSON string "true" (the quoted-typo case)'),
        ("1", "number 1"),
        ("null", "explicit null"),
    ]:
        set_daily_review(bad_value)
        off_bad = run_rsi()
        assert "skipping (no model call)" in off_bad, (
            f"daily_review={bad_value} ({label}) is not boolean true and must "
            f"gate the run off — no model call:\n{off_bad}"
        )

    # Malformed JSON must fail shut too (jq exits 5; the gate must not read
    # that as consent). Written directly rather than via set_daily_review
    # because the point is that it never parses.
    dellan.succeed(
        "echo '{\"components\": {\"daily_review\": tru' > %s/config.json"
        % rsi_cfg_dir
    )
    off_malformed = run_rsi()
    assert "skipping (no model call)" in off_malformed, (
        f"malformed config JSON must gate the run off:\n{off_malformed}"
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

    # ── git hardening (home/jonathan.nix programs.git.settings) ──
    # These are integrity checks and default-deny transport rules: they
    # only bite when something is already wrong, so nothing else in the
    # suite notices if home-manager silently stops emitting them (an
    # upstream settings-vs-extraConfig rename would do exactly that).
    # Read the values back out of the generated config.
    expected_git_config = {
        "transfer.fsckObjects": "true",
        "fetch.fsckObjects": "true",
        "receive.fsckObjects": "true",
        "protocol.allow": "never",
        "protocol.https.allow": "always",
        "protocol.file.allow": "user",
        "protocol.ext.allow": "never",
        "core.fsmonitor": "false",
        "submodule.recurse": "false",
        "safe.bareRepository": "explicit",
        "user.useConfigOnly": "true",
        "gc.reflogExpireUnreachable": "90.days",
    }
    for key, want in expected_git_config.items():
        got = dellan.succeed(
            f"su - jonathan -c 'git config --global --get {key}'"
        ).strip()
        assert got == want, (
            f"git config --global {key} = {got!r}, expected {want!r} "
            f"(home/jonathan.nix programs.git.settings)"
        )

    # The global ignore file's negations only work if the `!` lines
    # follow the glob that catches them — `.env.*` swallows
    # .env.example otherwise. Ordering is invisible in the Nix source,
    # so prove it against a real repo rather than by reading the file.
    ignore_probe = dellan.succeed(
        "su - jonathan -c '"
        "d=$(mktemp -d); cd $d; git init -q .; "
        "for f in .env .env.local secrets.pem terraform.tfstate "
        ".env.example README.md; do "
        "git check-ignore -q $f && echo IGNORED $f || echo TRACKED $f; "
        "done'"
    )
    for want in [
        "IGNORED .env",
        "IGNORED .env.local",
        "IGNORED secrets.pem",
        "IGNORED terraform.tfstate",
        "TRACKED .env.example",
        "TRACKED README.md",
    ]:
        assert want in ignore_probe, (
            f"global gitignore probe missing {want!r}:\n{ignore_probe}"
        )

    # ── worktree flow under safe.bareRepository = explicit ──
    # The nixos-config change flow runs on a bare repo at ~/Repos/nixos-config
    # with linked worktrees. #184 set `safe.bareRepository = explicit` as
    # generic hardening and broke every `git -C <bare>` call — the worktree
    # flow itself, plus the daily nixos-worktree-sweep, which then failed
    # closed to zero deletions. The gate missed it because the only assertion
    # was the literal config VALUE (see the git config probe above), which
    # stays green whether or not the workflow it protects still works.
    #
    # Callers now anchor on the `main` linked worktree instead, which reaches
    # the same refs without asking git to discover a bare directory. This
    # probe asserts BOTH halves, because either alone is a false pass:
    #   1. the anchor pattern supports the full lifecycle, and
    #   2. discovery of a bare repo is genuinely still refused — otherwise
    #      the setting is not actually protecting anything.
    #
    # Asserted as BEHAVIOUR, not as config values, so any future change that
    # breaks the flow fails here whatever it is named.
    wt_probe = dellan.succeed(
        "su - jonathan -c '"
        "d=$(mktemp -d); cd $d; "
        "git init -q --bare bare.git; "
        "git clone -q bare.git seed >/dev/null 2>&1; cd seed; "
        "git commit -q --allow-empty -m seed; "
        "git push -q origin HEAD:refs/heads/main; cd $d; "
        # Bootstrap the anchor the one supported way: GIT_DIR named explicitly.
        "GIT_DIR=$d/bare.git git worktree add -q $d/main main >/dev/null 2>&1 "
        "&& echo BOOTSTRAP_OK || echo BOOTSTRAP_FAIL; "
        # The anchor pattern: every day-to-day operation goes through here.
        "git -C $d/main worktree list >/dev/null 2>&1 "
        "&& echo ANCHOR_LIST_OK || echo ANCHOR_LIST_FAIL; "
        "git -C $d/main worktree add -q $d/wt -b feat/probe main >/dev/null 2>&1 "
        "&& echo ANCHOR_ADD_OK || echo ANCHOR_ADD_FAIL; "
        "git -C $d/main rev-parse --verify -q refs/heads/feat/probe >/dev/null 2>&1 "
        "&& echo ANCHOR_REFS_OK || echo ANCHOR_REFS_FAIL; "
        "git -C $d/main worktree remove $d/wt >/dev/null 2>&1 "
        "&& echo ANCHOR_REMOVE_OK || echo ANCHOR_REMOVE_FAIL; "
        # And the protection itself must still bite.
        "git -C $d/bare.git worktree list >/dev/null 2>&1 "
        "&& echo BARE_DISCOVERY_ALLOWED || echo BARE_DISCOVERY_REFUSED'"
    )
    for want in [
        "BOOTSTRAP_OK",
        "ANCHOR_LIST_OK",
        "ANCHOR_ADD_OK",
        "ANCHOR_REFS_OK",
        "ANCHOR_REMOVE_OK",
        # If this flips to ALLOWED, safe.bareRepository stopped applying and
        # the hardening is silently inert.
        "BARE_DISCOVERY_REFUSED",
    ]:
        assert want in wt_probe, (
            f"nixos-config worktree flow assertion failed ({want} missing). "
            f"Anchor is ~/Repos/nixos-config-worktrees/main; see the anchor "
            f"rule in CLAUDE.md. Probe output:\n{wt_probe}"
        )

    # The ncfg helper is the ergonomic half of the same change — without it
    # the anchor path is long enough that muscle memory reaches for the bare
    # repo, which now fails.
    #
    # Asserts wiring, not execution: initContent lands in .zshrc, which only
    # an INTERACTIVE zsh sources, and `su - jonathan -c` is a login
    # non-interactive shell. Driving a real interactive zsh here would drag in
    # p10k for no extra coverage — the function body is a one-line `git -C`,
    # and the path it points at is already exercised by the anchor probe.
    ncfg_src = dellan.succeed("su - jonathan -c 'cat ~/.zshrc'")
    assert "ncfg()" in ncfg_src, (
        "ncfg shell function missing from ~/.zshrc "
        "(home/jonathan.nix programs.zsh.initContent)"
    )
    assert "Repos/nixos-config-worktrees/main" in ncfg_src, (
        "ncfg is present but does not anchor on the main worktree — it must "
        "not point at the bare repo, which safe.bareRepository now refuses"
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
    # Created as ROOT with absolute paths. This used to be forced:
    # /home/jonathan/Repos was pre-created root-owned by the microvm
    # share plumbing, so jonathan could not mkdir under it (verified via
    # driverInteractive: "mkdir: cannot create directory ... Permission
    # denied"). tests/lib/common.nix now creates that tree explicitly as
    # jonathan and keeps the microvms from booting, so the permission
    # wall is gone — but root still works, and a root 0755 file is still
    # executable by the service user, which is all the wrapper's
    # `[ ! -x "$RUNNER" ]` guard needs.
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

    # ── aggregator all-sources ingest (modules/nixos/aggregator-ingest-timer.nix) ──
    # One user timer walks all nine aggregator sources every 30 min. The
    # predecessor (aggregator-github-ingest) ran one source and had NO
    # failure reporting at all: a broken run reached the journal and
    # nowhere else. Both halves of the replacement are asserted here
    # behaviourally, because presence-only checks on this module would
    # pass with the notifier silently disabled — which is precisely the
    # state it exists to prevent.
    #
    # Since 2026-08-16 the CLI itself IS in the VM closure (the unit execs
    # a store path built by overlays/aggregator.nix, not a checkout), so
    # `--help` and the Presidio-path assertion below run the real binary.
    # A full ingest still cannot run here — no network, no agenix secret,
    # no ~/.claude/projects — so no run of the real command reaches exit 3
    # from inside the test. The exit-3 -> OnFailure
    # edge is therefore driven by overriding ONLY ExecStart via a drop-in
    # (the [Unit] section, and with it the OnFailure edge under test, stays
    # the production one), while the wrapper half is covered by invoking the
    # real generated script and by starting the real unit unmodified.
    agg_timers = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user list-timers --all'"
    )
    assert "aggregator-ingest.timer" in agg_timers, (
        f"aggregator-ingest.timer missing from user timer list:\n{agg_timers}"
    )
    # wantedBy = timers.target, proven by systemd rather than by a symlink
    # stat: enabled (the install symlink resolved) AND active (the user
    # manager actually armed it, so a tick will come).
    for prop, expected in [("is-enabled", "enabled"), ("is-active", "active")]:
        got = dellan.succeed(
            "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
            f"systemctl --user {prop} aggregator-ingest.timer'"
        ).strip()
        assert got == expected, (
            f"aggregator-ingest.timer {prop}={got!r}, expected {expected!r} "
            f"— the timer is not wanted by timers.target"
        )
    # The github-only predecessor must be gone, not merely shadowed: a
    # leftover unit file would keep ingesting one source on its own tick.
    dellan.fail("test -f /etc/systemd/user/aggregator-github-ingest.service")
    dellan.fail("test -f /etc/systemd/user/aggregator-github-ingest.timer")

    agg_unit = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat aggregator-ingest.service'"
    )
    # The OnFailure edge itself, and the timeout backstop that makes a
    # wedged nine-source run fail (Type=oneshot disables TimeoutStartSec by
    # default, which is how a hang becomes an unbounded "activating").
    assert "OnFailure=aggregator-ingest-failure-notify.service" in agg_unit, (
        f"aggregator-ingest.service lost its OnFailure edge:\n{agg_unit}"
    )
    assert "TimeoutStartSec=" in agg_unit, (
        f"aggregator-ingest.service lost its TimeoutStartSec backstop:\n{agg_unit}"
    )

    # AGGREGATOR_NOTIFY_COMMAND: present, NON-EMPTY, and executable. All
    # three matter. `Environment=AGGREGATOR_NOTIFY_COMMAND=` (the empty
    # spelling) and a mistyped program are the two shapes the aggregator
    # documents as historically silent-in-the-wrong-direction; a config
    # that produced either would let this unit run for months believing
    # notifications were on while they were off.
    import re as _re
    m = _re.search(r'Environment="AGGREGATOR_NOTIFY_COMMAND=([^"]*)"', agg_unit)
    assert m, (
        "aggregator-ingest.service does not set AGGREGATOR_NOTIFY_COMMAND, so "
        f"the in-process staleness notifier is not installed:\n{agg_unit}"
    )
    agg_notify_cmd = m.group(1).strip()
    assert agg_notify_cmd, (
        "AGGREGATOR_NOTIFY_COMMAND is set but blank — the aggregator treats "
        "that as a run error, not as 'off'"
    )
    dellan.succeed(f"test -x {agg_notify_cmd.split()[0]}")

    agg_exec = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat aggregator-ingest.service' "
        "| awk -F= '/^ExecStart=/{print $2}' | tr -d '\"'"
    ).strip()
    agg_script = dellan.succeed(f"cat {agg_exec}")
    # What it runs: every source through the one runner, not `ingest github`.
    assert "ingest --all" in agg_script, (
        f"aggregator wrapper no longer drives all sources:\n{agg_script}"
    )
    # ── The unit must run a DEPLOYED ARTIFACT, not a working tree ──
    #
    # Regression lock for the defect fixed on 2026-08-16. ExecStart had
    # been a store path the whole time, and the timer still ran whatever
    # was checked out in ~/Repos/aggregator, because the wrapper's last
    # line was `exec uv run --directory /home/jonathan/Repos/aggregator`.
    # Everything a reviewer would naturally glance at — the unit file, the
    # ExecStart= line, `systemctl cat` — looked correct. Four PRs went by.
    #
    # So the assertion is on the wrapper's TEXT, not on ExecStart: no path
    # under /home/ may appear in the program this unit runs, at all. The
    # aggregator keeps its state under ~/.local/share and reads sources
    # from ~/Dropbox etc, but it resolves those itself at runtime from
    # $HOME — none of it belongs in the wrapper, so a blanket ban here has
    # no legitimate casualty and no wording for a future edit to slip past.
    assert "/home/" not in agg_script, (
        "aggregator-ingest's wrapper references a home-directory path, so "
        "the unit is running (or reading) a developer working tree rather "
        "than a store path pinned in flake.lock. This is the exact defect "
        f"the 2026-08-16 packaging change closed:\n{agg_script}"
    )
    # `uv run` by name, separately: it is the specific mechanism that both
    # ran the tree AND wrote to it (venv resolve/sync, uv.lock) from an
    # unattended systemd unit. `uv` is no longer even in runtimeInputs.
    assert "uv run" not in agg_script, (
        f"aggregator wrapper must not shell out to `uv run`:\n{agg_script}"
    )
    # `exec`, so the CLI's exit status is the unit's exit status. Anything
    # that captures and re-raises the status by hand can zero it (PR #67),
    # and a zeroed 3 is a run that dropped data reported as success. The
    # exec'd program must be a store path — parsed out and probed below.
    agg_exec_lines = [
        ln.strip() for ln in agg_script.splitlines() if ln.strip().startswith("exec ")
    ]
    assert len(agg_exec_lines) == 1, (
        f"expected exactly one `exec` line in the wrapper:\n{agg_script}"
    )
    agg_cli = agg_exec_lines[0].split()[1].strip("'\"")
    assert agg_cli.startswith("/nix/store/"), (
        f"aggregator wrapper execs {agg_cli!r}, which is not a store path:\n{agg_script}"
    )
    assert agg_exec_lines[0].endswith("ingest --all"), (
        f"aggregator wrapper no longer execs the all-sources runner:\n{agg_script}"
    )

    # Same ban on the unit body — narrower wording because a future
    # ReadWritePaths=/home/... could be legitimate, whereas naming the
    # checkout never is.
    assert "Repos/aggregator" not in agg_unit, (
        f"aggregator-ingest.service still names the dev checkout:\n{agg_unit}"
    )

    # Behavioural half: the packaged CLI runs to completion in a machine
    # that has no aggregator checkout at all. A static path assertion
    # cannot tell a complete deployed artifact from a store path whose
    # dependencies live somewhere else.
    dellan.succeed("test ! -e /home/jonathan/Repos/aggregator")
    dellan.succeed(f"test -x {agg_cli}")
    agg_cli_out = dellan.succeed(f"su - jonathan -c '{agg_cli} --help' 2>&1")
    assert "ingest" in agg_cli_out, (
        f"packaged aggregator CLI did not print its usage:\n{agg_cli_out}"
    )

    # ── Presidio must be on the FULL path, not the regex fallback ──
    #
    # aggregator/core/scrub.py falls back to regex-only PII detection when
    # the spaCy model Presidio is configured for (en_core_web_lg) is not
    # installed. That fallback is silent in every way that would surface
    # it: the run exits 0, the row is still stamped with the
    # "presidio+gitleaks/v1" scrub fingerprint, and nothing rescrubs it.
    # Packaging the app is exactly the change that could drop the model —
    # it is not on PyPI and therefore not in uv.lock — so the assertion
    # lives here rather than in a comment. See overlays/aggregator.nix.
    #
    # The warning goes to stderr at import time, so `--help` above already
    # exercised it; assert on that output rather than paying a second
    # model load on a CI VM.
    assert "Presidio unavailable" not in agg_cli_out, (
        "the packaged aggregator degraded to regex-only PII scrubbing — "
        "en_core_web_lg is missing from the closure, and a degraded scrub "
        f"is indistinguishable from a healthy one downstream:\n{agg_cli_out}"
    )

    # The notifier must be reachable ONLY through OnFailure. `static` means
    # the unit has no [Install] section, so nothing can pull it in on its
    # own — the race-free half of the "does not fire spuriously" control
    # (the behavioural half is the exit-0 run below).
    agg_notify_enabled = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user is-enabled aggregator-ingest-failure-notify.service'"
    ).strip()
    assert agg_notify_enabled == "static", (
        "the failure notifier must be OnFailure-only (no [Install]); "
        f"is-enabled={agg_notify_enabled!r}"
    )

    # ── aggregator schema-skew detector (modules/nixos/aggregator-schema-health.nix) ──
    #
    # This unit exists because the ingest timer asserted above CANNOT detect
    # its own most damaging failure. On 2026-08-27 the aggregator's MCP reader
    # moved to cache schema 6 while the writer pinned in flake.lock stayed at
    # 5. migrate() ends by stamping PRAGMA user_version with the writer's own
    # constant, so every 30-minute tick re-stamped the cache back down to 5
    # and EXITED 0 doing it. OnFailure cannot see a successful run; the
    # in-process notifier had nothing to say. Recall was 100% dead for three
    # days and no channel on this host said a word.
    #
    # The assertions below are behavioural for the same reason the ingest
    # ones are: a presence-only check would pass against a detector that
    # silently reported everything as healthy, which is precisely the state
    # it exists to prevent. So the real generated script is RUN, against
    # stub probes that produce each verdict, and its routing is asserted.
    health_timers = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user list-timers --all'"
    )
    assert "aggregator-schema-health.timer" in health_timers, (
        f"aggregator-schema-health.timer missing from user timers:\n{health_timers}"
    )
    for prop, expected in [("is-enabled", "enabled"), ("is-active", "active")]:
        got = dellan.succeed(
            "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
            f"systemctl --user {prop} aggregator-schema-health.timer'"
        ).strip()
        assert got == expected, (
            f"aggregator-schema-health.timer {prop}={got!r}, expected "
            f"{expected!r} — the detector is not armed, so nothing is "
            "watching whether recall works"
        )

    health_unit = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat aggregator-schema-health.service'"
    )
    assert "OnFailure=aggregator-schema-health-failure-notify.service" in health_unit, (
        "the detector lost its own OnFailure edge, so a detector that dies "
        f"reports nothing — the failure this whole unit is about:\n{health_unit}"
    )
    assert "TimeoutStartSec=" in health_unit, (
        "Type=oneshot disables TimeoutStartSec by default, so without it a "
        "wedged check holds the unit 'activating' forever and every later "
        f"tick silently no-ops:\n{health_unit}"
    )
    health_notify_enabled = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user is-enabled aggregator-schema-health-failure-notify.service'"
    ).strip()
    assert health_notify_enabled == "static", (
        "the detector's failure notifier must be OnFailure-only (no "
        f"[Install]); is-enabled={health_notify_enabled!r}"
    )

    health_exec = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat aggregator-schema-health.service' "
        "| awk -F= '/^ExecStart=/{print $2}' | tr -d '\"'"
    ).strip()
    health_script = dellan.succeed(f"cat {health_exec}")

    # Same blanket ban the ingest wrapper carries, and for a sharper reason
    # here: this script's whole job is to compare a DEPLOYED writer against a
    # developer checkout, which makes a literal home path a tempting and
    # plausible edit. It resolves $HOME at runtime instead.
    assert "/home/" not in health_script, (
        "the schema-health script names a home-directory path; it must "
        f"resolve $HOME at runtime instead:\n{health_script}"
    )

    # ── The detector must never invoke the thing it is checking ──
    #
    # Regression lock, and the subtlest failure available here. The
    # aggregator CLI calls store.migrate() on every subcommand except
    # `embed`, and migrate() WRITES PRAGMA user_version. So a probe that
    # shelled out to `aggregator status` would re-stamp the cache at the
    # writer's old version — performing the exact damage it was asked to
    # report on, every hour, while looking like a health check. The probe
    # reads the cache read-only and reads two source files as text.
    for forbidden in ["aggregator status", "aggregator query", "aggregator ingest"]:
        assert forbidden not in health_script, (
            f"the schema-health script invokes `{forbidden}`, which calls "
            f"migrate() and re-stamps the cache it is measuring:\n{health_script}"
        )

    # ── Behavioural: drive the REAL script with stub probes ──
    #
    # The VM has no aggregator checkout (asserted above), so the real probe
    # cannot run here. What CAN be proven is the half that lives in this
    # repo: that the script routes each verdict to the right announcement,
    # that a healthy verdict is genuinely silent, and that a verdict it does
    # not recognise is announced rather than assumed benign.
    #
    # notify-send has no daemon to talk to in this VM, so it fails and the
    # script logs the fallback line. That is deliberate: the journal marker
    # is emitted FIRST and unconditionally, which is exactly why it — and not
    # the toast — is what a headless test asserts on.
    dellan.succeed("mkdir -p /home/jonathan/probe-stubs")
    for code, needle in [
        (0, None),
        (20, "AGGREGATOR RECALL IS DEAD"),
        (10, "will break on the next ingest tick"),
        (30, "UNVERIFIED"),
        # An exit code the script does not know about. A future probe state
        # must surface as noise, never as silence.
        (77, "unrecognised status 77"),
    ]:
        stub = f"/home/jonathan/probe-stubs/probe{code}.py"
        dellan.succeed(
            f"printf 'import sys\\nprint(\"stub verdict {code}\")\\n"
            f"sys.exit({code})\\n' > {stub}"
        )
        dellan.succeed(f"chown jonathan {stub}")
        # Clear the debounce stamp between cases: it is per-24h and would
        # otherwise suppress every case after the first, turning four
        # assertions into one.
        dellan.succeed(
            "rm -f /home/jonathan/.local/state/aggregator/schema-skew-notified"
        )
        out = dellan.succeed(
            "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
            f"AGGREGATOR_SCHEMA_PROBE={stub} {health_exec} 2>&1' || true"
        )
        if needle is None:
            assert out.strip() == "", (
                "the detector spoke on a HEALTHY verdict. Silence is its only "
                f"budget; spending it every hour is how it stops being read:\n{out}"
            )
        else:
            assert needle in out, (
                f"probe exit {code} did not produce its announcement "
                f"({needle!r}):\n{out}"
            )
            assert "stub verdict" in out, (
                f"the probe's own summary text was dropped from the "
                f"announcement, leaving a headline with no diagnosis:\n{out}"
            )

    # ── Silence must mean "verified", never "could not tell" ──
    #
    # The probe file absent is the state a tidying edit would most plausibly
    # turn into an early `exit 0`. It must announce AND exit non-zero, so the
    # OnFailure edge asserted above fires as a second backstop.
    dellan.succeed(
        "rm -f /home/jonathan/.local/state/aggregator/schema-skew-notified"
    )
    # `execute`, not `succeed`: a non-zero exit is the ASSERTION here, not a
    # test failure, and `succeed` would reject the very behaviour being
    # checked.
    missing_rc, missing_out = dellan.execute(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        f"AGGREGATOR_SCHEMA_PROBE=/nonexistent/probe.py {health_exec} 2>&1'"
    )
    assert "UNVERIFIED" in missing_out, (
        "a missing probe was not announced — a check that goes quiet when its "
        f"own machinery breaks reads as good news:\n{missing_out}"
    )
    assert missing_rc != 0, (
        "a missing probe must exit non-zero so the OnFailure edge fires as a "
        f"second backstop; got rc={missing_rc}:\n{missing_out}"
    )

    # ── The 24h debounce, and its recovery path ──
    #
    # Two halves. The debounce keeps a standing fault (this one is
    # persistent-until-a-human-acts) from becoming an hourly toast, because a
    # nagged operator mutes the channel. The recovery half is the one with no
    # precedent in this repo to copy: OnFailure notifiers never see the
    # healthy case, so they never clear their stamp. This unit runs on a
    # timer and does — without which a fault fixed and re-broken inside 24h
    # would be silently suppressed the second time, and the second time is
    # the one that proves the fix did not hold.
    stamp = "/home/jonathan/.local/state/aggregator/schema-skew-notified"
    dellan.succeed(f"rm -f {stamp}")
    dellan.succeed("mkdir -p /home/jonathan/.local/state/aggregator")
    dellan.succeed(f"touch {stamp} && chown jonathan {stamp}")
    healthy_stub = "/home/jonathan/probe-stubs/probe0.py"
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        f"AGGREGATOR_SCHEMA_PROBE={healthy_stub} {health_exec}'"
    )
    dellan.fail(f"test -f {stamp}")

    # ── aggregator embed worker (home/aggregator-embed.nix) ────────────────
    #
    # The embed half is imported from the aggregator's own tree rather than
    # declared in this repo, so upstream's `aggregator-embed-unit-hygiene`
    # check keeps guarding the unit that actually runs. What THIS repo
    # decides, and therefore what is asserted here, is the wiring: that the
    # worker is armed, that it can never download on a tick, that the seed
    # unit is human-triggered only, and that importing the upstream module
    # did not also resurrect its per-source ingest timers.
    assert "aggregator-embed.timer" in agg_timers, (
        f"aggregator-embed.timer missing from user timer list:\n{agg_timers}"
    )
    for prop, expected in [("is-enabled", "enabled"), ("is-active", "active")]:
        got = dellan.succeed(
            "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
            f"systemctl --user {prop} aggregator-embed.timer'"
        ).strip()
        assert got == expected, (
            f"aggregator-embed.timer {prop}={got!r}, expected {expected!r} — "
            f"the backfill would never tick"
        )

    # THE IMPORT MUST NOT BRING THE PER-SOURCE INGEST TIMERS BACK.
    # `services.aggregator.enable = true` switches on the whole upstream
    # module; home/aggregator-embed.nix turns `sources.*.enable` off because
    # aggregator-ingest.timer already walks every source through one runner.
    # If a future edit drops those two lines, this host gets a second and
    # third writer against the same cache.db doing a subset of the same
    # work — which is exactly the arrangement the unified runner replaced,
    # and it would look like nothing more than two extra timers in a list.
    #
    # ENUMERATED, NOT SPOT-CHECKED, and the difference is the whole point.
    # `sources.sessions.enable` and `sources.github.enable` BOTH DEFAULT TO
    # TRUE upstream, so the module arms every source it knows about unless
    # this repo names it and switches it off. A name-by-name check only ever
    # covers the sources that existed when it was written: an aggregator-src
    # bump that adds a third default-on source would sail straight past it
    # and land a second writer on cache.db, silently, on auto-deploy. So
    # assert the WHOLE SET and make a new name fail the lane until someone
    # dispositions it deliberately.
    #
    # `list-unit-files` rather than `list-timers`, because the upstream units
    # are `lib.mkIf`-gated: a disabled source has no unit FILE at all, and a
    # file that exists but was never started would not appear in list-timers.
    # It also spans both search paths — /etc/systemd/user for the NixOS-level
    # ingest timer, ~/.config/systemd/user for the home-manager embed timer.
    agg_timer_files = sorted(set(dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user list-unit-files --no-legend \"aggregator-*.timer\"' "
        "| awk '{print $1}'"
    ).split()))
    # `aggregator-schema-health.timer` is the third name, dispositioned
    # deliberately and on the opposite side of the test that this set exists to
    # apply. Everything above is about keeping a SECOND WRITER off cache.db.
    # The health timer never writes: it opens the cache `mode=ro` and reads two
    # source files as text, and it never invokes the aggregator CLI at all —
    # which matters because every subcommand but `embed` calls migrate(), and
    # migrate() stamps PRAGMA user_version. modules/nixos/aggregator-schema-health.nix
    # carries the reasoning; the assertions further up in this file exercise
    # the script and pin that it names no `aggregator status`.
    #
    # A FOURTH name still fails the lane, and should: the question to ask of it
    # is the same one, "does it write to cache.db", not "is it plausible".
    assert agg_timer_files == [
        "aggregator-embed.timer",
        "aggregator-ingest.timer",
        "aggregator-schema-health.timer",
    ], (
        "the set of aggregator timers on this host changed. Expected exactly "
        "the unified ingest runner, the embed worker, and the read-only "
        "schema-skew detector; got:\n"
        f"{agg_timer_files}\n"
        "A name MISSING here means a timer this host depends on stopped being "
        "installed. A NEW name is almost certainly an upstream per-source "
        "ingest timer whose `enable` defaults to true and which "
        "home/aggregator-embed.nix does not switch off — i.e. a second writer "
        "against the same cache.db, doing a subset of the work "
        "aggregator-ingest.timer already does. Disable it there, then add it "
        "to this list."
    )

    # AND ASK THE SAME QUESTION WITHOUT ASSUMING THE UNIT TYPE. A timer is not
    # the only thing an aggregator-src bump can add under
    # `services.aggregator.enable`: a service, path or socket unit carrying its
    # own [Install] WantedBy is pulled in by a target directly and would never
    # show up in a timer list at all. flake.nix records that this repo's CI is
    # the ONLY gate on such a bump — `flake = false` means upstream's own
    # checks never run here — so pin the general property instead of a
    # spelling: WHICH aggregator units are ARMED, i.e. carry a WantedBy some
    # target can follow. Everything else upstream ships (the two -seed and
    # -failure-notify services) is reachable only by hand or via OnFailure, and
    # that is the distinction worth defending.
    agg_all_units = sorted(set(dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user list-unit-files --no-legend \"aggregator-*\"' "
        "| awk '{print $1}'"
    ).split()))
    agg_armed = []
    for unit in agg_all_units:
        if "WantedBy=" in dellan.succeed(
            "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
            f"systemctl --user cat {unit}'"
        ):
            agg_armed.append(unit)
    # Three armed units now. The health timer is armed on purpose — a detector
    # that only runs when someone remembers to run it is not a detector — and
    # its two services are deliberately NOT here: the check service is started
    # by its timer and the failure-notify service is OnFailure-only, both
    # asserted `static` above. That asymmetry is the property worth defending,
    # and it is why this list is about WantedBy rather than about unit count.
    assert agg_armed == [
        "aggregator-embed.timer",
        "aggregator-ingest.timer",
        "aggregator-schema-health.timer",
    ], (
        "the set of ARMED aggregator units changed. Only the three timers may "
        f"carry an [Install] WantedBy; got {agg_armed} out of "
        f"{agg_all_units}.\n"
        "A newly armed unit is something an aggregator-src bump added that "
        "starts ITSELF. Check whether it writes to cache.db before doing "
        "anything else — if it does, switch it off in "
        "home/aggregator-embed.nix rather than widening this list."
    )

    agg_embed_unit = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat aggregator-embed.service'"
    )
    # OFFLINE ON EVERY TICK. The worker must fail loudly on absent weights
    # rather than reach the network: a timer that can download turns a
    # missing-model misconfiguration into a silent multi-GB fetch on a
    # laptop that may be tethered. `--seed-models` is the only online path.
    assert "HF_HUB_OFFLINE=1" in agg_embed_unit, (
        "aggregator-embed.service does not pin HF_HUB_OFFLINE=1, so a "
        f"scheduled tick could fetch model weights:\n{agg_embed_unit}"
    )
    assert "Repos/aggregator" not in agg_embed_unit, (
        f"aggregator-embed.service names the dev checkout:\n{agg_embed_unit}"
    )

    # THE ENV VAR IS THE WEAKEST HALF OF "OFFLINE", and asserting only it is
    # how this check quietly stops covering anything. HF_HUB_OFFLINE is a
    # REQUEST: a library that does not read it, or any subprocess spawned
    # along the way, still has the network. The load-bearing lines are the
    # seccomp address-family restriction — which makes an AF_INET socket()
    # fail outright — and the IP filter behind it.
    #
    # AND THIS REPO'S CI IS THE ONLY PLACE THAT CAN CATCH THEIR LOSS.
    # `aggregator-src` is a `flake = false` input, so upstream's own
    # `checks.<system>.aggregator-embed-unit-hygiene` never runs here. A rev
    # bump that dropped these directives would evaluate clean, build clean,
    # and auto-deploy to the laptop with the guarantee gone.
    for directive in [
        "TRANSFORMERS_OFFLINE=1",
        "RestrictAddressFamilies=AF_UNIX AF_NETLINK",
        "IPAddressDeny=any",
    ]:
        assert directive in agg_embed_unit, (
            f"aggregator-embed.service no longer carries {directive!r}, so the "
            "worker's offline guarantee rests on every library agreeing to "
            f"read an environment variable:\n{agg_embed_unit}"
        )

    # The one opt-in that lets a run fetch weights. It belongs to the seed
    # path and nowhere else; on the worker it would turn a 30-minute timer
    # into a downloader, which is the exact failure HF_HUB_OFFLINE=1 above is
    # there to prevent — so assert its ABSENCE rather than inferring it from
    # the presence of the others.
    assert "AGGREGATOR_ALLOW_MODEL_DOWNLOAD" not in agg_embed_unit, (
        "aggregator-embed.service carries AGGREGATOR_ALLOW_MODEL_DOWNLOAD — "
        "the scheduled worker is permitted to download model weights:\n"
        f"{agg_embed_unit}"
    )

    # THE POLITENESS DIRECTIVES ARE LOAD-BEARING, NOT COSMETIC. This worker is
    # a CPU-bound torch process with TimeoutStartSec=infinity, measured at
    # ~55 days of continuous work on the real corpus, running on an
    # interactive laptop. Nice=19 and IOSchedulingClass=idle are the whole
    # reason that is tolerable: they confine it to otherwise-idle capacity.
    # Drop them and the same unit becomes a month-long foreground CPU burn,
    # with no test going red and nothing else in this repo to notice — the
    # bump that removed them would evaluate clean and auto-deploy. Same
    # reasoning as the resource-flag assertions on claude-idle-handoff.
    for directive in ["Nice=19", "IOSchedulingClass=idle"]:
        assert directive in agg_embed_unit, (
            f"aggregator-embed.service no longer carries {directive!r}, so a "
            "backfill measured in weeks would compete with interactive work "
            f"instead of yielding to it:\n{agg_embed_unit}"
        )

    # THE MEMORY CEILING IS THIS REPO'S OWN ADDITION, so it is asserted apart
    # from the upstream directives above rather than riding along with them.
    # Upstream caps CPU and IO but not memory, and this host has an OOM
    # history in exactly this workload class — see home/aggregator-embed.nix
    # for the records.
    assert "MemoryHigh=6G" in agg_embed_unit, (
        "aggregator-embed.service lost its MemoryHigh ceiling, so a torch "
        "backfill measured in weeks runs unbounded on a 30G laptop with a "
        f"standing OOM history:\n{agg_embed_unit}"
    )
    # AND IT MUST STAY A THROTTLE. MemoryMax kills, a SIGKILLed worker leaves
    # its per-row claim on disk, and upstream condemns a claim found at
    # startup as a poison row — so swapping this for a hard cap would drop a
    # good row from the index on every kill, silently, and leave an index that
    # looks complete and is short. If this assertion is ever in the way, that
    # is the argument it exists to force.
    assert "MemoryMax=" not in agg_embed_unit, (
        "aggregator-embed.service gained a MemoryMax. That cap KILLS, and a "
        "killed worker's row claim is treated as poison by the embedder, so "
        "each kill silently removes a good row from the vector index. Use "
        f"MemoryHigh, which throttles instead:\n{agg_embed_unit}"
    )

    # PARSE THE VALUE, NOT THE SECOND `=`-DELIMITED FIELD. `awk -F=` here used
    # to take $2, which silently truncates the moment ExecStart carries an
    # argument containing `=`, and emits one line per ExecStart — so a drop-in
    # adding a second one made this variable multiline, and the `cat {var}`
    # below then ran everything after the first newline as a shell command in
    # the VM. Strip the key instead, stop at the first match, and refuse
    # anything that is not a single bare store path, so a future ExecStart
    # that grows arguments fails this lane loudly rather than reading whatever
    # a truncated path happens to point at.
    agg_embed_exec = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat aggregator-embed.service' "
        "| awk '/^ExecStart=/{sub(/^ExecStart=/, \"\"); print; exit}' "
        "| tr -d '\"'"
    ).strip()
    assert (
        agg_embed_exec.startswith("/nix/store/")
        and len(agg_embed_exec.split()) == 1
    ), (
        "could not read a single bare store path out of "
        f"aggregator-embed.service's ExecStart; got {agg_embed_exec!r}. "
        "If ExecStart legitimately gained arguments, split the binary off "
        "here — do not pass this string to a shell."
    )
    agg_embed_script = dellan.succeed(f"cat {agg_embed_exec}")
    # Same store-path ban as the ingest wrapper, same reason (2026-08-16).
    assert "/home/" not in agg_embed_script, (
        "the embed wrapper references a home-directory path, so the worker "
        f"runs a working tree rather than a pinned store path:\n{agg_embed_script}"
    )
    # `--catchup`, not `--once`. One batch per 30-minute tick is ~three weeks
    # before the last row is even attempted, and the symptom is a progress
    # counter that advances just enough to look healthy.
    assert "embed --catchup" in agg_embed_script, (
        f"the embed worker no longer drains the backlog:\n{agg_embed_script}"
    )

    # THE SEED UNIT IS HUMAN-TRIGGERED, and must stay that way. It is the one
    # path with network access and it pulls ~2.4 GB, so nothing may arm it.
    #
    # ASSERTED ON THE UNIT TEXT, not on `is-enabled`, and the difference bit
    # once already. The ingest notifier above checks `is-enabled == "static"`,
    # but that unit is a NixOS-level user unit living in /etc/systemd/user.
    # These come from home-manager, which symlinks into
    # ~/.config/systemd/user, and systemd reports an un-armed symlinked unit
    # as "linked" — with EXIT CODE 1, which `succeed` treats as a failure
    # before any comparison happens. Both spellings mean the same thing here
    # ("no [Install] section, nothing pulls it in"), so the durable assertion
    # is the absence of WantedBy itself.
    agg_seed_unit = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat aggregator-embed-seed.service'"
    )
    assert "WantedBy=" not in agg_seed_unit, (
        "aggregator-embed-seed.service carries an [Install] WantedBy, so some "
        "target pulls it in — a ~2.4 GB download is not something to schedule "
        f"implicitly:\n{agg_seed_unit}"
    )
    # Corroboration from systemd's own view. `|| true` because the un-armed
    # answers ("linked", "static") exit non-zero; the assertion is that it is
    # not the ARMED answer.
    agg_seed_enabled = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user is-enabled aggregator-embed-seed.service' || true"
    ).strip()
    assert agg_seed_enabled != "enabled", (
        f"aggregator-embed-seed.service is armed (is-enabled={agg_seed_enabled!r}); "
        f"it must be startable only by hand"
    )
    # The timer, by contrast, IS expected to report "enabled" — asserted
    # above. Keeping both in one file is what makes the two states legible as
    # a deliberate difference rather than an inconsistency.
    # The inverse of the worker's assertion: this unit is allowed online, and
    # if it were not, the models could never arrive at all.
    assert "HF_HUB_OFFLINE=0" in agg_seed_unit, (
        "aggregator-embed-seed.service is not marked as the online unit, so "
        f"nothing in this deployment can fetch the weights:\n{agg_seed_unit}"
    )

    # Stop the timer before driving the unit by hand. The timer carries
    # OnBootSec=5min + Persistent=true, so on a slow lane it can fire the
    # service underneath these assertions and make the marker counts
    # nondeterministic. Everything below is expressed as a DELTA against a
    # baseline captured after the stop, so an autonomous fire that already
    # happened is harmless.
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user stop aggregator-ingest.timer aggregator-ingest.service; true'"
    )
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user reset-failed aggregator-ingest.service; true'"
    )

    AGG_MARKER = "aggregator ingest run FAILED"

    def agg_notify_count():
        out = dellan.succeed(
            "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
            "journalctl --user -u aggregator-ingest-failure-notify.service "
            "--no-pager' || true"
        )
        return out.count(AGG_MARKER)

    def wait_agg_notify(baseline, what):
        # OnFailure dispatch is asynchronous, so poll rather than assert
        # instantly. Compares against a baseline instead of grepping for
        # presence: this lane trips the notifier more than once and a
        # presence check would pass on a previous run's line.
        import time as _time
        for _ in range(30):
            if agg_notify_count() > baseline:
                return
            _time.sleep(2)
        raise AssertionError(
            f"aggregator OnFailure notifier never fired for {what}; marker "
            f"count stuck at {agg_notify_count()} (baseline {baseline})"
        )

    agg_baseline = agg_notify_count()

    # (1) The real generated wrapper, invoked directly with the adversarial
    # input this VM naturally supplies: no decrypted agenix secret. It must
    # exit non-zero and say which guard tripped, not proceed to ingest
    # anonymously.
    agg_guard = dellan.fail(f"su - jonathan -c '{agg_exec}' 2>&1")
    assert "aggregator-ingest: secret" in agg_guard, (
        "wrapper must name the failing guard when the agenix secret is not "
        f"readable:\n{agg_guard}"
    )

    # (2) The real unit, unmodified, taking that same guard path: a
    # non-zero ExecStart must fail the unit and fire the notifier.
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user start aggregator-ingest.service; true'"
    )
    agg_state = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user is-failed aggregator-ingest.service || true'"
    ).strip()
    assert agg_state == "failed", (
        f"aggregator-ingest.service should be failed after the guard path; "
        f"got is-failed={agg_state!r}"
    )
    wait_agg_notify(agg_baseline, "the real wrapper's guard-path failure")
    agg_baseline = agg_notify_count()
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user reset-failed aggregator-ingest.service'"
    )

    # (3) and (4) inject exit codes the aggregator CLI cannot produce here
    # (no checkout, no network for `uv`) by overriding ONLY ExecStart. The
    # [Unit] section — and with it the OnFailure edge under test — stays
    # exactly the production one.
    def agg_dropin(exit_code):
        dellan.succeed(
            f"printf '#!/bin/sh\\nexit {exit_code}\\n' > /run/agg-exit && "
            "chmod 755 /run/agg-exit"
        )
        dellan.succeed(
            "mkdir -p /home/jonathan/.config/systemd/user/aggregator-ingest.service.d && "
            "printf '[Service]\\nExecStart=\\nExecStart=/run/agg-exit\\n' "
            "> /home/jonathan/.config/systemd/user/aggregator-ingest.service.d/exit.conf"
        )
        dellan.succeed(
            "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
            "systemctl --user daemon-reload'"
        )
        dellan.succeed(
            "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
            "systemctl --user start aggregator-ingest.service; true'"
        )
        return dellan.succeed(
            "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
            "systemctl --user show -P ExecMainStatus aggregator-ingest.service'"
        ).strip()

    # (3) Behavioural negative control: a CLEAN run (exit 0) must leave the
    # unit healthy and must NOT wake the notifier. Without this, (2) and (4)
    # would both pass on an OnFailure wired to fire unconditionally.
    agg_status = agg_dropin(0)
    assert agg_status == "0", f"exit-0 run reported ExecMainStatus={agg_status!r}"
    agg_state = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user is-failed aggregator-ingest.service || true'"
    ).strip()
    assert agg_state != "failed", (
        f"a clean run must not fail the unit; is-failed={agg_state!r}"
    )
    dellan.sleep(6)
    assert agg_notify_count() == agg_baseline, (
        "the failure notifier fired on a CLEAN run — OnFailure is mis-wired "
        f"(marker count {agg_notify_count()}, expected {agg_baseline})"
    )

    # (4) The exit-3 contract. `aggregator ingest --all` exits 3 when the
    # run COMPLETED but ended with a non-empty errors list — a partially
    # successful run, which must still be loud. systemd has to treat 3 as a
    # failure (no SuccessExitStatus= may creep in) and route it to the
    # notifier.
    agg_status = agg_dropin(3)
    assert agg_status == "3", (
        f"expected the injected exit 3 to reach systemd verbatim; "
        f"ExecMainStatus={agg_status!r}"
    )
    agg_state = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user is-failed aggregator-ingest.service || true'"
    ).strip()
    assert agg_state == "failed", (
        "exit 3 (completed with errors) must fail the unit, not be absorbed "
        f"as success; got is-failed={agg_state!r}"
    )
    wait_agg_notify(agg_baseline, "an exit-3 run")

    # Leave the VM clean for later assertions in this lane.
    dellan.succeed(
        "rm -rf /home/jonathan/.config/systemd/user/aggregator-ingest.service.d "
        "/run/agg-exit"
    )
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user daemon-reload'"
    )
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user reset-failed aggregator-ingest.service'"
    )

    # (5) TLS trust store. The unit must hand its process a CA bundle that
    # OpenSSL can actually parse.
    #
    # Regression lock for 2026-08-15: the unit set neither SSL_CERT_FILE nor
    # NIX_SSL_CERT_FILE, `uv run` supplies a python-build-standalone CPython
    # whose compiled cafile (/etc/ssl/cert.pem) does not exist on NixOS, and
    # the run therefore opened every HTTPS connection with ZERO trusted
    # roots. ticktick — the only source that speaks HTTPS from python's
    # stdlib — reported it as "self-signed certificate in certificate chain",
    # which reads as a MITM and is not one. Nothing in this lane asserted the
    # unit's trust store, which is why a config with no trusted CAs shipped
    # green; that is the hole this block closes.
    #
    # Driven through systemd, ExecStart-only drop-in exactly like (3)/(4), so
    # the [Service] Environment= block under test is the production one and
    # the probe observes what the real ingest run would observe. The rest of
    # the unit is untouched, so an exit-1 from the probe also re-proves the
    # OnFailure edge — but this run must exit 0.
    dellan.succeed(
        "mkdir -p /home/jonathan/.config/systemd/user/aggregator-ingest.service.d && "
        "printf '[Service]\\nExecStart=\\nExecStart=%s %s\\n' "
        "'${pkgs.python3}/bin/python3' '${aggregatorCaProbePy}' "
        "> /home/jonathan/.config/systemd/user/aggregator-ingest.service.d/ca-probe.conf"
    )
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user daemon-reload'"
    )
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user start aggregator-ingest.service; true'"
    )
    # Dump before asserting — once the assertion raises, the VM is torn down
    # and the probe's own diagnosis is the only thing that explains why.
    agg_ca_log = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "journalctl --user -u aggregator-ingest.service -n 40 --no-pager' || true"
    )
    print("[diag] aggregator-ingest CA probe journal:\n" + agg_ca_log)
    agg_ca_status = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user show -P ExecMainStatus aggregator-ingest.service'"
    ).strip()
    assert agg_ca_status == "0", (
        "aggregator-ingest.service does not carry a usable TLS trust store — "
        "an ingest run would verify every HTTPS certificate against an empty "
        f"CA set. Probe exited {agg_ca_status!r}; see [ca-probe] FAIL lines "
        f"in:\n{agg_ca_log}"
    )
    assert "[ca-probe] OK" in agg_ca_log, (
        "the CA probe exited 0 without reaching its success line — the "
        f"drop-in may not have taken effect:\n{agg_ca_log}"
    )
    # Independent of the probe's own arithmetic: the journal must show a
    # positive CA count, so a probe silently degraded to a no-op cannot pass.
    agg_ca_counts = _re.findall(r"x509_ca loaded from \S+: (\d+)", agg_ca_log)
    assert agg_ca_counts and int(agg_ca_counts[-1]) > 0, (
        "CA probe reported no positive x509_ca count; a bundle that parses "
        f"into zero roots is indistinguishable from no bundle:\n{agg_ca_log}"
    )

    dellan.succeed(
        "rm -rf /home/jonathan/.config/systemd/user/aggregator-ingest.service.d"
    )
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user daemon-reload'"
    )
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user reset-failed aggregator-ingest.service; true'"
    )
    # Re-arm the timer stopped above. Separate call on purpose: a
    # `VAR=x cmd1; cmd2` prefix scopes VAR to cmd1 only, so a second
    # systemctl in the same `su -c` runs without XDG_RUNTIME_DIR and cannot
    # reach the user bus.
    dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user start aggregator-ingest.timer'"
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

    # claude-pull — the pull half of ~/.claude's continuous delivery.
    # sync-agent.sh (cron) only ever pushed, so a PR merged in the GitHub
    # UI never reached this machine: skills, hooks and settings stayed at
    # the last local commit until someone pulled by hand, and once both
    # sides had commits the daily auto-push started failing
    # non-fast-forward. Same split as claude-idle-handoff above — timer +
    # unit are nix-managed so a fresh host re-creates the schedule, while
    # the script (~/.claude/scripts/claude-pull.sh) lives in the ~/.claude
    # repo and is therefore outside the VM closure.
    #
    # What this lane can prove: the schedule and the exact ExecStart the
    # timer will call. The OnCalendar + Persistent pairing is the
    # load-bearing part and the reason this is not a monotonic timer like
    # its neighbours — Persistent= only has an effect on OnCalendar=, and
    # this machine is a laptop that suspends. Without catch-up, a merge
    # that lands while it is asleep waits for the next natural boundary
    # instead of arriving on resume. The script's own behaviour
    # (fast-forward-only, divergence refusal, lock contention,
    # fetch-failure threshold) is covered by tests/test_claude_pull.sh in
    # the ~/.claude repo.
    assert "claude-pull.timer" in timers, (
        f"claude-pull.timer missing from user timer list:\n{timers}"
    )
    pull_timer = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat claude-pull.timer'"
    )
    for marker in [
        "OnCalendar=*:0/10",
        "Persistent=true",
        "Unit=claude-pull.service",
    ]:
        assert marker in pull_timer, (
            f"claude-pull.timer lost '{marker}':\n{pull_timer}"
        )
    for prop, expected in [("is-enabled", "enabled"), ("is-active", "active")]:
        got = dellan.succeed(
            "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
            f"systemctl --user {prop} claude-pull.timer'"
        ).strip()
        assert got == expected, (
            f"claude-pull.timer {prop}={got!r}, expected {expected!r} "
            f"— merged PRs would never reach the host"
        )
    pull_service = dellan.succeed(
        "su - jonathan -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) "
        "systemctl --user cat claude-pull.service'"
    )
    for marker in [
        "Type=oneshot",
        "ExecStart=%h/.claude/scripts/claude-pull.sh",
        "TimeoutStartSec=",
    ]:
        assert marker in pull_service, (
            f"claude-pull.service lost '{marker}':\n{pull_service}"
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

    # ── dcg, the destructive-command guard (overlays/dcg.nix + home/dcg.nix) ──
    #
    # dcg is the first and richest deny layer the Claude Code guard stack
    # consults before running a shell command. It used to be `cargo
    # install`ed into ~/.local/bin, with ~/.config/dcg/config.toml
    # hand-symlinked to ~/.claude/dcg.toml. The Mint -> NixOS migration
    # deleted both, and the consumer treats "dcg missing" as "nothing to
    # block", so the guard was inert for months with no error anywhere.
    #
    # That failure had two halves and this block asserts both, because
    # either one alone reads as healthy:
    #   (a) the BINARY is present — the half the migration dropped first;
    #   (b) the CONFIG is reachable — a dcg with no config still exits
    #       cleanly, still emits nothing, and still looks exactly like a
    #       dcg that examined the command and approved it.
    #
    # An earlier revision of this block ended with a "negative control"
    # that DELETED the linked config and asserted the destructive command
    # then came back UNDENIED — encoding the fail-open as the expected
    # result. It was a true statement about v0.12.5 and exactly the wrong
    # thing to assert: it made the degraded state a documented feature, so
    # any fix for it would have shown up as a test failure. It is replaced
    # here by two assertions that point the other way:
    #
    #   (c) attribution WITHOUT a degraded state — the deny document must
    #       carry the fixture's own reason string and NO ruleId/packId,
    #       which is how dcg marks an `[overrides]` match as opposed to a
    #       built-in pack match. That proves the config was read without
    #       ever needing to observe the guard disarmed. It comes with a
    #       positive control (`rm -rf /`, which a pack DOES block): an
    #       absence only means something while a pack deny still carries
    #       those fields, and nothing used to assert that it does.
    #   (d) the degraded state must be UNREACHABLE across an activation —
    #       delete the target, re-run home-manager, and the guard must be
    #       armed again (home/dcg.nix seeds home/dcg-fallback.toml).
    #
    # And (e): a malformed config must FAIL the activation. dcg does warn
    # on a TOML parse error, but only on the stderr of a PreToolUse hook,
    # which Claude Code discards — so today it reaches nobody while every
    # override silently stops applying.
    #
    # Two more, both about who actually finds out:
    #
    #   (f) the MARKER FILE. On NixOS, home-manager activation runs inside
    #       home-manager-jonathan.service and `nixos-rebuild` does not
    #       stream unit logs, so the seed banner lands in journalctl and
    #       in front of nobody. A seeded host would look fully configured
    #       while running a strictly weaker rule set — the same silent
    #       degradation in a new costume. home/dcg.nix therefore writes
    #       $XDG_STATE_HOME/dcg/fallback-active.json whenever the fallback
    #       is in force and deletes it when it is not; the session-start
    #       guard-health hook in the ~/.claude repo reads it. That is a
    #       cross-repo contract, so this lane pins its path, its schema and
    #       its lifecycle in both directions.
    #   (g) a dcg problem must not take out the REST of activation. The
    #       hard-fail used to live in an `entryAfter [ "linkGeneration" ]`
    #       entry, which hm.dag sorted ahead of installPackages,
    #       dconfSettings, installCrontab, kittyReloadConfig and
    #       reloadSystemd — so a malformed dcg.toml silently skipped eight
    #       unrelated steps, including the crontab reinstall whose whole
    #       purpose is to stop cron going stale. A guard that breaks
    #       unrelated machinery when it fires is a guard that gets
    #       commented out.
    #   (h) dcg must not EDIT the operator's permission surface. Its
    #       `general.self_heal_hook` defaults to true upstream, and true
    #       means every bare-`dcg` hook invocation rewrites
    #       ~/.claude/settings.json to register dcg's own PreToolUse entry
    #       ahead of the real guard. home/dcg-fallback.toml pins it off;
    #       this lane is what keeps it pinned. Every OTHER config this lane
    #       plants at the link target carries the same pin and is asserted
    #       the same way — a probe running self-heal-armed is harmless only
    #       while settings.json happens to be absent, which is an accident
    #       of ordering, not a property.
    #   (i) an edited fallback must REACH a host that is already running
    #       the seeded one. The seed arm fires only on an absent target, so
    #       the old copy stayed put while the marker's `cmp` — run against
    #       the new store path — failed and cleared the marker: quiet, and
    #       still degraded. The refresh is licensed by the seed's content
    #       hash in the marker, so it can only ever overwrite bytes this
    #       module wrote itself.
    #
    # Every banner assertion below is scoped to a journal CURSOR taken
    # before the restart that is supposed to produce it. The unscoped
    # `journalctl -n 400` the previous revision used could be satisfied by
    # the BOOT-time seed's identical banner, so a silent-reseed regression
    # would have passed. `dcg_journal_since` is the fix; the control
    # assertion under (d) proves the old form was satisfiable without any
    # restart at all.

    # (a) On jonathan's PATH (home.packages -> per-user profile) and
    # executable. `su -` so the assertion is about the login PATH the
    # hook actually runs under, not root's.
    dcg_bin = dellan.succeed("su - jonathan -c 'command -v dcg'").strip()
    assert dcg_bin.startswith("/"), (
        f"dcg did not resolve on jonathan's PATH: {dcg_bin!r}"
    )
    dellan.succeed(f"test -x {dcg_bin}")
    # And it must be a STORE binary. `command -v` lands on
    # /etc/profiles/per-user/jonathan/bin/dcg (useUserPackages), so the
    # store check has to go through the link. This is the regression
    # guard proper: the copy that vanished was an imperative
    # `cargo install` into ~/.local/bin, which would satisfy every
    # assertion above and none of this one.
    dcg_real = dellan.succeed(f"readlink -f {dcg_bin}").strip()
    assert dcg_real.startswith("/nix/store/"), (
        f"dcg on jonathan's PATH resolves to {dcg_real!r}, which is not a "
        "store path — it is not declaratively installed, so an OS migration "
        "or a stray rm can delete it silently again"
    )
    # And it must be the version the overlay pins, EXACTLY. Asserting
    # merely that --version printed something (the previous assertion) is
    # satisfied by any binary at all, so a `version`-only bump in
    # overlays/dcg.nix — which leaves `src` and its hash untouched — would
    # build green and deploy the OLD binary under the NEW label with this
    # lane still passing. `2>/dev/null` because the machine-readable
    # string is on stdout while the decorated banner is on stderr, and the
    # test driver merges the two.
    dcg_version = dellan.succeed(
        f"su - jonathan -c '{dcg_bin} --version 2>/dev/null'"
    ).strip()
    assert dcg_version == "${pkgs.dcg.version}", (
        f"deployed dcg reports version {dcg_version!r}, but overlays/dcg.nix "
        'pins version = "${pkgs.dcg.version}". The label and the artifact '
        "disagree, so the closure is shipping a binary nobody asked for."
    )

    # (b) The config link, and the seed behind it.
    #
    # Nothing is planted first. home/dcg.nix's activation hook already ran
    # at boot, and the VM has no ~/.claude repo — so this is exactly the
    # fresh-host state, and what the lane asserts is that the fresh-host
    # state comes up ARMED rather than silently disarmed.
    import json as _dcg_json
    import re as _re
    import shlex as _shlex

    dellan.succeed("test -L /home/jonathan/.config/dcg/config.toml")
    dcg_cfg_target = dellan.succeed(
        "readlink -f /home/jonathan/.config/dcg/config.toml"
    ).strip()
    assert dcg_cfg_target == "/home/jonathan/.claude/dcg.toml", (
        "~/.config/dcg/config.toml must resolve to the tracked file in the "
        "~/.claude repo (home/dcg.nix mkOutOfStoreSymlink); it resolves to "
        f"{dcg_cfg_target!r}. A store copy here would freeze the pattern "
        "list until the next rebuild."
    )

    # THE LINK IS NOT DANGLING. This one assertion is the whole fix: a
    # dangling link here means dcg drops the entire user layer, permits
    # `curl -X DELETE` with exit 0, empty stdout and ZERO bytes of stderr,
    # and still denies `rm -rf /` from a built-in pack — so every cheaper
    # check in this block passes while the guard is disarmed.
    dellan.succeed("test -f /home/jonathan/.claude/dcg.toml")

    # Verbatim drift check — the one this lane can actually keep. The
    # seeded file must be byte-identical to the tracked source in this
    # flake. (There is deliberately no such check against the real
    # ~/.claude/dcg.toml: it lives in a repo this flake cannot read, so
    # any "copied verbatim" claim about it would be unkeepable.)
    dellan.succeed(
        "cmp ${../home/dcg-fallback.toml} /home/jonathan/.claude/dcg.toml"
    )

    # (f) The marker file, and its contract with the ~/.claude session-start
    # guard-health hook. Path and schema are asserted literally, not read
    # out of the Nix that wrote them, because the reader lives in another
    # repo and hard-codes them — a drift here is a drift the other side
    # cannot see. Bump `schema` on any incompatible change and this
    # assertion will tell you the hook needs updating too.
    dcg_marker_path = "/home/jonathan/.local/state/dcg/fallback-active.json"

    def dcg_read_marker():
        """The marker as a dict, or None when it is absent."""
        if dellan.execute(f"test -f {dcg_marker_path}")[0] != 0:
            return None
        return _dcg_json.loads(dellan.succeed(f"cat {dcg_marker_path}"))

    dcg_marker = dcg_read_marker()
    assert dcg_marker is not None, (
        f"{dcg_marker_path} is absent on a host running the seeded "
        "bootstrap fallback. The banner home/dcg.nix printed went to "
        "journalctl only — nixos-rebuild does not stream unit logs — so "
        "without this file nothing tells the operator or the agent that "
        "the guard is running a weaker rule set than they think:\n"
        + dellan.succeed("ls -la /home/jonathan/.local/state/dcg || true")
    )
    assert dcg_marker["schema"] == 1, (
        f"marker schema is {dcg_marker['schema']!r}, not 1. The "
        "session-start guard-health hook in the ~/.claude repo reads this "
        "file and keys on the schema; bumping it here without bumping it "
        "there means the hook silently stops recognising the degraded "
        "state."
    )
    assert dcg_marker["component"] == "dcg", dcg_marker
    assert dcg_marker["state"] == "fallback-active", dcg_marker
    assert dcg_marker["target"] == "/home/jonathan/.claude/dcg.toml", dcg_marker
    assert dcg_marker["fallback_source"].startswith("/nix/store/"), dcg_marker
    assert dcg_marker["remedy"].strip(), dcg_marker
    # The seed's CONTENT hash, and it must describe the file the marker
    # names. This is the field the NEXT activation reads back to decide
    # whether a seeded target may be refreshed in place (arm (i) below), so
    # a wrong or missing value does not fail loudly — it silently costs the
    # refresh, which is the failure mode the whole arm is about.
    assert dcg_marker["fallback_sha256"] == dellan.succeed(
        "sha256sum " + dcg_marker["fallback_source"]
    ).split()[0], dcg_marker
    # observed_at is UTC ISO-8601 to the second; the reader compares it
    # against now to decide how stale its answer is.
    assert _re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", dcg_marker["observed_at"]
    ), dcg_marker
    # And the claim the file makes must actually hold: `target` really is
    # byte-identical to `fallback_source`. That is the same test the hook
    # re-runs when it wants an answer fresher than observed_at, so if it
    # cannot be run from the fields in the file, the contract is broken.
    dellan.succeed(
        f"cmp {dcg_marker['fallback_source']} {dcg_marker['target']}"
    )

    # And dcg's own loader must agree the user layer LOADED. From outside,
    # `missing`, `invalid` and `rejected` are indistinguishable from
    # `loaded`: all four exit 0 and print nothing on an allow. This is the
    # only place the difference is observable, and it is the same field
    # home/dcg.nix's activation check reads.
    dellan.succeed(
        "su - jonathan -c 'dcg config --format json' "
        "> /tmp/dcg-config.json 2>/dev/null"
    )
    dcg_cfg_doc = _dcg_json.loads(dellan.succeed("cat /tmp/dcg-config.json"))
    dcg_user_layer = next(
        s for s in dcg_cfg_doc["config_sources"] if s["level"] == "user"
    )
    assert dcg_user_layer["status"] == "loaded", (
        "dcg reports its user config layer as "
        f"{dcg_user_layer['status']!r} (detail: {dcg_user_layer.get('detail')!r}). "
        "Every override the operator wrote is inert, and nothing anywhere "
        "says so."
    )

    # Behavioural half: speak the Claude Code hook protocol at the real
    # binary and read the decision off stdout.
    #
    # The decision IS the stdout JSON. Measured on v0.12.5, bare `dcg`
    # exits 0 on a deny, on an allow, on empty stdin and on garbage stdin
    # alike. rc is therefore asserted to be EXACTLY 0: the previous
    # `rc in (0, 1)` accepted an exit-code-signalling dcg as a valid
    # verdict, so an upstream switch to rc=1-on-deny would slip through
    # this lane while the stdout contract quietly changed underneath it.
    #
    # DO NOT relax this by moving the hook to `dcg hook`. Measured: it does
    # exit 1 on a deny, but it emits batch JSONL
    # ({"index":0,"decision":"deny",...}) instead of the PreToolUse
    # document, and prints on allows too. Its --help claims the two are
    # identical without --batch; they are not. Swapping would give a
    # correct exit status and a payload Claude Code cannot read.
    # A timeout is NOT a verdict, and must never be read as one.
    #
    # dcg self-limits a hook evaluation to `hook_timeout_ms` (1000ms by
    # default) and, on expiry, emits a well-formed PreToolUse document
    # carrying `permissionDecision: "ask"` and a reason that says so. That
    # is dcg declining to answer, not dcg permitting the command — but it
    # is shaped exactly like a real verdict, so every assertion below would
    # otherwise read "no answer" as "wrong answer" and fail the lane.
    #
    # This is not hypothetical. It sank vm-minimal (base) on PR #192 with:
    #
    #   AssertionError: dcg did not deny 'curl -X DELETE https://example.com/x'
    #   "DCG could not complete safety evaluation within 1000ms
    #    (stage: pre_evaluation); command was not verified."
    #
    # The job took 3h09m against a normal few minutes — a GitHub runner
    # under enough contention that a 1000ms budget stopped being reachable.
    # `pre_evaluation` means it expired during setup, before looking at the
    # command at all, so the outcome carried no information about the rule
    # set whatsoever. The change under test was a documentation edit.
    #
    # The budget is deliberately NOT raised here. It is dcg's own runtime
    # default and the same one production hosts run, so widening it for the
    # VM would test a configuration nobody uses. Instead the non-answer is
    # retried: cold start (binary page-in, config parse, pack compile) is
    # paid once and the retry runs warm. If dcg genuinely cannot answer,
    # all attempts time out and the assertion still fires — with the
    # timeout quoted, so the failure names itself instead of masquerading
    # as a permissive rule set.
    _DCG_TIMEOUT_MARKER = "could not complete safety evaluation within"

    def _dcg_is_non_answer(doc):
        if doc is None:
            return False
        hso = doc.get("hookSpecificOutput", {})
        return (
            hso.get("permissionDecision") == "ask"
            and _DCG_TIMEOUT_MARKER in hso.get("permissionDecisionReason", "")
        )

    def dcg_decide(command, attempts=3):
        for attempt in range(1, attempts + 1):
            doc, raw = _dcg_decide_once(command)
            if not _dcg_is_non_answer(doc):
                return doc, raw
            print(
                "dcg evaluation timed out on attempt "
                + str(attempt) + "/" + str(attempts)
                + " for " + repr(command)
                + " — retrying warm; this is runner contention, not a verdict"
            )
        raise AssertionError(
            "dcg failed to produce a verdict for " + repr(command) + " in "
            + str(attempts) + " attempts; every one expired against its own "
            "hook_timeout_ms. The guard was never exercised, so this says "
            "nothing about the rule set — the runner is too loaded to answer "
            "inside dcg's budget. Last document:\n" + raw
        )

    def _dcg_decide_once(command):
        payload = _dcg_json.dumps(
            {"tool_name": "Bash", "tool_input": {"command": command}}
        )
        # json.dumps emits no single quotes, so single-quoting both the
        # payload and the binary path is safe without further escaping.
        # stdout goes to a file because dcg's decorated banner lands on
        # stderr and the test driver merges the two streams.
        rc_line = dellan.succeed(
            "printf '%s' '" + payload + "' | su - jonathan -c '" + dcg_bin + "'"
            + " > /tmp/dcg-decision.json 2>/tmp/dcg-decision.err"
            + " ; echo DCGRC=$?"
        )
        rc = int(rc_line.rsplit("DCGRC=", 1)[1].strip())
        assert rc == 0, (
            f"bare dcg exited {rc} on {command!r}. Measured on v0.12.5 it "
            "exits 0 for every input; a non-zero status means either a crash "
            "or that the verdict has moved out of stdout and into the exit "
            "code, which the Claude Code hook does not read.\n"
            + dellan.succeed("cat /tmp/dcg-decision.err")
        )
        raw = dellan.succeed("cat /tmp/dcg-decision.json")
        return (_dcg_json.loads(raw) if raw.strip() else None), raw

    def dcg_assert_denied_by_user_config(command, expect_reason):
        """Deny, AND attributable to the [overrides] layer rather than a pack.

        dcg tags a pack match with ruleId/packId and a config-override
        match with neither, so their absence plus the config's own reason
        string coming back is positive proof the user layer was read.
        The previous revision proved this by deleting the config and
        asserting the command was then permitted — which made the
        fail-open an expected result.
        """
        doc, raw = dcg_decide(command)
        assert doc is not None, (
            f"dcg emitted no decision document for {command!r}, i.e. it "
            "PERMITTED a destructive HTTP verb. Either the binary is not "
            "evaluating or ~/.config/dcg/config.toml is not reaching it — "
            "this is the exact shape of the months-long silent outage."
        )
        hso = doc["hookSpecificOutput"]
        assert hso.get("permissionDecision") == "deny", (
            f"dcg did not deny {command!r}:\n{raw}"
        )
        assert "ruleId" not in hso and "packId" not in hso, (
            f"the deny for {command!r} carries {hso.get('ruleId')!r} — it came "
            "from a built-in pack, not from the user config, so it proves "
            "nothing about the link being read:\n" + raw
        )
        assert expect_reason in hso["permissionDecisionReason"], (
            f"the deny for {command!r} does not carry the expected reason "
            f"{expect_reason!r}; the config that answered is not the one this "
            "assertion is about:\n" + raw
        )
        return hso

    # The seeded fallback denies, and says so in words the operator and
    # the agent both see — running on the fallback announces itself.
    dcg_assert_denied_by_user_config(
        "curl -X DELETE https://example.com/x", "BOOTSTRAP FALLBACK"
    )

    # Allows a benign one. Without this the lane would pass on a dcg that
    # denies everything, which is a broken guard too.
    benign_doc, benign_raw = dcg_decide("ls -la")
    assert benign_doc is None, (
        f"dcg denied a benign command (`ls -la`):\n{benign_raw}"
    )

    # THE POSITIVE CONTROL for the attribution above — the half nothing
    # asserted before.
    #
    # dcg_assert_denied_by_user_config proves a deny came from the
    # `[overrides]` layer rather than a built-in pack by asserting that
    # ruleId and packId are ABSENT. That argument is worth exactly as much
    # as the claim it rests on: that a deny which DID come from a pack
    # carries them. Nothing measured that claim, so a future dcg that
    # stopped tagging pack matches — or a config that accidentally enabled
    # a pack covering destructive HTTP verbs — would leave every
    # dcg_assert_denied_by_user_config call in this block passing while
    # proving nothing about the config being read at all. Which is the
    # "guard looks alive" shape, one level up.
    #
    # `rm -rf /` is the probe because it is the mirror image of the
    # `curl -X DELETE` used everywhere else here: no pack blocks the curl,
    # and no config this lane plants blocks the rm. Measured on v0.12.5 its
    # deny carries packId "core.filesystem" and ruleId
    # "core.filesystem:rm-rf-root-home". It runs against whatever config is
    # in force at this point (the seeded fallback), which is the point —
    # the fallback is strictly ADDITIVE to the built-in packs, so the pack
    # verdict has to survive it.
    dcg_pack_doc, dcg_pack_raw = dcg_decide("rm -rf /")
    assert dcg_pack_doc is not None, (
        "dcg PERMITTED `rm -rf /`, which its own core.filesystem pack "
        "denies. Either the built-in packs are no longer loaded or the "
        "binary is not evaluating — and either way every ruleId/packId "
        "ABSENCE assertion in this block is now vacuous, because a deny "
        "that came from a pack would look identical to one that came from "
        "the user config:\n" + dcg_pack_raw
    )
    dcg_pack_hso = dcg_pack_doc["hookSpecificOutput"]
    assert dcg_pack_hso.get("permissionDecision") == "deny", (
        f"dcg did not deny `rm -rf /`:\n{dcg_pack_raw}"
    )
    assert "packId" in dcg_pack_hso and "ruleId" in dcg_pack_hso, (
        "a deny that came from a BUILT-IN PACK carries "
        f"packId={dcg_pack_hso.get('packId')!r} ruleId="
        f"{dcg_pack_hso.get('ruleId')!r} — at least one is missing, so "
        "their absence no longer distinguishes a pack match from an "
        "`[overrides]` match. dcg_assert_denied_by_user_config is then "
        "asserting nothing: a pack deny satisfies it exactly as well as a "
        "user-config deny, which is the whole property it exists to "
        "establish. Find dcg's new attribution field and rewrite the "
        "helper around it before trusting any arm in this block.\n"
        + dcg_pack_raw
    )

    # (h) Consulting the guard must not let the guard EDIT the operator's
    # permission surface.
    #
    # dcg's `general.self_heal_hook` defaults to TRUE upstream. With it on,
    # every bare-`dcg` hook invocation calls ensure_hook_registered()
    # (main.rs:1534), which reads $HOME/.claude/settings.json
    # (cli.rs:13262 — hardcoded, CLAUDE_CONFIG_DIR is NOT honoured) looking
    # for a PreToolUse entry whose matcher is "Bash|PowerShell" and whose
    # command is the running binary's own absolute path. dcg is registered
    # INDIRECTLY on this host, via ~/.claude/hooks/bash-guard.py, so that
    # entry is never present and the repair branch (cli.rs:13635) fires on
    # EVERY Bash tool call: it inserts dcg's entry at PreToolUse[0] — ahead
    # of the real guard — and re-serialises the whole file.
    #
    # This is not hypothetical. It fired on the live host on 2026-08-24:
    # the injected entry named a /nix/store path, the trailing newline was
    # stripped, and the harness tripwire logged four
    # ConfigChange/user_settings events for that single write. It is also
    # not self-limiting — the injected command embeds the store path, so
    # every version bump re-triggers it and a hand revert does not stick.
    #
    # home/dcg-fallback.toml pins `self_heal_hook = false`, and that pin is
    # a ONE-LINE default that a version bump, a config rewrite or a
    # well-meaning tidy-up could flip back with nothing to notice. This arm
    # is the notice. It runs here, against the seeded fallback, because
    # that is the config a FRESH host comes up on — before the operator has
    # read a single line of output.
    dcg_settings = "/home/jonathan/.claude/settings.json"
    dellan.succeed(
        "install -D -o jonathan -g users -m 0644 "
        "${dcgVmSettings} " + dcg_settings
    )

    def dcg_settings_sha():
        return dellan.succeed("sha256sum " + dcg_settings).split()[0]

    dcg_settings_before = dcg_settings_sha()
    # The trigger has to be a BARE `dcg` hook invocation on a payload that
    # DENIES — that is the only form reaching ensure_hook_registered().
    # `dcg config` and the subcommands do not, so an arm that probed one of
    # those would report an untouched settings.json from a code path that
    # never had the chance to touch it. dcg_assert_denied_by_user_config
    # speaks the hook protocol at the deployed binary, which is exactly the
    # shape a real Bash tool call produces.
    dcg_assert_denied_by_user_config(
        "curl -X DELETE https://example.com/x", "BOOTSTRAP FALLBACK"
    )
    dcg_settings_after = dcg_settings_sha()
    assert dcg_settings_after == dcg_settings_before, (
        "dcg REWROTE /home/jonathan/.claude/settings.json — the operator's "
        "Claude Code PERMISSION SURFACE — from inside one PreToolUse hook "
        "invocation. This is not a stale hash: it means "
        "general.self_heal_hook is back ON (upstream defaults it to true), "
        "so ensure_hook_registered() has inserted the "
        'matcher-"Bash|PowerShell" entry pointing at dcg itself at '
        "PreToolUse[0], AHEAD of the real guard, and re-serialised the "
        "file. On the live host that ran once per Bash tool call. "
        "FIX: restore `self_heal_hook = false` under [general] in "
        "home/dcg-fallback.toml — do not relax this assertion.\n"
        f"  sha256 before: {dcg_settings_before}\n"
        f"  sha256 after:  {dcg_settings_after}\n"
        "  settings.json now reads:\n"
        + dellan.succeed("cat " + dcg_settings)
    )

    # THE POSITIVE CONTROL, and the reason the assertion above is worth
    # anything. An unchanged hash has two explanations — the pin works, or
    # the probe never reached the self-heal code path at all — and only one
    # of them is a passing test. A future change that stopped the probe
    # short (a helper rewired to `dcg config`, a payload that no longer
    # denies, a plant that silently failed to land) would leave the arm
    # above green and hollow.
    #
    # So: swap in a config that is the fallback in every respect the arm
    # cares about EXCEPT that it omits `self_heal_hook`, and run the very
    # same probe. The hash must now CHANGE. Attribution is via
    # dcg_assert_denied_by_user_config against this fixture's own reason
    # string, which matters more than usual here: a control config that
    # failed to load would leave dcg running with NO user layer, and a dcg
    # with no config rewrites settings.json too — so the control would
    # "pass" while proving nothing about self_heal_hook.
    dellan.succeed(
        "install -D -o jonathan -g users -m 0644 "
        "${dcgSelfHealConfig} /home/jonathan/.claude/dcg.toml"
    )
    dellan.succeed(
        "install -D -o jonathan -g users -m 0644 "
        "${dcgVmSettings} " + dcg_settings
    )
    dcg_control_before = dcg_settings_sha()
    dcg_assert_denied_by_user_config(
        "curl -X DELETE https://example.com/x", "${dcgSelfHealReason}"
    )
    dcg_control_after = dcg_settings_sha()
    assert dcg_control_after != dcg_control_before, (
        "CONTROL FAILED: with `self_heal_hook` deliberately unset, dcg left "
        "settings.json byte-identical. The self-heal path this lane exists "
        "to pin down is no longer reachable from the probe, so the "
        "unchanged-hash assertion above is proving nothing and would stay "
        "green if the pin were dropped. Find out what changed — the "
        "upstream default, the file dcg reads, or the shape of the probe — "
        "before trusting either arm.\n"
        f"  sha256 both:   {dcg_control_before}"
    )
    # And it changed in the specific way that makes it a security problem
    # rather than a reformat: dcg's own entry, at index 0, AHEAD of the
    # operator's guard, naming the running binary. Pinned tightly on
    # purpose — the version is pinned too, so the only thing that can move
    # this is a deliberate bump, which is exactly when it should be re-read.
    dcg_healed = _dcg_json.loads(dellan.succeed("cat " + dcg_settings))
    dcg_pre = dcg_healed["hooks"]["PreToolUse"]
    assert dcg_pre[0]["matcher"] == "Bash|PowerShell", (
        "CONTROL FAILED: dcg rewrote settings.json, but the entry it "
        "inserted first is not the matcher-\"Bash|PowerShell\" one the (h) "
        "failure message tells the reader to look for. The mechanism has "
        f"moved and the diagnostic is now misleading: {dcg_pre!r}"
    )
    dcg_healed_cmd = dcg_pre[0]["hooks"][0]["command"]
    assert dcg_healed_cmd == dcg_real, (
        "CONTROL FAILED: the injected entry points at "
        f"{dcg_healed_cmd!r}, not at the running binary {dcg_real!r}. The "
        "store path in the injected command is why this is not idempotent "
        "across version bumps, so it is part of what (h) is about."
    )
    assert any(
        h["command"].endswith("bash-guard.py")
        for e in dcg_pre[1:]
        for h in e["hooks"]
    ), (
        "CONTROL FAILED: after the rewrite the operator's own guard entry "
        "is not sitting behind the injected one. Either it was dropped "
        f"outright or the ordering is not what (h) describes: {dcg_pre!r}"
    )

    # Restore. Remove the control config and the plant, then re-run
    # home-manager so the arms below start from the seeded fallback they
    # expect — and so nothing downstream inherits a self-heal-armed dcg or
    # a settings.json for it to rewrite.
    dellan.succeed("rm " + dcg_settings)
    dellan.succeed("rm /home/jonathan/.claude/dcg.toml")
    dellan.succeed("systemctl restart home-manager-jonathan.service")
    dellan.succeed(
        "cmp ${../home/dcg-fallback.toml} /home/jonathan/.claude/dcg.toml"
    )

    # (c) The live-edit property mkOutOfStoreSymlink exists for: write a
    # DIFFERENT config straight to the link target, no rebuild, and the
    # next invocation must answer out of it. Its reason string is defined
    # once in Nix and interpolated into both the fixture and this
    # assertion, so the two cannot drift.
    dellan.succeed(
        "install -D -o jonathan -g users -m 0644 "
        "${dcgVmConfig} /home/jonathan/.claude/dcg.toml"
    )
    # …and answering out of THIS config must not edit the permission
    # surface either. Arm (h) pinned that for the seeded fallback, but the
    # fallback is not the only config this lane runs dcg under: every file
    # planted at the link target is one, and dcgVmConfig used to omit
    # `self_heal_hook` altogether — so this probe ran with self-heal ARMED.
    # It was harmless only because settings.json had been removed eleven
    # lines earlier, an ordering accident nothing asserted and any later
    # edit could undo.
    #
    # The plant is what gives the assertion teeth: measured on v0.12.5,
    # with settings.json ABSENT dcg creates nothing whatever the setting
    # says, so an unplanted arm would pass just as happily on a host where
    # the pin had been dropped.
    dellan.succeed(
        "install -D -o jonathan -g users -m 0644 "
        "${dcgVmSettings} " + dcg_settings
    )
    dcg_live_before = dcg_settings_sha()
    dcg_assert_denied_by_user_config(
        "curl -X DELETE https://example.com/x", "${dcgVmBlockReason}"
    )
    dcg_live_after = dcg_settings_sha()
    assert dcg_live_after == dcg_live_before, (
        "dcg rewrote /home/jonathan/.claude/settings.json while answering "
        "out of the live-edit fixture. `self_heal_hook = false` is missing "
        "from dcgVmConfig in tests/base.nix, or it no longer suppresses "
        "ensure_hook_registered(). Every config this lane plants at the "
        "link target has to carry the pin — a probe that runs "
        "self-heal-armed is only harmless while settings.json happens to "
        "be absent, and that is not a property this lane should depend "
        "on.\n"
        f"  sha256 before: {dcg_live_before}\n"
        f"  sha256 after:  {dcg_live_after}\n"
        "  settings.json now reads:\n"
        + dellan.succeed("cat " + dcg_settings)
    )
    # Remove the plant again. Everything below restarts activation and
    # re-probes, and none of it should inherit a settings.json for a
    # regression to rewrite — the same hygiene the restore above keeps.
    dellan.succeed("rm " + dcg_settings)

    # Journal scoping. Every banner assertion from here on is about output
    # a SPECIFIC restart produced, so it is read from a cursor taken just
    # before that restart. `journalctl --show-cursor -n 0` prints only the
    # `-- cursor: …` trailer, which is exactly what --after-cursor wants.
    def dcg_journal_cursor():
        line = dellan.succeed(
            "journalctl -u home-manager-jonathan.service --no-pager "
            "-n 0 --show-cursor"
        )
        return line.rsplit("-- cursor:", 1)[1].strip()

    def dcg_journal_since(cursor):
        return dellan.succeed(
            "journalctl -u home-manager-jonathan.service --no-pager -o cat "
            f"--after-cursor '{cursor}'"
        )

    # An activation that finds the operator's file in place must leave it
    # ALONE and must not claim to have seeded anything. Two jobs at once:
    # it is a real property (the seed arm must never clobber a hand-edited
    # list), and it is the control that shows why the scoping above is
    # load-bearing.
    dcg_cursor = dcg_journal_cursor()
    dellan.succeed("systemctl restart home-manager-jonathan.service")
    dcg_noseed_log = dcg_journal_since(dcg_cursor)
    assert "SEEDED BOOTSTRAP FALLBACK CONFIG" not in dcg_noseed_log, (
        "home-manager announced a seed on a run where the target already "
        "existed. Either it overwrote the operator's pattern list, or it "
        "printed a banner it had not earned:\n" + dcg_noseed_log[-3000:]
    )
    # Nor may the REFRESH arm (i) fire here, and this is the run that
    # proves it discriminates. Its precondition is half-met on purpose: a
    # marker written by the seed two restarts ago is still on disk, so the
    # only thing standing between the operator's file and an overwrite is
    # the content hash comparison. A refresh arm keyed on the marker's mere
    # PRESENCE — the obvious cheaper implementation — would clobber the
    # hand-edited list right here.
    assert "REFRESHED BOOTSTRAP FALLBACK CONFIG" not in dcg_noseed_log, (
        "home-manager announced a fallback refresh on a run where the "
        "target was the operator's own config. The refresh arm is keyed on "
        "something weaker than 'the bytes are still exactly what I seeded' "
        "and has just overwritten a hand-edited pattern list:\n"
        + dcg_noseed_log[-3000:]
    )
    dellan.succeed("cmp ${dcgVmConfig} /home/jonathan/.claude/dcg.toml")
    # THE CONTROL. Unscoped, the boot-time seed's identical banner is still
    # sitting in this unit's journal — so the previous revision's
    # `journalctl -n 400 | grep SEEDED` was satisfied here, on a restart
    # that seeded nothing. That is the silent-reseed regression the
    # cursor closes, demonstrated rather than argued.
    dcg_whole_log = dellan.succeed(
        "journalctl -u home-manager-jonathan.service --no-pager -o cat"
    )
    assert "SEEDED BOOTSTRAP FALLBACK CONFIG" in dcg_whole_log, (
        "control failed: the boot-time seed banner is no longer in this "
        "unit's journal at all, so the fresh-host seed did not happen or "
        "the journal was cleared. Everything (b) asserted is in doubt."
    )
    # And with the operator's own file in force, the marker must be GONE.
    # A marker that is never cleared is a marker the reader learns to
    # ignore, which is the same silence in a different place.
    assert dcg_read_marker() is None, (
        "the fallback marker survived an activation that found the "
        "operator's own config in place. It now reports a degraded state "
        "that is not happening, and the session-start hook will warn on "
        "every healthy session until someone deletes it by hand."
    )

    # (d) The degraded state must be UNREACHABLE across an activation.
    # Delete the target — the thing a fresh host, or claude-pull, or a
    # stray rm actually does — and re-run home-manager. Activation must
    # succeed, re-seed, and say loudly that it did.
    dellan.succeed("rm /home/jonathan/.claude/dcg.toml")
    dcg_cursor = dcg_journal_cursor()
    dellan.succeed("systemctl restart home-manager-jonathan.service")
    dellan.succeed("test -f /home/jonathan/.claude/dcg.toml")
    dellan.succeed(
        "cmp ${../home/dcg-fallback.toml} /home/jonathan/.claude/dcg.toml"
    )
    reseed_log = dcg_journal_since(dcg_cursor)
    assert "SEEDED BOOTSTRAP FALLBACK CONFIG" in reseed_log, (
        "home-manager re-seeded nothing, or did it silently. A silent repair "
        "is still a config the operator believes is theirs and is not:\n"
        + reseed_log[-3000:]
    )
    # …and the marker is back, with a fresh observation.
    dcg_marker = dcg_read_marker()
    assert dcg_marker is not None and dcg_marker["state"] == "fallback-active", (
        "the re-seeded fallback left no marker, so the only trace of the "
        "degraded state is again a banner in a unit log nobody reads: "
        f"{dcg_marker!r}"
    )
    dcg_assert_denied_by_user_config(
        "curl -X DELETE https://example.com/x", "BOOTSTRAP FALLBACK"
    )

    # (i) A fallback that CHANGES must reach a host already running the
    # seeded one — and must not go QUIET on the way.
    #
    # The seed arm fires only on an ABSENT target. So editing
    # home/dcg-fallback.toml and rebuilding a still-seeded host used to
    # leave the OLD copy exactly where it was, while the marker's `cmp` ran
    # against the NEW store path, failed, and took the "the operator's own
    # file is in force" branch: marker deleted, desktop notification
    # silenced, journal banner never printed — with the bytes on disk still
    # a bootstrap fallback, just not the current one. The host stops
    # REPORTING the degraded state without leaving it, and the way in is a
    # routine edit to a tracked file in this repo.
    #
    # A store path cannot change inside a running VM, so this stages the
    # same state from the other end: put an OLDER fallback at the target
    # and make the marker say that is what activation seeded. From the
    # activation script's side the two are indistinguishable — the marker
    # records content hash X, the target hashes to X, and X is not the
    # current fallback.
    dcg_target = "/home/jonathan/.claude/dcg.toml"
    dcg_fallback_sha = dellan.succeed(
        "sha256sum ${../home/dcg-fallback.toml}"
    ).split()[0]
    dellan.succeed(
        "install -D -o jonathan -g users -m 0644 "
        "${dcgStaleFallback} " + dcg_target
    )
    dcg_stale_sha = dellan.succeed("sha256sum " + dcg_target).split()[0]
    assert dcg_stale_sha != dcg_fallback_sha, (
        "the stale-fallback fixture is byte-identical to the current "
        "fallback, so there is no 'the seed moved' state to observe and "
        "this arm would pass without exercising anything"
    )
    # Derived from the marker activation ACTUALLY wrote a moment ago, not
    # hand-built: this arm is about activation reading its OWN record back,
    # so the record has to be its own in every field it does not need to
    # move.
    dcg_stale_marker = dict(dcg_marker)
    dcg_stale_marker["fallback_sha256"] = dcg_stale_sha
    dcg_stale_marker["fallback_source"] = (
        "/nix/store/" + "0" * 32 + "-dcg-fallback.toml"
    )
    dellan.succeed(
        "printf '%s' " + _shlex.quote(_dcg_json.dumps(dcg_stale_marker))
        + " > " + dcg_marker_path
    )
    dcg_cursor = dcg_journal_cursor()
    dellan.succeed("systemctl restart home-manager-jonathan.service")

    # The bytes on disk are the CURRENT fallback again…
    dellan.succeed("cmp ${../home/dcg-fallback.toml} " + dcg_target)
    # …activation said so…
    dcg_refresh_log = dcg_journal_since(dcg_cursor)
    assert "REFRESHED BOOTSTRAP FALLBACK CONFIG" in dcg_refresh_log, (
        "home-manager updated a stale seeded fallback silently, or not at "
        "all. A repair nobody is told about is a config the operator "
        "believes is theirs and is not:\n" + dcg_refresh_log[-3000:]
    )
    # …and the half that makes this a security finding rather than a
    # staleness one: the MARKER SURVIVED. This is the assertion the old
    # code failed.
    dcg_marker = dcg_read_marker()
    assert dcg_marker is not None and dcg_marker["state"] == "fallback-active", (
        "the marker was cleared on a host that is STILL running the "
        "bootstrap fallback — it was merely running an older one. Nothing "
        "now tells the session-start guard-health hook, the desktop or the "
        "journal that the operator's real pattern list is not loaded, and "
        "all it took was editing a tracked file in this repo: "
        f"{dcg_marker!r}"
    )
    assert dcg_marker["fallback_sha256"] == dcg_fallback_sha, (
        "the marker still records the OLD fallback's content hash "
        f"({dcg_marker['fallback_sha256']!r}, current is "
        f"{dcg_fallback_sha!r}). The next activation reads that back, "
        "decides the target is not what it seeded, and never refreshes "
        "again — so the repair would work exactly once: "
        f"{dcg_marker!r}"
    )
    # And the guard answers out of the refreshed file.
    dcg_assert_denied_by_user_config(
        "curl -X DELETE https://example.com/x", "BOOTSTRAP FALLBACK"
    )

    # (e) A malformed config must FAIL activation, not be absorbed.
    # dcg does warn on a TOML parse error — but on the stderr of a
    # PreToolUse hook, which Claude Code discards, so in the agent loop it
    # reaches nobody while every override stops applying. The file is the
    # operator's, so activation refuses to finish rather than rewriting it.
    dellan.succeed(
        "install -D -o jonathan -g users -m 0644 "
        "${dcgBrokenConfig} /home/jonathan/.claude/dcg.toml"
    )
    dcg_cursor = dcg_journal_cursor()
    dellan.fail("systemctl restart home-manager-jonathan.service")
    broken_log = dcg_journal_since(dcg_cursor)
    assert "USER CONFIG LAYER IS NOT LOADED" in broken_log, (
        "home-manager activation failed, but not with the dcg diagnostic — "
        "so the failure does not tell the operator what to fix:\n"
        + broken_log[-3000:]
    )
    assert "TOML parse error" in broken_log, (
        "the activation failure does not quote dcg's own parse error, so the "
        "operator gets no line number:\n" + broken_log[-3000:]
    )

    # (g) …and the rest of activation still ran. home-manager inlines every
    # activation entry into one `set -eu` script, so an `exit 1` from an
    # entry sorted early kills every entry after it. The check used to sit
    # in `entryAfter [ "linkGeneration" ]`, which hm.dag placed 8th of 16 —
    # ahead of installPackages, dconfSettings, ensureClaudeLogsDir,
    # installCalibrePlugins, installCrontab, kittyReloadConfig,
    # onFilesChange and reloadSystemd. So a typo in dcg.toml silently
    # skipped the crontab reinstall, which is the exact stale-crontab drift
    # the comment above `installCrontab` in home/jonathan-linux.nix was
    # written about, plus the systemd reload that makes changed user units
    # take effect at all. The fix splits the check in two and makes the
    # verdict entry depend on every other entry, so it sorts last: the
    # generation applies everything it can and then refuses to report
    # success. Read from the SAME failed run as the banner above, using the
    # step markers home-manager itself logs.
    dcg_steps = _re.findall(r"Activating (\S+)", broken_log)
    assert dcg_steps[-1] == "dcgConfigVerdict", (
        "the dcg verdict is not the last activation step; anything sorted "
        f"after it dies when it exits 1. Order was: {dcg_steps}"
    )
    assert "dcgConfigState" in dcg_steps, (
        f"the dcg seed/marker step did not run at all: {dcg_steps}"
    )
    # installCrontab specifically, because the stale-crontab drift is the
    # documented incident this would re-create (see the comment above
    # `installCrontab` in home/jonathan-linux.nix); reloadSystemd because
    # skipping it is how changed user units quietly fail to take effect.
    dcg_after_state = dcg_steps[dcg_steps.index("dcgConfigState") + 1:]
    for dcg_late_step in ["installCrontab", "reloadSystemd"]:
        assert dcg_late_step in dcg_after_state, (
            f"activation never reached {dcg_late_step!r} on a run that "
            "failed only because dcg.toml was malformed. A guard whose "
            "firing breaks the crontab reinstall and the systemd reload is "
            "a guard that gets commented out, which turns one loud failure "
            f"into a permanent silent one. Order was: {dcg_steps}"
        )

    # Restore, so the lane does not end on a deliberately failed unit.
    dellan.succeed("rm /home/jonathan/.claude/dcg.toml")
    dellan.succeed("systemctl reset-failed home-manager-jonathan.service")
    dellan.succeed("systemctl start home-manager-jonathan.service")
    dellan.succeed("test -f /home/jonathan/.claude/dcg.toml")
  '';
}
