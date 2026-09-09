# Codex-aware Kitty restore with manual pickup

## Goal

Restore interactive Codex panes to their recorded threads alongside existing
Claude Code panes. A restored agent must receive no automatically submitted
user prompt. Instead, Kitty leaves a short pickup draft in the input buffer;
the user can submit it or erase it before the agent does any new work.

## Current behavior and root cause

The deployed Kitty snapshot service is healthy. The initial classification and
resume-planning changes correctly launch a recorded Codex pane with the exact
argv `codex resume <UUID>`. The new process also receives the intended
`KITTY_WINDOW_ID`, `KITTY_LISTEN_ON`, and `KITTY_RESTORE_NOTE` values.

A live restore smoke exposed a later bootstrap gap. Before any user input,
Codex 0.146 emits no SessionStart hook event and does not update its transcript.
The `pane-sessions.tsv` map therefore remains Claude-only, the Codex note marker
remains `.pending`, and the Codex input buffer remains blank. The next periodic
save then overwrites the restored snapshot without `codex_session_id`, so a
second restart can no longer construct the exact resume command. Waiting for
the hook is circular: the manual pickup draft is meant to precede the first
user turn, but the observed Codex process produces no hook before that
boundary.

The same smoke confirms that the Claude path works: it resumes the exact
recorded session, shows the pickup draft without submitting it, and creates no
transcript turn. The correction therefore belongs in the restored Codex
bootstrap, not in the common resume command or the established Claude flow.

## Design

### Agent identity in the snapshot

Keep the existing `claude-kitty-pane-record` executable name so the already
deployed Claude and mirrored Codex hooks remain compatible. Generalize its
record to include an agent kind:

```text
kitty_window_id<TAB>agent_kind<TAB>session_id<TAB>cwd<TAB>timestamp
```

The hook records `codex` only when `/proc` ancestry proves the hook descends
from an interactive Codex CLI and `transcript_path` has the expected
`~/.codex/sessions/*.jsonl` shape. This is necessary because real Codex
SessionStart hooks do not receive `CODEX_THREAD_ID`, while `codex exec` fires
the same hook and must not overwrite the interactive pane row. Known one-shot
and service subcommands are rejected; root, positional-prompt, `resume`, and
`fork` invocations are interactive. Otherwise the recorder applies Claude's
existing entrypoint gate. The parser continues accepting old four-column rows;
the live foreground process disambiguates their agent kind.

SessionStart remains the normal authority for ordinary agent starts and for
Claude restore. A restored Codex pane is the one exception: the restore
launcher already owns the exact UUID selected from that pane's snapshot and
learns the newly launched Kitty window ID, so it writes the initial typed Codex
row itself. If Codex later emits a real hook event, the recorder replaces that
same row by window-ID key rather than creating a competing mapping.

The enricher recognizes interactive `claude` and `codex` processes anywhere in
`foreground_processes`, while continuing to ignore Kitty UI windows and
noninteractive child processes. It writes one of two explicit fields:

- `claude_session_id`
- `codex_session_id`

Keeping the existing Claude field makes old snapshots and the existing restore
tests backward compatible. Same-directory collision protection is evaluated
per agent kind so two Codex panes in one checkout cannot collapse onto one
thread.

### Resume planning

`pane_cmd` treats a foreground Codex TUI as a restorable agent, with the same
precedence that foreground Claude currently has over Kitty's original shell
command. The restore planner emits canonical commands:

```text
claude --resume <session-id>
codex resume <thread-id>
```

The local Codex CLI confirms that `codex resume <SESSION_ID>` is the supported
non-picker form. Restore does not replay a positional prompt or one-shot CLI
overrides from an earlier invocation. That matches the current Claude behavior
and avoids silently replaying either user input or unsafe launch flags.

An old snapshot containing only `claude_session_id` follows the current Claude
path unchanged. A Codex pane without a valid recorded thread degrades to the
original shell rather than guessing the latest thread and risking a collision.

### Recovery generation and notes

Each cold restore creates a random 128-bit generation token and stages the
complete recovery state beneath the fixed root:

```text
~/.local/state/claude/kitty-restore/
  current
  generation-<token>/
    manifest.json
    pane-<ordinal>.md
    pane-<ordinal>.md.pending
    pane-<ordinal>.expected-window
    pane-<ordinal>.bootstrap-{bound,failed}
```

