# Codex-aware Kitty restore with manual pickup

## Goal

Restore interactive Codex panes to their recorded threads alongside existing
Claude Code panes. A restored agent must receive no automatic user prompt.
Instead, Kitty leaves a short pickup draft in the input buffer; the user can
submit it or erase it before the agent does any new work.

## Current behavior and root cause

The deployed Kitty snapshot service is healthy. It currently saves eight live
panes once per minute, including four Claude Code panes and four Codex panes.
The shared SessionStart hook already records the correct UUID for every one of
those panes in `pane-sessions.tsv`.

The restore pipeline is nevertheless Claude-specific in two later stages:

1. `kitty-session-enrich` only recognizes a `claude` process and only attaches
   `claude_session_id` to a snapshot window.
2. `kitty-restore-session` only promotes a foreground `claude` process over the
   shell Kitty originally launched and only constructs `claude --resume`.

Consequently, the live restore plan resumes the four Claude sessions and turns
all four Codex panes back into plain zsh panes. This is a classification and
resume-planning gap, not a failure of Kitty capture or the save timer.

The current Claude restore also appends a long recovery notice as the resume
command's positional prompt. That submits the notice automatically, before the
user can decide whether the restored session should continue.

## Design

### Agent identity in the snapshot

Keep the existing `claude-kitty-pane-record` executable name so the already
deployed Claude and mirrored Codex hooks remain compatible. Generalize its
record to include an agent kind:

```text
kitty_window_id<TAB>agent_kind<TAB>session_id<TAB>cwd<TAB>timestamp
```

The hook records `codex` when `CODEX_THREAD_ID` identifies the current Codex
thread; otherwise it records `claude`. The parser continues accepting the old
four-column rows. For a legacy row, the live foreground process determines
which agent owns the UUID.

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
marker beside the note tells the shared SessionStart hook that this start came
from Kitty restore.

After recording the new pane/session mapping, that hook atomically claims the
marker and uses Kitty remote control to type exactly this text into its own
window, without a carriage return or newline:

```text
Read $KITTY_RESTORE_NOTE.
```

The user then chooses the next action: Enter submits the pickup, while
Backspace/Ctrl+U removes it. No agent turn begins automatically. Successful
typing consumes the marker. A failed Kitty send restores the marker and logs a
diagnostic; it never falls back to submitting a prompt.

Passing the note path through the pane environment avoids depending on a
resumed runtime preserving the requested session UUID. Claude may assign a new
SessionStart ID while resuming an older conversation, so matching the pending
note by session ID would be unreliable.

### Security and failure behavior

- The hook accepts `KITTY_RESTORE_NOTE` only after resolving it beneath the
  fixed Kitty restore state directory.
- Note and marker replacement is atomic and refuses symlink targets.
- Draft delivery targets the current numeric `KITTY_WINDOW_ID` and the current
  `KITTY_LISTEN_ON` socket only.
- The typed text is constant; note contents and paths are never interpolated
  into terminal input.
- Missing or malformed state cannot block pane restoration.
- A Codex UUID is used only when attached to that exact Kitty window by the
  SessionStart record; there is no latest-by-mtime fallback for Codex.
- Existing Claude egress-slice wrapping remains Claude-only. Codex follows its
  existing execution policy rather than being mislabeled as Claude.

## Verification

Development follows test-driven order.

1. Extend `vm-claude-pane` with failing behavioral cases for Codex hook rows,
   two same-directory Codex panes, legacy rows, invalid UUIDs, a pane returned
   to its shell, and exact `codex resume <id>` planning.
2. Extend `kitty-scripts` assertions so neither resume command contains an
   automatic prompt, note files have the required location and permissions,
   and draft bytes contain no newline.
3. Keep all existing Claude collision, zombie-pane, pane-zero, topology,
   retention, and egress-slice tests green.
4. Build the affected `vm-claude-pane` and `vm-kitty` check lanes locally.
5. Because this changes branching and multistep restore scripts, run the
   `nixos-agent-testing` interactive smoke against real Kitty in the feature
   VM: restore one Claude and one Codex pane, verify both resume the intended
   IDs, verify `Read $KITTY_RESTORE_NOTE.` is visible but unsent, erase one
   draft, and submit the other.
6. Run the configured preflight/evaluation checks and independent close-out
   review before committing, pushing, and opening the PR.

## Out of scope

- Restoring terminal scrollback or arbitrary foreground commands.
- Reconstructing Codex subagent transcripts beyond the bounded recovery note.
- Automatically submitting, accepting, or deleting the pickup draft.
- Replaying unsafe or ephemeral CLI flags from the previous Codex process.
