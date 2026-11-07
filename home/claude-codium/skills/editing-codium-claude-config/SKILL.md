---
name: editing-codium-claude-config
description: Use when adding or changing a skill, prompt or session notes for Claude inside Codium — writing an editor-scoped skill, editing anything under ~/.local/state/claude-codium, deciding whether a skill belongs to the editor or to every session, or reading a drift report heading about Codium skills or notes.
---

# Editing the Codium Claude layer

Editor sessions run with `CLAUDE_CONFIG_DIR=~/.local/state/claude-codium`.

| Path | Edit it here? |
|---|---|
| `skills/<name>/` | Yes — live immediately |
| `local.md` | Yes — seeded once, yours after |
| `CLAUDE.md` | No — re-linked from the store every activation |

Write a new skill straight into `skills/<name>/SKILL.md`. No worktree, no PR,
usable at once; it survives reboot and deploy but not a reinstall. The drift
report lists it under *Codium-only skills live but not declared* — the
promotion queue. Promote by moving the directory into
`home/claude-codium/skills/` in nixos-config.

Activation removes only a link whose target is gone or an obsolete store
link. A real directory, and a link into one of your own repos, are left
alone.

Scope it to the editor: the diff view, the panel, the file tree, the
accept/reject edit flow. Anything useful in a terminal too belongs in
`~/.claude/skills` (claude-config's `runtime/skills`), which both session
kinds already see.

A real directory here beats a shared skill of the same name silently, and is
reported as *Codium skills shadowing a shared skill of the same name*. Rename
or drop it rather than promoting it.

Put prose in `local.md`. An edit to `CLAUDE.md` is overwritten on the next
deploy.