The root and generation directories are mode `0700`; the manifest, notes, and
markers are mode `0600`. The manifest binds each ordinal to its agent kind,
recorded UUID, cwd, note path, and canonical resume argv. The existing
cold-start `restore.lock` covers reconciliation, generation creation, and
retention: the launcher builds a hidden temporary generation directory, renames
it into place, and atomically replaces the mode-`0600` `current` file only after
the manifest and every note are complete.

At cold-start entry, while holding that lock, the launcher first reconciles any
retained `.sending` markers to `.uncertain`. It keeps only the new active
generation and at most the immediately previous generation for diagnosis, and
removes older generations, abandoned temporary directories, and legacy loose
`pane-*.md*` files. A previous generation is never eligible for delivery. Thus
a topology shrink creates an active manifest containing only the new ordinals;
obsolete notes, bootstrap receipts, and every marker state rotate out under a
fixed two-generation cap instead of accumulating.

Claude notes retain the useful existing detail about interrupted subagents,
dirty worktrees, and surviving detached units. Codex notes state that the prior
process and its in-process workers ended, include the recorded working
directory and current Git summary when available, and tell the resumed agent to
verify filesystem and process state before continuing. Notes never live in a
project checkout or become part of a Git diff.

The launch environment carries the exact note path as `KITTY_RESTORE_NOTE`, the
generation token as `KITTY_RESTORE_BOOTSTRAP`, and the manifest ordinal as
`KITTY_RESTORE_ORDINAL`. The parent computes one monotonic deadline for the
whole restore and carries it in the manifest and bootstrap environment as
`KITTY_RESTORE_DEADLINE_MONOTONIC`. Its production timeout is the existing
30-second socket-startup budget; the test-only
`KITTY_RESTORE_TIMEOUT_SECONDS` override may shorten it. Resume commands contain
no prompt. Passing the note path through the pane environment avoids depending
on a resumed runtime preserving the requested session UUID. Claude may assign
a new SessionStart ID while resuming an older conversation, so matching a note
by session ID would be unreliable.

### Authoritative restored-pane binding

The shared registry writer atomically replaces a window-ID row while holding
the existing pane-session lock. For every restored Codex pane, registry binding
happens as soon as the new window ID is authoritative and before any subsequent
`kitty @ ls` target check or other draft-delivery preflight. A preflight or
delivery failure never rolls that row back, so the exact UUID survives every
delivery outcome and remains available to the next autosave.

Every restored Codex pane launches an in-pane bootstrap wrapper, never
`codex resume` directly. The wrapper receives the private generation token,
ordinal, and note path in its environment and independently carried exact argv
for both the intended resume and the recorded safe shell. It requires `current`
to name that generation, the token to match it, and the explicit ordinal to
select one structurally valid manifest entry. Only after those checks establish
a unique receipt target and binding may the wrapper trust that entry's recorded
safe shell or write a receipt into its generation. It then compares both
independently carried argv values against the entry and reads the numeric
`KITTY_WINDOW_ID` that Kitty injected into the process it actually spawned.
This self-observed ID, not a parent-side lookup, is the authoritative registry
key.

A failure before that binding boundary—including a missing or stale token, a
missing or wrong ordinal, or a top-level, `panes`, or entry structure that
prevents unique binding—logs locally, leaves every note marker untouched,
writes no bootstrap receipt, and execs fixed `/bin/sh`. Neither a generation
chosen by untrusted input nor caller-carried fallback argv is trusted on this
path.

Pane zero keeps its existing one-line session-file transport. `emit_stub`
extends the mode-`0600` `pane0-launch.json` record with the generation token,
ordinal 1, and complete manifest binding; `--exec-pane0` verifies the stub argv
prefix against that record and then enters the same in-pane bootstrap routine.
This captures Kitty's injected window ID before `execvp` without a socket query,
timing guess, or SessionStart event.

Later `kitty @ launch` calls also target the bootstrap wrapper. After each call
returns, the parent writes its single decimal result to that ordinal's atomic
`expected-window` file. The in-pane wrapper waits for that file and requires it
to equal its own Kitty-injected ID before proceeding. This is a cross-check of
the self-observed binding, not the source of the binding; a missing, malformed,
or mismatched return can never select some other pane or session.

Only after all checks pass does the wrapper atomically replace the typed Codex
row under the pane-session lock. It then writes atomic `bootstrap-bound` and
`execvp`s the exact manifest argv. `bootstrap-bound` is deliberately
intermediate: it proves the row is durable, but does not prove that the exec
happened or that Codex is the foreground process. The wrapper never performs
draft delivery itself.

