# Kitty Root-Pane Owner Selection Design

## Goal

Restore each Kitty pane's interactive root agent. A background Claude or Codex
process sharing the pane's PTY must never replace that owner during snapshot
enrichment, session conversion, or restore planning.

## Observed failure

The saved pre-restore window contained both processes below, in Kitty's
PID-ordered `foreground_processes` list:

1. `claude --model haiku --max-turns 20 --print ...`, a background proposal
   scorer.
2. `codex resume 01a08b57-a3fe-78a3-98a9-259d5a177453`, the pane's root TUI.

The same window's stable `cmdline` was the root Codex command. Existing code
selected the first interactive agent anywhere in `foreground_processes`, so
all three consumers classified the pane as Claude. Enrichment then rejected
the typed Codex registry row, and restore's latest-Claude fallback selected the
Haiku scorer transcript `e3d57bcd-ae4b-48a0-97d2-1cb34d013494`.

## Design

First, the shared classifier must enforce its existing documented boundary:
`_agent_kind` means interactive agent. Claude invocations containing `-p`,
`--print`, `--bg`, or `--background` are not pane-owner candidates. This
exclusion alone removes the observed Haiku scorer from consideration.

One shared helper then selects an interactive agent command for all three
consumers. Selection order is:

1. Use the stable Kitty window command when it directly identifies an
   interactive agent. This command describes what Kitty launched for the pane
   and fixes the observed direct-Codex failure.
2. When an exact recorded session field or typed registry row supplies an
   expected agent kind, select only a live foreground agent of that kind. This
   preserves shell-launched agents while excluding background agents of the
   other kind.
3. Without an expected kind, accept the foreground scan only when every
   interactive-agent candidate has one kind. Existing single-agent panes keep
   working regardless of PID order.
4. Treat a mixed-kind foreground list without stable or exact owner evidence
   as ambiguous. Restore the recorded shell or command instead of guessing.

The helper returns both kind and argv. Snapshot enrichment derives the expected
kind from `pane-sessions.tsv`; converter and restore derive it from the exact
`claude_session_id` or `codex_session_id` already attached to the snapshot.
Typed registry rows remain valid only when a live candidate of that kind exists,
except for existing stable-Claude zombie recovery.

Claude's known zombie-pane behavior stays intact: a stable Claude launch
command may recover its exact recorded session even after only an orphaned MCP
child remains. Codex keeps its stricter live-TUI requirement unless its stable
window command itself is interactive Codex. Noninteractive `codex exec`,
services, and background commands remain excluded by the existing classifier.

## Rejected alternatives

- Registry-only selection cannot protect old or temporarily un-enriched
  snapshots and would make `last.session` disagree with restore.
- Highest or lowest PID remains process-order guessing; the reported failure
  demonstrates that shared-PTY background work can occupy either side of the
  root process.
- Rejecting every mixed-agent pane would avoid hijacking but unnecessarily lose
  exact root sessions where Kitty's stable command or typed registry is clear.

## Empirical verification

Testing has two layers:

- Deterministic VM fixtures feed the exact mixed-process shape through
  `kitty-session-enrich`, `kitty-session-convert`, and
  `kitty-restore-session --dump-panes`. They assert the root Codex UUID wins and
  the Haiku Claude UUID is never selected. Separate grammar controls prove
  `claude --print`/`--background` are excluded while root and resume invocations
  remain interactive.
- Real-X `vm-kitty` launches a root Codex process with a background
  `claude --model haiku --print` process sharing its PTY, saves through live
  `kitty @ ls`, kills Kitty, restores through the production wrapper, and
  verifies the exact Codex UUID before the restore guard clears and again after
  a subsequent save.

Because the implementation changes branching, an interactive feature-VM smoke
must repeat the mixed-process save and restore before the PR opens.

## Scope

Change only pane-owner selection and its tests. No restore UI, note-delivery,
registry-format, or layout behavior changes.
