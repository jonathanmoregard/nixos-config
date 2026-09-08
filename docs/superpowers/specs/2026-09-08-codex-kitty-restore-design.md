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
obsolete notes and every marker state rotate out under a fixed two-generation
cap instead of accumulating.

Claude notes retain the useful existing detail about interrupted subagents,
dirty worktrees, and surviving detached units. Codex notes state that the prior
process and its in-process workers ended, include the recorded working
directory and current Git summary when available, and tell the resumed agent to
verify filesystem and process state before continuing. Notes never live in a
project checkout or become part of a Git diff.

The launch environment carries the exact note path as `KITTY_RESTORE_NOTE` and
the generation token as `KITTY_RESTORE_BOOTSTRAP`. Resume commands contain no
prompt. Passing the note path through the pane environment avoids depending on
a resumed runtime preserving the requested session UUID. Claude may assign a
new SessionStart ID while resuming an older conversation, so matching a note by
session ID would be unreliable.

### Authoritative restored-pane binding

The shared registry writer atomically replaces a window-ID row while holding
the existing pane-session lock. For every restored Codex pane, registry binding
happens as soon as the new window ID is authoritative and before any subsequent
`kitty @ ls` target check or other draft-delivery preflight. A preflight or
delivery failure never rolls that row back, so the exact UUID survives every
delivery outcome and remains available to the next autosave.

Pane zero uses the environment of the process Kitty actually spawned rather
than trying to discover itself by timing. `emit_stub` extends the existing
mode-`0600` `pane0-launch.json` record with the generation token, ordinal 1,
agent kind, exact recorded UUID, cwd, note path, and canonical argv, then puts
the same token and note path in the stub's `--env` fields. The existing
`--exec-pane0` helper runs inside the new pane before `execvp`; Kitty itself has
already injected that pane's numeric `KITTY_WINDOW_ID` and configured
`KITTY_LISTEN_ON`, as confirmed by the live smoke.

Before starting Codex, `--exec-pane0` requires the environment token, note path,
ordinal, and canonical-argv prefix to match both `pane0-launch.json` and the
active generation manifest. It also requires a numeric `KITTY_WINDOW_ID`.
Those checks bind Kitty's own injected ID to exactly one planned pane without a
socket query or a SessionStart event. The helper then persists the typed Codex
row under the pane-session lock and runs the delivery state machine before
`execvp` of the canonical resume argv. `send-text` writes to the same pane's pty
input queue; the exec preserves that pty, and the absence of a newline keeps the
queued draft from being submitted when Codex takes over. A delivery failure
does not prevent the exact mapped resume. If any binding check or registry
write fails, however, the helper leaves the marker pending, does not run
delivery, and opens the safe fallback shell instead of starting an unmapped
Codex resume.

For every later pane, `kitty-pane-add` returns the single decimal window ID
emitted by its exact `kitty @ launch` call rather than discarding stdout. The
restore loop validates that return, immediately persists the typed Codex row
under the pane-session lock, and only then invokes the delivery preflight. A
missing or malformed returned ID is never guessed: the launcher leaves the
marker pending, logs a concise diagnostic, and does not claim successful
binding or delivery.

SessionStart remains the authority for ordinary starts and Claude restore. A
later real Codex hook may replace the launcher-written row by the same window-ID
key, but for a restored Codex pane it performs registry replacement only and
never calls draft delivery. The restore launcher owns that generation's sole
automatic attempt, so a hook that appears after user input cannot insert a late
pickup draft.

### Draft delivery state machine

Draft delivery uses three durable marker names beside the note:

- `.pending`: no send attempt has begun; the restore launcher's one automatic
  attempt is eligible.
- `.sending`: this process owns the claim, but a crash could make the external
  send boundary unknowable.
- `.uncertain`: a send may have reached Kitty; this is terminal and is never
  retried automatically.

After the registry row is durable, the delivery helper resolves the note within
the active generation and requires `kitty @ ls` on the configured socket to
contain exactly one window with the authoritative ID. A missing, duplicate, or
unreachable target leaves `.pending` untouched. Only a successful preflight may
atomically rename `.pending` to `.sending`.

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
  An identity-critical Codex bootstrap failure degrades that pane to the safe
  shell rather than starting a resume whose exact mapping cannot be preserved.
- A Codex UUID is bootstrapped only from the valid `codex_session_id` attached
  to the exact snapshot pane being restored; there is no latest-by-mtime
  fallback for Codex.
- Every delivery path starts only after the typed mapping is durable. A failed
  target preflight leaves `.pending`; any attempted send ends or reconciles as
  `.uncertain`. Neither outcome removes or rolls back the mapping.
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
   `codex resume`. Assert that pane zero binds the Kitty-injected window ID and
   later panes bind the decimal IDs returned by `kitty @ launch`, with each
   typed row durable before the first `kitty @ ls` preflight.
3. Make that preflight fail. Assert that `.pending` remains, the mapping remains,
   no send is attempted, and a subsequent periodic save preserves the exact
   recorded UUID as `codex_session_id`.
4. Exercise the pane-zero bootstrap token, manifest, ordinal, note-path, and
   canonical-argv checks. A unique valid binding must start the exact resume;
   a missing, stale, mismatched, or ambiguous binding must claim no marker and
   fail closed to the shell.
5. Add deterministic delivery seams immediately before invoking `send-text` and
   immediately after it returns. A handled pre-send failure returns `.sending`
   to `.pending` with zero send calls. An interruption after the send boundary
   leaves `.sending`; reconciliation changes it to `.uncertain`, and a later
   invocation makes no second send. Both paths retain the exact typed mapping.
6. Simulate the window disappearing after the successful `kitty @ ls` preflight
   but before or during `send-text`. Assert `.uncertain`, no delivered claim,
   no mapping loss, and no automatic duplicate input even if `send-text` exits
   zero. The success control asserts the draft bytes are exactly
   `Read $KITTY_RESTORE_NOTE.` with no carriage return or newline.
7. Create a smaller second restore generation after a larger topology. Assert
   that only the new ordinals are active, stale `.pending`, `.sending`, and
   `.uncertain` files are reconciled and rotated or pruned under the restore
   lock, abandoned temporary state is removed, and the two-generation bound is
   enforced.
8. Keep all existing Claude collision, zombie-pane, pane-zero, topology,
   retention, and egress-slice tests green.
9. Build the affected `vm-claude-pane` and `vm-kitty` check lanes locally.
10. Because this changes branching and multistep restore scripts, repeat the
   full `nixos-agent-testing` dual-client smoke against real Kitty in the
   feature VM. Restore one Claude and one Codex pane; verify both exact IDs,
   the Codex typed mapping before any hook or transcript update, UUID retention
   across a periodic save, and the exact pickup draft visible but unsent in
   both panes with no transcript turn. Exercise erasing one draft and manually
   submitting the other.
11. Run the configured preflight/evaluation checks and independent close-out
   review before committing, pushing, and opening the PR.

## Out of scope

- Restoring terminal scrollback or arbitrary foreground commands.
- Reconstructing Codex subagent transcripts beyond the bounded recovery note.
- Automatically submitting, accepting, or deleting the pickup draft.
- Replaying unsafe or ephemeral CLI flags from the previous Codex process.
