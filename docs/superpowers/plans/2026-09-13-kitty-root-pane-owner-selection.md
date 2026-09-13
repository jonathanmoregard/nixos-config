# Kitty Root-Pane Owner Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (default) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore pane's root interactive agent when background headless agents share its Kitty PTY.

**Architecture:** Tighten shared Claude/Codex classifier so headless Claude modes are not interactive-pane candidates, then route converter, restore, and enricher through one stable-command/exact-kind/unique-kind selector. Prove behavior first with deterministic fixtures, then with live Kitty discovery and complete save-kill-restore-save cycle.

**Tech Stack:** Nix/Home Manager, embedded Python 3, Kitty remote control, NixOS VM tests, real X11 Kitty session restore.

---

## File map

- `home/kitty.nix`: shared agent classification and pane-owner selection used by snapshot enrichment, session conversion, and restore planning.
- `tests/kitty-scripts.nix`: fast generated-script regression for headless Claude exclusion, exact mixed-agent restore, and ambiguous fallback.
- `tests/claude-pane.nix`: VM regression proving typed Codex registry row enriches correct process when headless Claude appears first.
- `tests/kitty.nix`: real-X process-tree and save-kill-restore-save E2E.
- `docs/superpowers/specs/2026-09-13-kitty-root-pane-owner-selection-design.md`: behavior contract and captured production evidence.

### Task 1: Add fast failing owner-selection regressions

**Files:**
- Modify: `tests/kitty-scripts.nix:350-410`
- Modify: `tests/kitty-scripts.nix:1230-1290`
- Test: `tests/kitty-scripts.nix`

- [x] **Step 1: Add exact mixed-agent fixtures**

Extend existing JSON fixture generator with these windows:

```python
mixed_root = win(41, ["/usr/bin/codex", "resume", CODEX_SID])
mixed_root["codex_session_id"] = CODEX_SID
mixed_root["foreground_processes"] = [
    {"pid": 4101, "cmdline": [
        "/usr/bin/claude", "--model", "haiku", "--max-turns", "20",
        "--print", "score proposals",
    ]},
    {"pid": 4102, "cmdline": [
        "/usr/bin/codex", "resume", CODEX_SID,
    ]},
]

mixed_shell = win(42, ["/bin/zsh"])
mixed_shell["codex_session_id"] = CODEX_SID
mixed_shell["foreground_processes"] = mixed_root["foreground_processes"]

headless_modes = {
    "claude-print-short": ["/usr/bin/claude", "-p", "score"],
    "claude-print-long": ["/usr/bin/claude", "--print", "score"],
    "claude-bg-short": ["/usr/bin/claude", "--bg", "score"],
    "claude-bg-long": ["/usr/bin/claude", "--background", "score"],
}

mixed_ambiguous = win(43, ["/bin/zsh"])
mixed_ambiguous["foreground_processes"] = [
    {"pid": 4301, "cmdline": ["/usr/bin/claude", "--resume", CLAUDE_SID]},
    {"pid": 4302, "cmdline": ["/usr/bin/codex", "resume", CODEX_SID]},
]

cases["mixed-root"] = tab([mixed_root])
cases["mixed-shell"] = tab([mixed_shell])
cases["mixed-ambiguous"] = tab([mixed_ambiguous])
for index, (label, argv) in enumerate(headless_modes.items(), start=44):
    headless = win(index, argv)
    headless["foreground_processes"] = [{"pid": 4400 + index, "cmdline": argv}]
    cases[label] = tab([headless])
```

Use existing `CODEX_SID` fixture constant or define it once as
`cccc3333-cccc-4333-8333-cccccccccccc` beside `codex_with_id`.

- [x] **Step 2: Assert converter and restore outcomes**

For `mixed-root` and `mixed-shell`, run both production scripts and require
canonical root UUID:

```bash
for label in mixed-root mixed-shell; do
  SHELL=/bin/sh kitty-session-convert < "grid/$label.json" \
    > "state/$label.session"
  grep -qF \
    '/usr/bin/codex resume cccc3333-cccc-4333-8333-cccccccccccc' \
    "state/$label.session"

  rm -rf "state/cache-$label"
  mkdir -p "state/cache-$label/kitty-session"
  cp "grid/$label.json" "state/cache-$label/kitty-session/snapshot.json"
  XDG_CACHE_HOME="$PWD/state/cache-$label" \
    kitty-restore-session --dump-panes > "state/$label.panes.json"
  jq -e --arg sid 'cccc3333-cccc-4333-8333-cccccccccccc' \
    '.[0].agent_kind == "codex" and .[0].cmd == ["/usr/bin/codex", "resume", $sid]' \
    "state/$label.panes.json" >/dev/null
done

for label in mixed-ambiguous claude-print-short claude-print-long \
  claude-bg-short claude-bg-long; do
  SHELL=/bin/sh kitty-session-convert < "grid/$label.json" \
    > "state/$label.session"
  grep -qF '/bin/sh' "state/$label.session"
done
```

