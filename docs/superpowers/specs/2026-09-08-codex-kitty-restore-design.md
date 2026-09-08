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

### Recovery note and manual pickup

Before launching each restored agent pane, write its recovery context to:

```text
~/.local/state/claude/kitty-restore/pane-<ordinal>.md
```

The directory is mode `0700` and notes are mode `0600`. Ordinals are unique
within the one restored topology and are overwritten on the next restore, so
the state remains bounded. Notes never live in a project checkout or become
part of a Git diff.

Claude notes retain the useful existing detail about interrupted subagents,
dirty worktrees, and surviving detached units. Codex notes state that the prior
process and its in-process workers ended, include the recorded working
directory and current Git summary when available, and tell the resumed agent to
verify filesystem and process state before continuing.

The launch environment carries the exact note path as
`KITTY_RESTORE_NOTE`. Resume commands contain no prompt. A one-shot pending
marker beside the note identifies a draft that has not yet been delivered.

For a restored Codex pane, the restore launcher performs the bootstrap. It
first confirms that the new numeric window ID exists on the current
`KITTY_LISTEN_ON` socket. Under the existing pane-session lock, it then writes
an agent-kind-tagged `codex` row keyed to that new window ID and containing the
exact recorded UUID. It atomically claims that pane's pending marker and uses
the current Kitty socket and window ID to send exactly these constant bytes,
without a carriage return or newline:

```text
Read $KITTY_RESTORE_NOTE.
```

The user then chooses the next action: Enter submits the pickup, while
Backspace/Ctrl+U removes it. No agent turn begins automatically. The live-window
preflight must precede both marker consumption and draft delivery because Kitty
documents that `send-text` always exits successfully, even when it matched no
window. On failure, the launcher leaves `.pending`, preserves the known Codex
mapping when the target identity has already been established, and logs a
concise diagnostic. It never falls back to submitting a prompt.

Pane zero follows the same ordering after the Kitty socket appears and its
window ID can be discovered. Later panes use the window IDs returned directly
by `kitty @ launch`. This gives every pane a trustworthy old-UUID-to-new-window
binding before its marker can be consumed.

Passing the note path through the pane environment avoids depending on a
resumed runtime preserving the requested session UUID. Claude may assign a new
SessionStart ID while resuming an older conversation, so matching the pending
note by session ID would be unreliable.

Two alternatives are explicitly rejected. Polling for a Codex SessionStart
event cannot break the pre-first-turn cycle observed in the smoke test.
Injecting the pickup through stdin or as a positional prompt can make the agent
act immediately and therefore violates the required manual decision point.

### Security and failure behavior

- The hook and Codex restore bootstrap accept `KITTY_RESTORE_NOTE` only after
  resolving it beneath the fixed Kitty restore state directory.
- Note and marker replacement is atomic and refuses symlink targets.
- Draft delivery targets the current numeric `KITTY_WINDOW_ID` and the current
  `KITTY_LISTEN_ON` socket only.
- The typed text is constant; note contents and paths are never interpolated
  into terminal input.
- Missing or malformed state cannot block pane restoration.
- A Codex UUID is bootstrapped only from the valid `codex_session_id` attached
  to the exact snapshot pane being restored; there is no latest-by-mtime
  fallback for Codex.
- A failed target preflight cannot consume the marker or send terminal input.
  A later delivery failure leaves `.pending` available for recovery and keeps
  a known mapping only when its new target window was established reliably.
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
   `codex resume`. Assert that the launcher immediately writes the typed mapping
   for the new window ID and that a subsequent periodic save preserves the
   exact recorded UUID as `codex_session_id`.
3. Extend `kitty-scripts` assertions so marker consumption happens only after
   the target socket/window preflight. Assert that the delivered draft is
   exactly `Read $KITTY_RESTORE_NOTE.` with no carriage return or newline, and
   that failure leaves `.pending`, preserves only a trustworthy mapping, and
   never submits input.
4. Keep all existing Claude collision, zombie-pane, pane-zero, topology,
   retention, and egress-slice tests green, including the separate discovery
   path for pane zero and returned window IDs for later panes.
5. Build the affected `vm-claude-pane` and `vm-kitty` check lanes locally.
6. Because this changes branching and multistep restore scripts, repeat the
   full `nixos-agent-testing` dual-client smoke against real Kitty in the
   feature VM. Restore one Claude and one Codex pane; verify both exact IDs,
   the Codex typed mapping before any hook or transcript update, UUID retention
   across a periodic save, and the exact pickup draft visible but unsent in
   both panes with no transcript turn. Exercise erasing one draft and manually
   submitting the other.
7. Run the configured preflight/evaluation checks and independent close-out
   review before committing, pushing, and opening the PR.

## Out of scope

- Restoring terminal scrollback or arbitrary foreground commands.
- Reconstructing Codex subagent transcripts beyond the bounded recovery note.
- Automatically submitting, accepting, or deleting the pickup draft.
- Replaying unsafe or ephemeral CLI flags from the previous Codex process.
