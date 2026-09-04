# vm-claude-egress: behavioural gate for the phase-1 Claude Code egress
# observer (modules/nixos/claude-egress-observe.nix +
# home/claude-egress-slice.nix).
#
# Run: nix build .#checks.x86_64-linux.vm-claude-egress -L
#
# Every assertion here is behavioural. None of them read a setting back
# and call that proof — that is the PR #184 lesson, where a green gate, a
# self-review and a twelve-value read-back all passed while the primary
# workflow was broken, because every check verified that settings were
# present and correct rather than that the workflow still worked.
#
# Six assertions, in the spec's numbering:
#
#   1. Observer captures    — traffic from inside the slice is logged
#   2. Scoping holds        — identical traffic outside it is NOT
#   3. Slice absent         — table loads, networking survives, bind exits 0
#   4. Rebind               — a recreated cgroup is re-bound, not silently dead
#   5. Launcher resolution  — the zsh function beats a planted ~/.local/bin
#   6. Firewall untouched   — iptables backend still owns the firewall
#
# 2 is deliberately ordered AFTER 1 and written as a count DELTA: as a
# presence check it would pass vacuously whenever the observer is simply
# broken, which is the one situation it is supposed to catch.
#
# Three invariants ride along inside those sections rather than as
# sections of their own, because each one needs state the section around
# it has already built:
#
#   - the reporter's window spans a REBOOT (inside 3, which reboots)
#   - an aged-out resolution pair stops matching (inside the report block)
#   - the launcher does not leak XDG_RUNTIME_DIR (inside 5)
{ pkgs, inputs }:
let
  nft = "${pkgs.nftables}/bin/nft";
  bash = "${pkgs.bash}/bin/bash";