After the binding boundary, a note, independently carried argv, numeric window,
`expected-window`, registry, or bound-receipt failure leaves `.pending`, writes
`bootstrap-failed` where possible, and execs the manifest-recorded safe shell
instead of Codex. If that failure receipt cannot itself persist, the parent
observes no terminal receipt and handles the pane through the same bounded
deadline. This post-binding behavior does not weaken the pre-binding rule:
untrusted token, ordinal, or manifest structure never selects a receipt path or
fallback command.

SessionStart remains the authority for ordinary starts and Claude restore. A
later real Codex hook may replace the launcher-written row by the same window-ID
key, but for a restored Codex pane it performs registry replacement only and
never calls draft delivery. The restore launcher owns that generation's sole
automatic attempt, so a hook that appears after user input cannot insert a late
pickup draft.

### Restore and autosave serialization

Immediately after acquiring the existing `restore.lock`, and before destructive
cleanup, the cold-start parent atomically writes the mode-`0600`
`restore-incomplete` guard with its generation and current stage. It then holds
the lock continuously across cleanup, generation publication, every pane
launch, and final settlement of every restored Codex pane. A bound pane is
settled only when `kitty @ ls` reports that exact authoritative window ID with
the interactive Codex process in its foreground list and the exact canonical
`codex resume <UUID>` argv from its manifest entry. A bootstrap-wrapper process
is never settled, even after `bootstrap-bound`. A failed pane is settled only
when `bootstrap-failed` exists and the window is running its recorded safe shell
or has reached the explicit safe-shell failure state. Terminal settlement is a
liveness condition: either outcome stops the wait for that pane. Only an exact
Codex settlement is eligible for draft delivery; a safe-shell settlement leaves
`.pending` untouched. The parent releases the lock after every pane reaches one
of the terminal settlement states and every eligible delivery attempt reaches a
durable marker state, or after the shared deadline ends an unsettled
pre-binding failure.

A pre-binding failure has no receipt and therefore is not a failed-pane
settlement. The parent reaches its bounded deadline, preserves the prior
snapshot and `restore-incomplete`, leaves all note markers untouched, and
releases `restore.lock` through the normal timeout path.

Socket startup, parent launch-result capture, `expected-window`, bootstrap
receipt, foreground settlement, and delivery preflight all consume the same
finite monotonic deadline; no stage resets it. Each polling loop checks the
remaining time and uses a subprocess timeout no longer than that remainder. A
missing launch return, killed wrapper, vanished window, or expired deadline
logs the generation, ordinal, and exact failed stage, leaves an unclaimed draft
`.pending`, and records the restore as incomplete. The parent closes or replaces
only a window whose returned or self-reported ID and bootstrap-wrapper argv
still prove it belongs to that entry; ambiguous windows are left untouched.
Abandoned generation files rotate under the existing retention policy.

The guard keeps the prior `snapshot.json` and `last.session` authoritative after
any detected failure or abrupt parent exit. Successful restore completion is
stricter than terminal settlement: every planned Codex pane must settle as its
exact intended `codex resume <UUID>`, and every other required pane launch must
succeed. Only that all-success outcome removes the guard immediately before
releasing the lock. A post-binding `bootstrap-failed` plus safe-shell settlement
is terminal for waiting and permits lock release, but marks the restore
unsuccessful and keeps the guard and prior snapshots intact. A pre-binding
failure reaches the same unsuccessful result only through the bounded timeout,
not a receipt. Failure to remove the guard after an otherwise successful restore
is itself a logged incomplete restore. A later cold restore may replace the
guard while holding the lock and try again. Every exit path uses a `finally`
equivalent to release `restore.lock`, including timeout and cleanup failure, so
a dead wrapper cannot retain the lock forever.

`kitty-session-save` opens that same cache-directory lock before socket
discovery or `kitty @ ls` and takes it non-blockingly. If restore owns it, the
saver exits successfully without creating a candidate, enriching, replacing
`snapshot.json`, or regenerating `last.session`; the next timer tick retries.
When the saver acquires the lock, it holds it through capture, enrichment,
snapshot commit, and `last.session` replacement. It also skips publication
while `restore-incomplete` exists. Therefore no published snapshot can observe
a restored Codex process between pane creation and terminal settlement, or
replace the prior snapshot after a failed restore.

### Draft delivery state machine

Draft delivery uses three durable marker names beside the note:

- `.pending`: no send attempt has begun; the restore launcher's one automatic
  attempt is eligible.
- `.sending`: this process owns the claim, but a crash could make the external
  send boundary unknowable.