Also assert `--print` and `haiku` occur in neither converted output nor
dumped restore commands.

- [x] **Step 3: Run fast check and observe RED**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.kitty-scripts -L
```

Expected: FAIL because current `pane_cmd` selects first
`claude --print` candidate instead of canonical Codex or safe shell.

- [x] **Step 4: Commit RED checkpoint**

```bash
git add tests/kitty-scripts.nix
git diff --cached --check
git commit -m "test: reproduce kitty background-agent restore"
```

### Task 2: Add failing enrichment and real-X regressions

**Files:**
- Modify: `tests/claude-pane.nix:90-115`
- Modify: `tests/claude-pane.nix:340-410`
- Modify: `tests/kitty.nix:125-165`
- Modify: `tests/kitty.nix:400-500`
- Test: `tests/claude-pane.nix`
- Test: `tests/kitty.nix`

- [x] **Step 1: Add mixed-process enrichment fixture**

Add separate typed registry and synthetic live window so existing registry
fixtures stay independent:

```python
sid_mixed = "eeee5555-eeee-4555-8555-eeeeeeeeeeee"
wid_mixed = 105
stage_input(
    "/tmp/mixed-agent.tsv",
    f"{wid_mixed}\tcodex\t{sid_mixed}\t/tmp/mixed\t0",
)
mixed_ls = json.dumps([{"tabs": [{"windows": [{
    "id": wid_mixed,
    "cwd": "/tmp/mixed",
    "title": "mixed-agent",
    "cmdline": ["/bin/zsh"],
    "foreground_processes": [
        {"pid": 1001, "cmdline": [
            "/usr/bin/claude", "--model", "haiku", "--print", "score",
        ]},
        {"pid": 1002, "cmdline": [
            "/usr/bin/codex", "resume", sid_mixed,
        ]},
    ],
}]}]}])
stage_input("/tmp/mixed-agent.json", mixed_ls)
dellan.succeed(
    "su - jonathan -c 'KITTY_ENRICH_TEST=1 "
    "KITTY_ENRICH_TSV=/tmp/mixed-agent.tsv kitty-session-enrich "
    "< /tmp/mixed-agent.json > /tmp/mixed-agent-enriched.json'"
)
mixed_window = json.loads(dellan.succeed(
    "cat /tmp/mixed-agent-enriched.json"
))[0]["tabs"][0]["windows"][0]
assert mixed_window.get("codex_session_id") == sid_mixed
assert "claude_session_id" not in mixed_window
```

Add headless-only Claude control with typed Claude row and assert neither
session field is attached.

- [x] **Step 2: Build enrichment lane and observe RED**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.vm-claude-pane -L
```

Expected: FAIL at `codex_session_id` because current enricher classifies first
headless Claude process and rejects typed Codex row.

- [x] **Step 3: Create live mixed-agent test processes**

Add real long-lived Claude executable and launcher that starts it before root
Codex child:

```nix
testClaude = pkgs.writeCBin "claude" ''
  #include <signal.h>
  #include <unistd.h>
  int main(void) { for (;;) pause(); }
'';

testMixedAgentPane = pkgs.writeShellScriptBin "mixed-agent-pane" ''
  set -eu
  ${testClaude}/bin/claude --model haiku --max-turns 20 --print score &
  claude_pid=$!
  trap 'kill "$claude_pid" 2>/dev/null || true' EXIT
  ${testCodex}/bin/codex resume "$1"
'';
```

Replace direct Codex pane launch with:

```python
dellan.succeed(
    "su jonathan -c "
    f"'kitty-pane-add --cwd /etc -- "
    "${testMixedAgentPane}/bin/mixed-agent-pane "
    f"{codex_sid}'"
)
```

Before writing `pane-sessions.tsv`, capture live `kitty @ ls` and assert one
window contains exact Claude and Codex argv, with Claude candidate occurring
earlier in reported array. Keep registry lookup keyed to exact Codex argv.
After `kitty-session-save`, assert that window has
`codex_session_id == codex_sid` and no `claude_session_id`. Existing kill,
wrapper restore, guard, exact foreground Codex, and subsequent-save assertions
remain unchanged.

- [x] **Step 4: Build real-X lane and observe RED**

Run:

```bash
nix build --no-link .#checks.x86_64-linux.vm-kitty -L
```

Expected: FAIL immediately after save because current enrichment picks earlier
headless Claude process and drops typed Codex identity.

- [x] **Step 5: Commit remaining RED tests**

```bash
git add tests/claude-pane.nix tests/kitty.nix
git diff --cached --check
git commit -m "test: cover mixed-agent kitty restore end to end"
```

