---
name: resuming-a-reset-session
description: Use when asked to continue work from a session whose context is gone — "pick back up", "pick this back up", "accidentally reset session", "session reset", "you lost your context", "continue where we left off", "what were we doing", "carry on". For a planned handoff read self-compact's handoff instead; for a status question use reporting-state.
---

# Resuming a reset session

The repo tells you what *changed*. Only the transcript tells you what the user
was *doing*. Never reconstruct intent from `git log` and a diff — a confident
wrong reconstruction reads exactly like a correct one, and the user cannot see
that you guessed.

## 1. Read the previous transcript

```bash
~/.local/state/claude-codium/skills/resuming-a-reset-session/bin/last-session -n 12
```

Newest transcript for the current directory, this session excluded, wrappers
stripped. `-d DIR` for another worktree. Editor and terminal sessions keep
separate `projects/` dirs; it searches both. Nothing found, or the reset was a
planned `/self-compact` → use its handoff and `mission.md`.

## 2. Find three things

| | |
|---|---|
| **Live request** | the last thing the user actually asked. This is the task. |
| **Open question** | a decision you put to them that never got an answer. |
| **Durable directive** | a stated preference ("here's how I like X"). |

A tangent right before the reset is still the live request — a half-answered
editor question outranks the big task it interrupted.

## 3. Record the directive that same turn

A durable directive goes datestamped into `<notes>/session-constraints.md`
before you resume. A reset is exactly when an unrecorded preference is lost
for good.

## 4. Report, then resume

Three lines before acting — live request, open question, work in flight. Then
do the live request. If the recovered facts contradict what the repo suggested,
say so in one line.

## 5. Leave in-flight work where it sits

Uncommitted changes you did not author this session are an in-flight
conversation, not a task to finish. Do not commit, merge, push or revert them,
even when the gates are green and the diff looks complete — "the user was still
reviewing it" is invisible in a diff. Say the work is staged, say what it is,
and let the user call it. Verifying it (format, lint, the owning-crate check)
is useful and safe; landing it is not yours.