- `.uncertain`: a send may have reached Kitty; this is terminal and is never
  retried automatically.

For a restored Codex pane, delivery is eligible only after the registry row is
durable and the parent has observed the exact Codex foreground argv in the
authoritative window. The delivery helper then resolves the note within the
active generation and requires a fresh `kitty @ ls` on the configured socket to
contain exactly that one settled window. A missing, duplicate, unreachable, or
still-bootstrap target leaves `.pending` untouched. Only a successful settled
target preflight may atomically rename `.pending` to `.sending`.

With the claim held, the helper sends exactly these constant bytes to that
socket and window, without a carriage return or newline:

```text
Read $KITTY_RESTORE_NOTE.
```

A handled failure before the `send-text` subprocess is invoked can safely
rename `.sending` back to `.pending`. Immediately before invocation the helper
marks the attempt as begun in-process. Once invocation is attempted, every
return code transitions `.sending` to `.uncertain`: Kitty provides no delivery
acknowledgement, and even success cannot prove that the target survived the
preflight-to-send interval. If the process dies while `.sending` exists, the
next cold-start reconciliation also converts it to `.uncertain`; it never
guesses that a resend is safe. A post-send interruption therefore cannot cause
duplicate input, at the cost of requiring manual recovery when delivery is
uncertain.

When the send reaches the still-live target, as verified by the interactive
smoke rather than inferred from marker state, the exact draft is visible but
remains unsent. The user then chooses the next action: Enter submits it, while
Backspace/Ctrl+U removes it. No state transition presses Enter or otherwise
starts an agent turn.

Two alternatives are explicitly rejected. Polling for a Codex SessionStart
event cannot break the pre-first-turn cycle observed in the smoke test.
Injecting the pickup through stdin or as a positional prompt can make the agent
act immediately and therefore violates the required manual decision point.

### Security and failure behavior

- The hook and Codex restore bootstrap accept `KITTY_RESTORE_NOTE` only after
  resolving it beneath the fixed state root and the active generation named by
  the matching bootstrap token and manifest entry.
- Generation, manifest, note, marker, and registry replacement is atomic and
  refuses symlink targets.
- Draft delivery targets the authoritative numeric window ID on the configured
  `KITTY_LISTEN_ON` socket only; neither socket discovery nor cwd matching may
  substitute another target.
- The typed text is constant; note contents and paths are never interpolated
  into terminal input.
- Missing or malformed recovery state cannot prevent Kitty from opening a pane.
  Before a unique active-generation/ordinal binding exists, the wrapper writes
  no receipt and execs fixed `/bin/sh`; it never trusts caller-carried fallback
  argv. After that binding exists, a later validation or persistence failure may
  write `bootstrap-failed` and exec the manifest-recorded safe shell. Neither
  path starts a resume whose exact mapping cannot be preserved.
- A Codex UUID is bootstrapped only from the valid `codex_session_id` attached
  to the exact snapshot pane being restored; there is no latest-by-mtime
  fallback for Codex.
- Kitty never launches a restored `codex resume` argv directly. That exec is
  reachable only after the in-pane wrapper has validated identity, persisted
  the registry row, and published `bootstrap-bound`.
- Every delivery path starts only after the typed mapping is durable. A failed
  target preflight also requires parent-observed settled Codex foreground and
  leaves `.pending`; any attempted send ends or reconciles as `.uncertain`.
  Neither outcome removes or rolls back the mapping.
- `.uncertain` is an honest no-ack outcome, not a delivered claim. It requires
  manual inspection or recovery and is never an automatic-resend source.
- No failure path appends a newline, presses Enter, or otherwise submits the
  pickup draft.
- Existing Claude egress-slice wrapping remains Claude-only. Codex follows its
  existing execution policy rather than being mislabeled as Claude.

## Verification

Development follows test-driven order.

1. Extend `vm-claude-pane` with failing behavioral cases for Codex hook rows,
   two same-directory Codex panes, legacy rows, invalid UUIDs, a pane returned
   to its shell, and exact `codex resume <id>` planning.
2. Add a restore regression that deliberately emits no Codex hook after
   `codex resume`. Assert that every Codex pane launches through the in-pane
   wrapper, binds its Kitty-injected window ID under the pane-session lock, and
   makes the typed row durable before the first delivery preflight. Assert that
   no parent launch command starts `codex resume` directly.
3. Make that preflight fail. Assert that `.pending` remains, the mapping remains,
   no send is attempted, and a subsequent periodic save preserves the exact
   recorded UUID as `codex_session_id`.