### Task 3: Implement shared interactive owner selection

**Files:**
- Modify: `home/kitty.nix:373-530`
- Modify: `home/kitty.nix:575-620`
- Modify: `home/kitty.nix:2240-2320`
- Modify: `home/kitty.nix:4230-4290`
- Test: `tests/kitty-scripts.nix`
- Test: `tests/claude-pane.nix`

- [x] **Step 1: Tighten shared Claude classification**

Add beside current executable classifiers:

```python
CLAUDE_NONINTERACTIVE_FLAGS = {
    "-p", "--print", "--bg", "--background",
}


def _is_claude_exe_interactive(cmdline):
    """True only for a Claude conversation that owns terminal."""
    return _is_claude_exe(cmdline) and not any(
        arg in CLAUDE_NONINTERACTIVE_FLAGS for arg in cmdline[1:]
    )


def _is_agent_executable(cmdline):
    inner = unwrap_launchers(cmdline)
    return _is_claude_exe(inner) or _is_codex_exe(inner)
```

Change `_agent_kind()` to use `_is_claude_exe_interactive(inner)` for
Claude. Keep `_is_claude()` unchanged because slice wrapping and exact-Claude
recovery still need to recognize canonical Claude argv.

- [x] **Step 2: Add one shared selector**

Add below `_agent_kind()`:

```python
def select_pane_agent(win, expected_kind=None):
    """Return (kind, argv) for pane owner, or (None, None)."""
    stable = unwrap_pane0(win.get("cmdline") or [])
    stable_kind = _agent_kind(stable)
    if stable_kind:
        return stable_kind, stable

    candidates = []
    for process in win.get("foreground_processes") or []:
        argv = process.get("cmdline") or []
        kind = _agent_kind(argv)
        if kind:
            candidates.append((kind, argv))

    if expected_kind in {"claude", "codex"}:
        for kind, argv in candidates:
            if kind == expected_kind:
                return kind, argv
        return None, None

    if len({kind for kind, _argv in candidates}) == 1 and candidates:
        return candidates[0]
    return None, None
```

Add shared `_snapshot_agent_kind(win)` returning `claude` or `codex` only
when exactly one corresponding `*_session_id` is a string accepted by
`UUID_RE.fullmatch`; both-or-neither returns `None`.

- [x] **Step 3: Route converter and restore through selector**

Replace both duplicated foreground loops with:

```python
kind, cmdline = select_pane_agent(win, _snapshot_agent_kind(win))
if cmdline:
    if kind == "claude":
        sid = win.get("claude_session_id")
        if isinstance(sid, str) and UUID_RE.fullmatch(sid):
            return [unwrap_launchers(cmdline)[0], "--resume", sid]
        return cmdline
    if kind == "codex":
        sid = win.get("codex_session_id")
        if isinstance(sid, str) and UUID_RE.fullmatch(sid):
            return [unwrap_launchers(cmdline)[0], "resume", sid]
        return clean_user_shell()
```

For remaining fallback, return stable `window.cmdline` or
`foreground_processes[0]` only when `_is_agent_executable()` is false;
otherwise return `clean_user_shell()`. Define same two-line
`clean_user_shell()` in restore that converter already has. In
`load_panes()`, change safe-shell derivation to accept `wc` only when
`not _is_agent_executable(wc)`, preventing rejected headless agent argv from
becoming fallback shell.

- [x] **Step 4: Route enrichment through selector**

Move TSV lookup before classification and use typed kind as expected kind:

```python
entry = tsv.get(wid) if isinstance(wid, int) else None
expected_kind = entry[0] if entry is not None else None
kind, _cmdline = select_pane_agent(win, expected_kind)
if kind is None:
    continue
sid = None
if entry is not None:
    row_kind, row_sid = entry
    if row_kind is None or row_kind == kind:
        sid = row_sid
```

Delete old first-agent loop and separate `_is_claude(window.cmdline)` arm;
selector's stable-command branch subsumes Claude zombie recovery.

- [x] **Step 5: Run cheap checks**

Run:

```bash
git diff --check
nix eval --no-warn-dirty .#checks.x86_64-linux.vm-kitty.drvPath
nix build --no-link --print-out-paths \
  .#nixosConfigurations.dellan.config.home-manager.users.jonathan.home.path
nix build --no-link .#checks.x86_64-linux.kitty-scripts -L
```

Expected: all exit 0; generated Python lint and shell checks pass; fast mixed
fixtures select exact Codex or safe shell.

- [x] **Step 6: Run deterministic VM enrichment gate**

```bash
nix build --no-link .#checks.x86_64-linux.vm-claude-pane -L
```

Expected: PASS, including mixed typed-row and headless-only controls.

- [x] **Step 7: Commit implementation**