in
(import ./lib/common.nix { inherit pkgs inputs; }).mkFeatureTest {
  name = "vm-claude-egress";
  hm = ../home/_test-claude-egress.nix;
  extraModules = [
    ../modules/nixos/claude-egress-observe.nix
    {
      services.claudeEgressObserve.enable = true;
      # Fixture for the reporter's forward-resolution join. The VM has no
      # DNS, so without a resolvable candidate name section 1 would be
      # empty for the trivial reason and the join itself would never run.
      # .98 stands in for a known destination, .99 for an unknown one, and
      # the report has to sort them into different sections.
      networking.hosts."192.168.1.98" = [ "api.anthropic.com" ];
    }
  ];
  testScript = ''
    import re

    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("home-manager-jonathan.service")
    dellan.wait_for_unit("default.target", "jonathan")
    dellan.wait_for_unit("claude-egress-table.service")
    # home-manager-jonathan.service going active does NOT mean the user
    # units it just linked have finished starting — it queues them and
    # returns. Observed flaking here on a slow run: the slice cgroup was
    # still absent one line later. Prod tolerates the same race via the
    # bind timer's OnBootSec=1min; the test has to wait explicitly.
    dellan.wait_for_unit("claude-egress.slice", "jonathan")

    uid = dellan.succeed("id -u jonathan").strip()
    RUNTIME = f"XDG_RUNTIME_DIR=/run/user/{uid}"

    # The bind timer fires on its own schedule (OnBootSec=1min /
    # OnUnitActiveSec=5min). Stop it so a tick cannot land in the middle
    # of the stale-binding window assertion 4 constructs; every rebind
    # below is then an explicit, synchronous `systemctl start`.
    dellan.succeed("systemctl stop claude-egress-bind.timer")

    def nft_chain():
        return dellan.succeed(
            "${nft} list chain inet claude_egress output"
        )

    def counter():
        m = re.search(r"counter packets (\d+)", nft_chain())
        return int(m.group(1)) if m else None

    def log_count():
        return int(dellan.succeed(
            "journalctl -k --no-pager | grep -c 'claude-egress: ' || true"
        ).strip())

    def slice_cgroup():
        return dellan.succeed(
            f"find /sys/fs/cgroup/user.slice/user-{uid}.slice/user@{uid}.service "
            "-maxdepth 4 -type d -name claude-egress.slice -print -quit "
            "2>/dev/null || true"
        ).strip()

    def state_file():
        raw = dellan.succeed("cat /run/claude-egress/state 2>/dev/null || true")
        out = {}
        for line in raw.splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k] = v
        return out

    def user_systemctl(args):
        return dellan.succeed(
            f"su - jonathan -c '{RUNTIME} systemctl --user {args}'"
        )

    # Dial targets: unoccupied addresses on this node's own eth1 subnet.
    # On-link, so the SYN really is emitted through the output hook;
    # nothing answers, so nothing depends on a listener existing.
    node_ip = dellan.succeed(
        "ip -4 -o addr show dev eth1 | grep -o 'inet [0-9.]*' | cut -d' ' -f2"
    ).strip()
    assert node_ip.startswith("192.168.1."), (
        f"unexpected test-network address {node_ip} — the networking.hosts "
        "fixture above pins 192.168.1.98"
    )
    dial_ip = "192.168.1.99"        # resolves to no candidate name
    known_ip = "192.168.1.98"       # networking.hosts -> api.anthropic.com
    print(f"[setup] node eth1={node_ip} dial targets={dial_ip},{known_ip}")

    dellan.succeed(
        "printf '%s\\n' '#!/bin/sh' "
        "'timeout 3 ${bash} -c \"exec 3<>/dev/tcp/$1/443\"' "
        "'exit 0' > /run/egress-dial && chmod 755 /run/egress-dial"
    )

    def dial_in_slice(target=None):
        target = target or dial_ip
        dellan.succeed(
            f"su - jonathan -c '{RUNTIME} systemd-run --user --scope --quiet "
            f"--slice=claude-egress.slice -- /run/egress-dial {target}' || true"
        )
        dellan.sleep(2)

    def dial_outside(target=None):
        target = target or dial_ip
        dellan.succeed(f"su - jonathan -c \"/run/egress-dial {target}\" || true")
        dellan.sleep(2)

    def dial_sibling_slice(target=None):
        # Same uid, same user manager, DIFFERENT slice — jonathan's browser
        # and IDE live here. This is the control that separates
        # cgroup-scoped from uid-scoped and from
        # whole-user-manager-scoped; the plain outside dial above runs in
        # the driver's root session and would still pass against a rule
        # bound one level too high.
        target = target or dial_ip
        dellan.succeed(
            f"su - jonathan -c '{RUNTIME} systemd-run --user --scope --quiet "
            f"--slice=app.slice -- /run/egress-dial {target}' || true"
        )
        dellan.sleep(2)

    def run_bind():
        dellan.succeed("systemctl start claude-egress-bind.service")

    # ── The level index is DISCOVERED, never computed ─────────────────
    #
    # systemd derives a slice's parent from the dashes in its own name,
    # so claude-egress.slice does not sit directly under
    # user@<uid>.service — it sits under an auto-created claude.slice,
    # one level deeper. The naive arithmetic gives level 4; the truth is
    # 5. A level-4 rule parses, loads, and matches nothing — a silent
    # no-op that looks armed, i.e. exactly the PR #184 shape. This block
    # pins the discovery, so a future refactor that starts computing the
    # level instead of finding it fails here.
    cg = slice_cgroup()
    assert cg, (
        "claude-egress.slice has no cgroup — the HM slice unit did not start"
    )
    rel = cg[len("/sys/fs/cgroup/"):]
    level = len(rel.split("/"))
    # The arithmetic a reader would write without knowing about the
    # auto-created parent slice. Naming it here makes the gap explicit
    # rather than leaving "5, not 4" as prose in the module header.
    naive_rel = f"user.slice/user-{uid}.slice/user@{uid}.service/claude-egress.slice"
    naive_level = len(naive_rel.split("/"))
    print(f"[setup] slice cgroup={cg}\n[setup] rel={rel} level={level} naive={naive_level}")
    assert rel.endswith("claude.slice/claude-egress.slice"), (
        "systemd no longer nests the dashed slice name under an auto-created "
        f"claude.slice, so the discovered depth is not what the module documents: {rel}"
    )
    assert level > naive_level, (
        f"the discovered level ({level}) equals the naive computation "
        f"({naive_level}) — discovery is no longer load-bearing and the "
        "wrong-level control below stops meaning anything"
    )

    run_bind()
    chain = nft_chain()
    print("[setup] bound chain:\n" + chain)
    assert f'socket cgroupv2 level {level} "{rel}"' in chain, (
        f"bind unit did not bind level {level} of {rel}:\n{chain}"
    )
    st = state_file()
    assert st.get("state") == "bound", f"state file does not report bound: {st}"
    assert st.get("level") == str(level), f"state file level {st} != {level}"

    # nft is what proves the level index is load-bearing rather than
    # decorative: the SAME cgroup at the WRONG ancestor level must match
    # nothing. This is the negative control for the discovery above.
    dellan.succeed(
        f'${nft} add rule inet claude_egress output socket cgroupv2 level 4 \\"{rel}\\" '
        'counter comment \\"wrong-level control\\"'
    )

    def wrong_level_counter():
        m = re.findall(r"counter packets (\d+)", nft_chain())
        return int(m[-1])

    # ── 1. Observer captures ─────────────────────────────────────────
    base_c, base_l, base_w = counter(), log_count(), wrong_level_counter()
    print(f"[1] baseline counter={base_c} log={base_l} wrong-level={base_w}")
    dial_in_slice()
    got_c, got_l, got_w = counter(), log_count(), wrong_level_counter()
    print(f"[1] after in-slice dial counter={got_c} log={got_l} wrong-level={got_w}")
    lines = dellan.succeed(
        "journalctl -k --no-pager | grep 'claude-egress: ' | tail -3 || true"
    )
    print("[1] log lines:\n" + lines)
    assert got_c > base_c, (
        "traffic from a process inside claude-egress.slice did not match the "
        f"rule — the observer is not capturing (counter {base_c} -> {got_c})"
    )
    assert got_l > base_l, (
        f"no claude-egress: journal line for the in-slice dial ({base_l} -> {got_l})"
    )
    assert f"DST={dial_ip}" in lines and "DPT=443" in lines, (
        f"the logged line does not carry the destination that was dialled:\n{lines}"
    )
    assert got_w == base_w, (
        "the wrong-ancestor-level rule matched too, so the level index is not "
        f"discriminating and level 4 vs 5 would not have mattered ({base_w} -> {got_w})"
    )

    # ── 2. Scoping holds ─────────────────────────────────────────────
    # A count DELTA around the action, ordered after 1 has proven the
    # observer live. As a presence check ("no line mentioning X") this
    # would pass on a completely dead observer.
    for label, dial in [
        ("root session", dial_outside),
        ("jonathan's app.slice", dial_sibling_slice),
    ]:
        pre_c, pre_l = counter(), log_count()
        dial()
        post_c, post_l = counter(), log_count()
        print(f"[2] {label}: counter {pre_c}->{post_c} log {pre_l}->{post_l}")
        assert post_c == pre_c, (
            f"an identical dial from {label} — OUTSIDE claude-egress.slice — "
            f"matched the rule (counter {pre_c} -> {post_c}); the control is "
            "not cgroup-scoped and would observe far more than Claude Code"
        )
        assert post_l == pre_l, (
            f"traffic from {label} produced a claude-egress: line "
            f"({pre_l} -> {post_l})"
        )

    # ── 4. Rebind after recreation ───────────────────────────────────
    # F1's second half: the rule carries the cgroup INODE as a constant,
    # so a slice that is destroyed and recreated leaves a rule that looks
    # armed and matches nothing.
    ino1 = dellan.succeed(f"stat -c %i {cg}").strip()
    user_systemctl("stop claude-egress.slice")
    user_systemctl("start claude-egress.slice")
    dellan.wait_for_unit("claude-egress.slice", "jonathan")
    cg2 = slice_cgroup()
    assert cg2, "slice cgroup did not come back after stop/start"
    ino2 = dellan.succeed(f"stat -c %i {cg2}").strip()
    print(f"[4] inode {ino1} -> {ino2}")
    assert ino1 != ino2, (
        "the recreated slice reused its inode, so this run cannot exercise the "
        "staleness path at all"
    )

    # Before rebinding: nft only prints a cgroup PATH when the stored
    # inode still resolves; a dead binding prints a bare integer. So the
    # path disappearing from the listing IS the stale state.
    stale_chain = nft_chain()
    print("[4] chain while stale:\n" + stale_chain)
    assert f'"{rel}"' not in stale_chain, (
        "the rule still resolves to the slice path after the cgroup was "
        f"recreated — this run is not testing staleness:\n{stale_chain}"
    )
    # And the stale rule really is dead, not merely cosmetic.
    pre_c = counter()
    dial_in_slice()
    assert counter() == pre_c, (
        "the stale rule still matched traffic, so a dead inode is not the "
        "failure mode this repair exists for"
    )

    run_bind()
    fixed_chain = nft_chain()
    print("[4] chain after rebind:\n" + fixed_chain)
    assert f'socket cgroupv2 level {level} "{rel}"' in fixed_chain, (
        f"bind unit did not repair the stale binding:\n{fixed_chain}"
    )
    st = state_file()
    assert st.get("inode") == ino2, (
        f"state file still records the dead inode: {st} (live {ino2})"
    )
    # Capture must actually resume — the counter reset with the flush, so
    # take a fresh baseline.
    pre_c, pre_l = counter(), log_count()
    dial_in_slice()
    assert counter() > pre_c and log_count() > pre_l, (
        "capture did not resume after the rebind"
    )

    # The wrong-level control rule was flushed away with the rebind;
    # re-add it so nothing below silently depends on chain shape.
    dellan.succeed(
        f'${nft} add rule inet claude_egress output socket cgroupv2 level 4 \\"{rel}\\" '
        'counter comment \\"wrong-level control\\"'
    )

    # ── 5. Launcher resolution ───────────────────────────────────────
    # F2: home/jonathan.nix prepends $HOME/.local/bin to PATH so the
    # self-updating native installer wins over the nixpkgs build. A
    # wrapper shipped in the home-manager profile sits behind it and is
    # never reached — and a VM test of such a wrapper passes green,
    # because no native installer exists in a VM. So the VM plants one.
    dellan.succeed(
        "mkdir -p /home/jonathan/.local/bin && "
        "printf '%s\\n' "
        "'#!/bin/sh' "
        "'{' "
        "'  echo \"argv: $*\"' "
        "'  echo \"exe: $0\"' "
        "'  echo \"cgroup: $(cat /proc/self/cgroup)\"' "
        "'} >> /home/jonathan/fake-claude.log' "
        "'exit 0' "
        "> /home/jonathan/.local/bin/claude && "
        "chmod 755 /home/jonathan/.local/bin/claude && "
        "touch /home/jonathan/fake-claude.log && "
        "chown -R jonathan:users /home/jonathan/.local /home/jonathan/fake-claude.log"
    )

    # The FIRST interactive zsh in a cold VM pays for compinit and the whole
    # rc chain before it runs anything: 77s on a green run, and then 124
    # (timeout) on the next one under a 120s cap. Warm it once outside any
    # assertion — after this the dump is cached and the calls below take
    # ~10s — and keep the cap far enough above the cold cost that a slow
    # runner cannot turn a passing gate red.
    dellan.succeed(
        f"timeout 600 su - jonathan -c '{RUNTIME} TERM=xterm zsh -ic true' || true"
    )

    def zsh(cmd, runtime=True):
        env = f"{RUNTIME} " if runtime else ""
        return dellan.succeed(
            f"timeout 300 su - jonathan -c \"{env}TERM=xterm zsh -ic '{cmd}'\" 2>&1"
        )

    def fake_log():
        return dellan.succeed("cat /home/jonathan/fake-claude.log")

    def clear_fake_log():
        dellan.succeed("truncate -s 0 /home/jonathan/fake-claude.log")

    # The function must shadow every PATH entry, and `whence -p` must
    # resolve the planted installer rather than the profile copy.
    resolution = zsh("whence -p claude; whence -w claude")
    print("[5] resolution:\n" + resolution)
    assert "/home/jonathan/.local/bin/claude" in resolution, (
        f"whence -p did not resolve the planted native installer:\n{resolution}"
    )
    assert "claude: function" in resolution, (
        f"claude is not a shell function in the interactive shell:\n{resolution}"
    )

    clear_fake_log()
    out = zsh("claude --version; echo STILL_ALIVE")
    log = fake_log()
    print("[5] claude() run:\n" + log)
    assert "argv: --continue --version" in log, (
        f"claude() did not pass --continue through to the real binary:\n{log}"
    )
    assert "exe: /home/jonathan/.local/bin/claude" in log, (
        "the binary that ran is not the planted native installer — the "
        f"launcher pinned something else:\n{log}"
    )
    assert "claude-egress.slice" in log, (
        f"the launched binary did not end up inside claude-egress.slice:\n{log}"
    )
    # The launcher must NOT exec: `exec` in an interactive zsh function
    # replaces the login shell, so quitting Claude Code would close the
    # terminal instead of returning to the prompt.
    assert "STILL_ALIVE" in out, (
        "the calling shell did not survive the launch — the launcher exec'd "
        f"and would close the user's terminal on quit:\n{out}"
    )

    # claudee: same placement, no --continue.
    clear_fake_log()
    zsh("claudee --version")
    log = fake_log()
    assert "argv: --version" in log and "--continue" not in log, (
        f"claudee must start a fresh session (no --continue):\n{log}"
    )
    assert "claude-egress.slice" in log, (
        f"claudee did not place the binary in the slice:\n{log}"
    )

    # ── --continue must not override an explicit session selection ────
    # `--continue` means "the most recent conversation in this directory"
    # and it WINS over `--resume <sid>`, so the wrapper's unconditional
    # prepend silently opened the wrong transcript. Real incident
    # (2026-09-04): two `claude --resume <sid>` calls both reattached to
    # the session already running, and pane-sessions.tsv ended up with
    # three kitty window ids mapped to one session id.
    #
    # The predicate is _claude_selects_session (home/jonathan.nix), called
    # by both this launcher and the jonathan.nix wrapper it shadows. Each
    # accepted argument SHAPE gets its own case, because the CLI accepts
    # more than `--resume <value>` — verified against claude 2.1.260:
    # `--resume=<sid>` (commander's --long=VALUE) and `-r<sid>` / `-cv`
    # (attached short values and clustered short booleans) all parse.
    SID = "11111111-2222-3333-4444-555555555555"

    def argv_case(cmd, want, forbid_continue, label):
        clear_fake_log()
        zsh(cmd)
        log = fake_log()
        print(f"[5] {label}:\n{log}")
        assert want in log, (
            f"{label}: `{cmd}` did not reach the binary as [{want}]:\n{log}"
        )
        if forbid_continue:
            assert "--continue" not in log, (
                f"{label}: the wrapper injected --continue over an explicit "
                f"session selection — `{cmd}` would open the WRONG "
                f"session:\n{log}"
            )
        # Whichever branch runs, the confinement is not optional.
        assert "claude-egress.slice" in log, (
            f"{label}: the binary escaped claude-egress.slice:\n{log}"
        )

    argv_case(
        f"claude --resume {SID} --version",
        f"argv: --resume {SID} --version",
        True, "--resume <sid> passthrough",
    )
    argv_case(
        f"claude --resume={SID} --version",
        f"argv: --resume={SID} --version",
        True, "--resume=<sid> passthrough",
    )
    argv_case(
        f"claude -r {SID} --version",
        f"argv: -r {SID} --version",
        True, "-r <sid> passthrough",
    )
    argv_case(
        "claude --session-id ABC --version",
        "argv: --session-id ABC --version",
        True, "--session-id passthrough",
    )
    argv_case(
        "claude --print hello",
        "argv: --print hello",
        True, "--print passthrough (non-interactive keeps its meaning)",
    )
    # Control 1: a flag that selects no session must STILL get --continue.
    # Without this, a wrapper that simply stopped injecting would pass
    # every case above and silently break the daily default.
    argv_case(
        "claude --model opus --version",
        "argv: --continue --model opus --version",
        False, "non-session flag still resumes",
    )
    # Control 2: `--` ends the option list, so a session-looking word
    # after it is prompt text and must not suppress the default.
    argv_case(
        "claude -- --resume x",
        "argv: --continue -- --resume x",
        False, "-- ends option scanning",
    )

    # ── --fork-session is a MODIFIER, not a session selector ──────────
    # `claude --help` (2.1.260): "When resuming, create a new session ID
    # instead of reusing the original (use with --resume or --continue)".
    # It cannot select a session on its own, so treating it as a selector
    # made bare `claude --fork-session` suppress --continue and silently
    # open a FRESH session — the fork workflow lost, the same class of
    # bug as the one the predicate exists to fix. Bare, it must expand to
    # `--continue --fork-session`: fork the most recent conversation.
    argv_case(
        "claude --fork-session --version",
        "argv: --continue --fork-session --version",
        False, "bare --fork-session forks the most recent session",
    )
    # …and combined with a real selector it must still not gain one.
    argv_case(
        f"claude --fork-session --resume {SID}",
        f"argv: --fork-session --resume {SID}",
        True, "--fork-session --resume <sid> passthrough",
    )
    argv_case(
        f"claude --fork-session -r {SID}",
        f"argv: --fork-session -r {SID}",
        True, "--fork-session -r <sid> passthrough",
    )
    # Control 3: `-f` has no short form in the CLI and is not in the
    # `-*[crp]*` class, so dropping --fork-session must not have shifted
    # the short-cluster catch-all either way.
    argv_case(
        "claude -f --version",
        "argv: --continue -f --version",
        False, "-f is not a session-selecting short cluster",
    )
    argv_case(
        "claude -fc --version",
        "argv: -fc --version",
        True, "a short cluster containing c still selects",
    )

    # Degradation path: with no user bus reachable the launcher must warn
    # and STILL start the tool. Observation degrades; the tool never
    # fails to start.
    clear_fake_log()
    out = dellan.succeed(
        "timeout 300 su - jonathan -c \"XDG_RUNTIME_DIR=/run/nonexistent "
        "TERM=xterm zsh -ic 'claude --version'\" 2>&1"
    )
    log = fake_log()
    print("[5] no-bus fallback:\n" + out + "\n---\n" + log)
    assert "claude-egress: UNOBSERVED" in out, (
        f"the launcher ran outside the slice without saying so:\n{out}"
    )
    assert "argv: --continue --version" in log, (
        f"the launcher failed to start the tool when the bus was gone:\n{log}"
    )
    assert "claude-egress.slice" not in log, (
        f"fallback claimed to be unobserved but landed in the slice anyway:\n{log}"
    )

    # ── XDG_RUNTIME_DIR must not leak into the caller ────────────────
    # The launcher has to default XDG_RUNTIME_DIR when the caller has none,
    # but a bare `export` sets it in the CALLING interactive shell, so every
    # later command in that terminal inherits a value the user never set —
    # and on the fallback path that value is a guess the launcher itself
    # just proved wrong. The probe lives in a file so no outer shell layer
    # can expand the variable before zsh sees it.
    # The brackets are the delimiters that make an empty value visible, and
    # they MUST be quoted: zsh globs an unquoted `[...]` and dies with
    # "no matches found" before printing anything.
    dellan.succeed(
        "cat > /run/leak-probe.zsh <<'PROBE'\n"
        "print -r -- \"BEFORE=[$XDG_RUNTIME_DIR]\"\n"
        "claude --version >/dev/null 2>&1\n"
        "print -r -- \"AFTER=[$XDG_RUNTIME_DIR]\"\n"
        "PROBE"
    )
    clear_fake_log()
    leak = dellan.succeed(
        "timeout 300 su - jonathan -c \"env -u XDG_RUNTIME_DIR TERM=xterm "
        "zsh -ic 'source /run/leak-probe.zsh'\" 2>&1"
    )
    log = fake_log()
    print("[5] runtime-dir leak probe:\n" + leak + "\n---\n" + log)
    assert "BEFORE=[]" in leak, (
        "the probe shell already carried XDG_RUNTIME_DIR, so a leak out of the "
        f"launcher could not be distinguished from the ambient value:\n{leak}"
    )
    assert "argv: --continue --version" in log, (
        f"the probe never actually invoked the launcher:\n{log}"
    )
    assert "AFTER=[]" in leak, (
        "_claude_slice exported XDG_RUNTIME_DIR into the calling shell; it must "
        f"scope the default to the function:\n{leak}"
    )

    # ── claude-egress-report ─────────────────────────────────────────
    # Three sections, run as the unprivileged user (which is who runs it).
    #
    # Reverse DNS cannot produce an allowlist — api.anthropic.com is
    # CDN-fronted and MagicDNS hides names — so the reporter joins
    # observed addresses against a FORWARD resolution of a candidate list
    # from this host. Both branches of that join have to be exercised, or
    # a reporter that files everything into one section passes.
    dial_in_slice(known_ip)

    # The snapshot half. Resolving only at report time is not enough: the
    # CDN-fronted candidates rotate addresses, so a destination observed on
    # Tuesday can resolve from nothing by Friday and get filed as unknown —
    # indistinguishable from the signal the report exists to surface.
    dellan.succeed("systemctl start claude-egress-resolve.service")
    snapshot = dellan.succeed("cat /var/lib/claude-egress/resolutions.tsv")
    print("[report] resolution snapshot:\n" + snapshot)
    assert f"{known_ip}\tapi.anthropic.com" in snapshot, (
        f"the resolve unit did not snapshot the candidate host:\n{snapshot}"
    )

    # Proof the reporter actually READS the snapshot rather than relying on
    # its own live resolution: plant a pair no live lookup can produce, and
    # dial that address. If the snapshot is ignored, it lands in section 2.
    snap_only_ip = "192.168.1.97"
    dellan.succeed(
        f"printf '%s\\t%s\\t%s\\n' {snap_only_ip} snapshot-only.invalid \"$(date +%s)\" "
        ">> /var/lib/claude-egress/resolutions.tsv"
    )
    dellan.fail("getent ahosts snapshot-only.invalid")
    dial_in_slice(snap_only_ip)

    # ── Aged-out pairs must stop matching ────────────────────────────
    # A pair with no expiry is a pair that is right forever. CDN and cloud
    # addresses get recycled to different operators, so a months-old row
    # keeps filing a NEW owner of that address as "matched" — silently
    # suppressing section 2, which exists to surface exactly that. Planted
    # with a 1970 timestamp so no plausible TTL can keep it alive.
    expired_ip = "192.168.1.96"
    dellan.succeed(
        f"printf '%s\\t%s\\t%s\\n' {expired_ip} expired.invalid 1 "
        ">> /var/lib/claude-egress/resolutions.tsv"
    )
    dial_in_slice(expired_ip)

    # The roll has to drop it too, or the file grows a permanent tail of
    # rows the reporter then has to keep re-ignoring.
    dellan.succeed("systemctl start claude-egress-resolve.service")
    rolled = dellan.succeed("cat /var/lib/claude-egress/resolutions.tsv")
    print("[report] snapshot after the roll:\n" + rolled)
    assert "expired.invalid" not in rolled, (
        "claude-egress-resolve kept an aged-out pair, so the snapshot never "
        f"forgets a recycled address:\n{rolled}"
    )
    assert "snapshot-only.invalid" in rolled, (
        "the roll dropped a pair that is still within its TTL — aging is "
        f"discarding live data:\n{rolled}"
    )
    assert f"{known_ip}\tapi.anthropic.com" in rolled, (
        f"the roll lost the freshly resolved candidate host:\n{rolled}"
    )

    report = dellan.succeed(
        "timeout 120 su - jonathan -c 'claude-egress-report \"-1 hour\"' 2>&1"
    )
    print("[report]\n" + report)
    for marker in [
        "== 1. matched",
        "== 2. unmatched",
        "== 3. health",
        "recorded state:  bound",
        "live check:      OK",
    ]:
        assert marker in report, (
            f"claude-egress-report is missing {marker!r}:\n{report}"
        )
    matched_section = report.split("== 1. matched")[1].split("== 2. unmatched")[0]
    unmatched_section = report.split("== 2. unmatched")[1].split("== 3. health")[0]
    health_section = report.split("== 3. health")[1]
    # The address that forward-resolves from a candidate name becomes a
    # phase-2 allowlist candidate, carrying the name it resolved from.
    assert known_ip in matched_section and "api.anthropic.com" in matched_section, (
        f"the reporter did not join {known_ip} back to its candidate name:\n{report}"
    )
    assert known_ip not in unmatched_section, (
        f"{known_ip} was filed as unmatched despite resolving:\n{report}"
    )
    # The address that resolves from nothing is the interesting signal.
    assert dial_ip in unmatched_section, (
        f"the observed unknown destination {dial_ip} is not reported as "
        f"unmatched:\n{report}"
    )
    assert dial_ip not in matched_section, (
        f"{dial_ip} matches no candidate name but was filed as matched:\n{report}"
    )
    # Only the rolling snapshot can explain this one.
    assert (
        snap_only_ip in matched_section
        and "snapshot-only.invalid" in matched_section
    ), (
        "the reporter ignored the rolling resolution snapshot and joined only "
        f"against a live lookup:\n{report}"
    )
    # And the aged-out pair must fall through to section 2 — the signal the
    # report exists to surface — rather than be silently absorbed by a row
    # that stopped being true months ago.
    assert expired_ip in unmatched_section, (
        f"{expired_ip} was joined off an expired snapshot row instead of "
        f"being reported as an unknown destination:\n{report}"
    )
    assert expired_ip not in matched_section and "expired.invalid" not in report, (
        f"the reporter honoured an aged-out resolution pair:\n{report}"
    )
    assert "resolution snapshot:" in health_section and (
        "MISSING" not in health_section
    ), (
        f"health does not report the state of the resolution snapshot:\n{report}"
    )
    # The health section's "|| echo unknown" trap: `systemctl is-active`
    # prints the state AND exits non-zero for every non-active state, so
    # a naive fallback appends a stray line instead of substituting one.
    assert "unknown" not in health_section, (
        f"health section contains a stray fallback line:\n{health_section}"
    )
    # Run as root the same report must additionally show the live rule —
    # the branch the unprivileged run cannot reach.
    root_report = dellan.succeed("claude-egress-report '-1 hour' 2>&1")
    assert "socket cgroupv2" in root_report, (
        f"the privileged report does not show the live rule:\n{root_report}"
    )

    # ── 6. Firewall untouched ────────────────────────────────────────
    # The host firewall stays on the iptables backend. Flipping the
    # backend on a machine running docker, libvirt and tailscale is not
    # risk this change takes; the module carries an eval-time assertion
    # against networking.nftables.enable, and this is its runtime half.
    fw = dellan.succeed("systemctl is-active firewall.service").strip()
    assert fw == "active", f"firewall.service is not active: {fw!r}"
    nftsvc = dellan.succeed(
        "systemctl is-active nftables.service || true"
    ).strip()
    assert nftsvc != "active", (
        f"nftables.service is active — the firewall backend was flipped: {nftsvc!r}"
    )
    # Our chain must be observe-only: accept policy, no blocking verdict.
    chain = nft_chain()
    assert "policy accept" in chain, f"claude_egress chain is not accept-policy:\n{chain}"
    for banned in [" drop", "reject", "policy drop"]:
        assert banned not in chain, (
            f"phase 1 must log and never block, but the chain contains {banned!r}:\n{chain}"
        )
    # And outbound connectivity genuinely works through the hook.
    dellan.succeed(
        f"timeout 5 ${bash} -c 'exec 3<>/dev/tcp/{node_ip}/22'"
    )

    # ── 3. Boot with the slice absent ────────────────────────────────
    # F1's first half. Done last because it reboots the machine.
    #
    # First the negative control that makes the design decision
    # meaningful: a ruleset that DOES name a cgroup fails to load
    # outright when that cgroup is absent. Had the table shipped with the
    # cgroup rule baked in, this is what boot would have done.
    dellan.succeed(
        "printf '%s\\n' "
        "'table inet probe_absent {' "
        "'  chain output {' "
        "'    type filter hook output priority 0; policy accept;' "
        "'    socket cgroupv2 level 4 \"user.slice/nope-does-not-exist.slice\" counter' "
        "'  }' "
        "'}' > /run/absent.nft"
    )
    absent_err = dellan.fail("${nft} -f /run/absent.nft 2>&1")
    assert "cgroupv2 path fails" in absent_err, (
        "a ruleset naming an absent cgroup was expected to fail to load; got:\n"
        f"{absent_err}"
    )
    # The shipped ruleset must therefore contain no cgroup match at all.
    table_unit = dellan.succeed("systemctl cat claude-egress-table.service")
    ruleset_path = re.search(r"ExecStart=\S*/nft -f (\S+)", table_unit).group(1)
    shipped = dellan.succeed(f"cat {ruleset_path}")
    print("[3] shipped ruleset:\n" + shipped)
    assert "cgroupv2" not in shipped, (
        "the boot-time ruleset names a cgroup, so boot fails whenever the slice "
        f"has not been started:\n{shipped}"
    )

    # Now prove it for real: mask the slice so it can never start, REBOOT,
    # and check the machine comes up healthy with nothing to bind to.
    #
    # `systemctl --user mask` cannot be used: home-manager already owns
    # ~/.config/systemd/user/claude-egress.slice, so masking there refuses
    # ("already exists and is a symlink to /nix/store/...-home-manager-files").
    # ~/.config/systemd/user.control sits ABOVE that directory in the user
    # manager's load path (systemd.unit(5), "Load path when running in user
    # mode") and home-manager does not manage it, so a /dev/null symlink
    # there is a mask that both wins and survives the reboot.
    dellan.succeed(
        "mkdir -p /home/jonathan/.config/systemd/user.control && "
        "ln -sf /dev/null "
        "/home/jonathan/.config/systemd/user.control/claude-egress.slice && "
        "chown -R jonathan:users /home/jonathan/.config/systemd/user.control"
    )
    dellan.shutdown()
    dellan.start()
    dellan.wait_for_unit("multi-user.target")
    dellan.wait_for_unit("claude-egress-table.service")
    dellan.wait_for_unit("default.target", "jonathan")
    dellan.succeed("systemctl stop claude-egress-bind.timer")

    masked = dellan.succeed(
        f"su - jonathan -c '{RUNTIME} systemctl --user is-enabled "
        "claude-egress.slice' || true"
    ).strip()
    assert masked == "masked", (
        f"the slice is not masked after reboot (is-enabled={masked!r}) — this "
        "run is not testing the absent case"
    )
    assert slice_cgroup() == "", (
        "the slice started despite being masked — this reboot is not testing "
        "the absent case"
    )
    tbl = dellan.succeed("systemctl is-active claude-egress-table.service").strip()
    assert tbl == "active", (
        f"claude-egress-table.service failed to load with the slice absent: {tbl!r}"
    )
    # The bind unit must treat an unlaunched slice as a no-op, not a fault.
    run_bind()
    bind_state = dellan.succeed(
        "systemctl is-failed claude-egress-bind.service || true"
    ).strip()
    assert bind_state != "failed", (
        f"claude-egress-bind.service failed on the absent slice: {bind_state!r}"
    )
    st = state_file()
    assert st.get("state") == "absent", (
        f"bind unit did not record the slice as absent: {st}"
    )
    assert "cgroupv2" not in nft_chain(), (
        f"a cgroup rule is bound although no slice exists:\n{nft_chain()}"
    )
    # The report has to survive — and be honest about — exactly this state.
    # "Nothing is being observed" is the single most important thing it can
    # say, and it is the state its health section is least exercised in.
    absent_report = dellan.succeed(
        "timeout 120 su - jonathan -c 'claude-egress-report \"-1 hour\"' 2>&1"
    )
    print("[3] report with the slice absent:\n" + absent_report)
    assert "recorded state:  absent" in absent_report, (
        f"the report does not say the slice is absent:\n{absent_report}"
    )
    assert "nothing is being observed" in absent_report, (
        "the report must say plainly that nothing is being observed, not "
        f"merely omit a section:\n{absent_report}"
    )
    # It must not invent a stale-binding diagnosis out of an empty path.
    assert "STALE" not in absent_report, (
        f"absent was misreported as a stale binding:\n{absent_report}"
    )

    # ── Observations must survive the reboot ─────────────────────────
    # `journalctl -k` implies `-b`, so a reporter that uses it silently
    # truncates its window at the last boot however long a window was
    # asked for — and the phase-2 allowlist is then built from whatever
    # happened since the machine last came up, with nothing in the output
    # saying so. Every address below was dialled BEFORE the reboot above,
    # inside the one-hour window this report was given.
    print("[3] cross-boot window check, dialled pre-reboot: "
          f"{dial_ip} {known_ip} {snap_only_ip}")
    assert dial_ip in absent_report, (
        "the report lost every observation made before the reboot — its "
        "journal query is capped at the current boot, so the phase-2 "
        f"allowlist under-reports with no visible sign:\n{absent_report}"
    )
    assert known_ip in absent_report and snap_only_ip in absent_report, (
        "only part of the pre-reboot observation window survived:\n"
        f"{absent_report}"
    )
    # The join has to survive it too — /var/lib, not /run, for this reason.
    assert "api.anthropic.com" in absent_report, (
        "the resolution snapshot did not survive the reboot, so pre-reboot "
        f"observations come back nameless:\n{absent_report}"
    )
    # Networking must be unaffected.
    node_ip = dellan.succeed(
        "ip -4 -o addr show dev eth1 | grep -o 'inet [0-9.]*' | cut -d' ' -f2"
    ).strip()
    dellan.succeed(f"timeout 5 ${bash} -c 'exec 3<>/dev/tcp/{node_ip}/22'")
    fw = dellan.succeed("systemctl is-active firewall.service").strip()
    assert fw == "active", f"firewall.service not active after reboot: {fw!r}"

    # home-manager-jonathan.service fails on this boot, and that is the
    # MASK's doing, not the module's: HM activation starts the user units
    # it manages, and starting a masked unit is an error. Recorded here
    # rather than left as an unexplained red unit for the next reader —
    # and proven to be the cause by unmasking and re-running activation
    # clean below.
    hm_after_mask = dellan.succeed(
        "systemctl is-failed home-manager-jonathan.service || true"
    ).strip()
    print(f"[3] home-manager while the slice is masked: {hm_after_mask}")

    # Leave the machine in the shipped state.
    dellan.succeed(
        "rm -f /home/jonathan/.config/systemd/user.control/claude-egress.slice"
    )
    user_systemctl("daemon-reload")
    user_systemctl("start claude-egress.slice")
    dellan.wait_for_unit("claude-egress.slice", "jonathan")
    dellan.succeed("systemctl reset-failed home-manager-jonathan.service || true")
    dellan.succeed("systemctl start home-manager-jonathan.service")
    hm_clean = dellan.succeed(
        "systemctl is-failed home-manager-jonathan.service || true"
    ).strip()
    assert hm_clean != "failed", (
        "home-manager activation still fails with the slice unmasked, so the "
        f"failure above was NOT the test's mask: {hm_clean!r}"
    )
    run_bind()
    assert "cgroupv2" in nft_chain(), (
        f"the binding did not come back after unmasking:\n{nft_chain()}"
    )
  '';
}