4. Exercise the bootstrap token, active manifest, ordinal, note-path,
   canonical-argv, and Kitty-injected-ID checks for pane zero and a later pane.
   Give two panes distinct UUIDs and ordinals but the same safe-shell argv; both
   must bind their exact ordinal. The later-pane control must also match the
   parent's launch-returned ID. A unique valid binding starts the exact resume.
   Missing/stale token, missing/wrong ordinal, and malformed top-level,
   `panes`, or entry structure that prevents unique binding must write no
   receipt, leave every note marker untouched, avoid caller-carried fallback,
   and exec fixed `/bin/sh`. Once token, ordinal, and a structurally valid entry
   establish a trusted binding, note/argv/window/`expected-window`/registry or
   bound-receipt failure must leave `.pending`, write `bootstrap-failed` where
   possible, and exec the manifest-recorded safe shell. If the failure receipt
   cannot persist, assert that the parent reaches the finite deadline,
   preserves the prior snapshot and `restore-incomplete`, and releases the
   lock.
5. Pause a later in-pane wrapper after Kitty creates its window but before it
   writes the registry row. Start `kitty-session-save` and assert that its
   nonblocking `restore.lock` acquisition exits zero without creating a
   candidate or changing `snapshot.json` or `last.session`. Release the wrapper,
   wait for the exact Codex foreground settlement, then save again and assert
   the published snapshot contains the exact `codex_session_id`.
6. Pause the wrapper immediately after `bootstrap-bound` but before `execvp`.
   Assert that the parent still holds `restore.lock`, `kitty @ ls` identifies the
   wrapper rather than a settled Codex process, and a concurrent saver skips
   without publishing an identity-less snapshot. Release the wrapper and assert
   settlement occurs only when the exact `codex resume <UUID>` foreground argv
   appears.
7. Exercise a missing launch return, a wrapper killed before its receipt, a
   vanished window, and a settlement timeout under a shortened shared deadline.
   Each case must terminate within that deadline, log its generation/ordinal and
   failed stage, leave the draft unclaimed, preserve the prior snapshot through
   `restore-incomplete`, clean only unambiguously owned partial state/windows,
   and release `restore.lock`.
8. Force one planned Codex pane to write `bootstrap-failed` and settle as its
   recorded safe shell. Assert that this terminal state stops the wait and
   releases `restore.lock`, so a saver can acquire it, but does not count as
   successful restore completion: `restore-incomplete` remains, the saver
   publishes nothing, and the prior exact snapshot and backups remain intact.
9. Add deterministic delivery seams immediately before invoking `send-text` and
   immediately after it returns. A handled pre-send failure returns `.sending`
   to `.pending` with zero send calls. An interruption after the send boundary
   leaves `.sending`; reconciliation changes it to `.uncertain`, and a later
   invocation makes no second send. Both paths retain the exact typed mapping.
10. Simulate the window disappearing after the successful `kitty @ ls` preflight
   but before or during `send-text`. Assert `.uncertain`, no delivered claim,
   no mapping loss, and no automatic duplicate input even if `send-text` exits
   zero. The success control asserts the draft bytes are exactly
   `Read $KITTY_RESTORE_NOTE.` with no carriage return or newline.
11. Create a smaller second restore generation after a larger topology. Assert
   that only the new ordinals are active, stale `.pending`, `.sending`, and
   `.uncertain` files are reconciled and rotated or pruned under the restore
   lock, abandoned temporary state is removed, and the two-generation bound is
   enforced.
12. Keep all existing Claude collision, zombie-pane, pane-zero, topology,
   retention, and egress-slice tests green.
13. Build the affected `vm-claude-pane` and `vm-kitty` check lanes locally.
14. Because this changes branching and multistep restore scripts, repeat the
   full `nixos-agent-testing` dual-client smoke against real Kitty in the
   feature VM. Restore one Claude and one Codex pane; verify both exact IDs,
   the Codex typed mapping before any hook or transcript update, UUID retention
   across a periodic save, and the exact pickup draft visible but unsent in
   both panes with no transcript turn. Exercise erasing one draft and manually
   submitting the other.
15. Run the configured preflight/evaluation checks and independent close-out
   review before committing, pushing, and opening the PR.

## Out of scope

- Restoring terminal scrollback or arbitrary foreground commands.
- Reconstructing Codex subagent transcripts beyond the bounded recovery note.
- Automatically submitting, accepting, or deleting the pickup draft.
- Replaying unsafe or ephemeral CLI flags from the previous Codex process.