```bash
git add home/kitty.nix
git diff --cached --check
git commit -m "fix: restore kitty pane root agent"
```

### Task 4: Prove real restore behavior and ship

**Files:**
- Update: `docs/superpowers/plans/2026-09-13-kitty-root-pane-owner-selection.md`

- [x] **Step 1: Run full real-X automated E2E**

```bash
nix build --no-link .#checks.x86_64-linux.vm-kitty -L
```

Expected: PASS after live `kitty @ ls` proves both processes share one pane,
save retains exact Codex identity, cold restore launches exact
`codex resume <UUID>`, guard clears, and next save retains same UUID.

- [x] **Step 2: Run interactive feature-VM smoke**

Start headless feature VM:

```bash
nix run .#feature-vm
```

From another shell, drive deployed scripts inside VM with observed mixed
process shape:

```bash
ssh_opts=(-p 2222 -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null -i ~/.ssh/id_ed25519)
ssh "${ssh_opts[@]}" jonathan@localhost 'set -eu
sid=eeee5555-eeee-4555-8555-eeeeeeeeeeee
tsv=$(mktemp)
cache=$(mktemp -d)
printf "105\tcodex\t%s\t/tmp/mixed\t0\n" "$sid" > "$tsv"
payload=$(printf '\''[{"tabs":[{"windows":[{"id":105,"cwd":"/tmp/mixed","cmdline":["/bin/zsh"],"foreground_processes":[{"pid":1001,"cmdline":["/usr/bin/claude","--model","haiku","--print","score"]},{"pid":1002,"cmdline":["/usr/bin/codex","resume","%s"]}]}]}]}]'\'' "$sid")
printf %s "$payload" | env KITTY_ENRICH_TEST=1 KITTY_ENRICH_TSV="$tsv" \
  kitty-session-enrich > /tmp/mixed-enriched.json
jq -e --arg sid "$sid" '\''.[0].tabs[0].windows[0] | .codex_session_id == $sid and (has("claude_session_id") | not)'\'' \
  /tmp/mixed-enriched.json
mkdir -p "$cache/kitty-session"
cp /tmp/mixed-enriched.json "$cache/kitty-session/snapshot.json"
XDG_CACHE_HOME="$cache" kitty-restore-session --dump-panes \
  > /tmp/mixed-panes.json
jq -e --arg sid "$sid" '\''.[0].agent_kind == "codex" and .[0].cmd == ["/usr/bin/codex", "resume", $sid]'\'' \
  /tmp/mixed-panes.json
printf %s "$payload" | SHELL=/bin/sh kitty-session-convert \
  > /tmp/mixed.session
! grep -Eq -- "--print|haiku" /tmp/mixed.session
rm -f "$tsv"
rm -rf "$cache"'
```

Capture output proving:

```text
input: headless Claude precedes root Codex
enriched snapshot: codex_session_id equals eeee5555-eeee-4555-8555-eeeeeeeeeeee
restore plan: argv equals codex resume eeee5555-eeee-4555-8555-eeeeeeeeeeee
session conversion: no --print or haiku argv survives
```

Stop VM with Ctrl-C after proof capture. Any manual-smoke discrepancy becomes
new failing automated assertion before changing implementation.

- [x] **Step 3: Run review and final verification**

Invoke `advice-refine-test-loop`, reproduce every finding, fix confirmed
issues, and rerun affected cheap plus VM gates. Then invoke
`verification-before-completion` and record fresh command output.

Recorded 2026-09-13:

- Deterministic close-out gate: exit 0, no findings, gitleaks clean.
- Fresh read-only close-out reviewer: PASS, zero material findings.
- Fast generated-script gate: PASS.
- Deterministic enrichment/restore VM: PASS.
- Real-X Kitty E2E: PASS; live process order was headless Haiku before root
  Codex, first save retained only exact Codex UUID, cold relaunch restored
  exact `codex resume <UUID>`, restore guard cleared, second save retained
  same UUID.
- Interactive feature VM: PASS against installed scripts; enrichment selected
  Codex, restore planned exact UUID, conversion emitted clean shell and no
  `--print`/Haiku argv.

- [x] **Step 4: Commit plan completion and push**

Mark completed checkboxes, then:

```bash
git add docs/superpowers/plans/2026-09-13-kitty-root-pane-owner-selection.md
git diff --cached --check
git commit -m "docs: record kitty restore verification"
git push -u origin fix/kitty-root-pane-restore
```

- [ ] **Step 5: Open PR and monitor CI**

Open PR against `main`. PR body must include root-cause evidence, exact local
gate commands, real-X output summary, interactive feature-VM proof, risk level,
rollback with exact implementation commit hash, and
`feature-vm.nix modified: no`. Monitor required checks to terminal state. Do
not merge; user clicks merge.
