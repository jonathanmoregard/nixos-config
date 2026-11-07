# Claude in Codium

This file is the global CLAUDE.md for sessions started from VSCodium, and for
no others. It is reached because `home/vscodium.nix` declares
`claudeCode.environmentVariables` with `CLAUDE_CONFIG_DIR` pointing at
`~/.local/state/claude-codium`, which the extension pulls out of that list and
applies to the `claude` process it spawns.

The global rules are imported below rather than restated. Nothing here
replaces them; this file adds what is only true inside the editor.

## What is different in here

- There is a GUI. A diff, a file tree and a rendered preview are one click
  away for the user, so describing a change in prose that the editor is
  already showing is wasted output. Say what changed and why; let the editor
  show the what.
- The user's selection and open file are attached to the conversation by the
  extension. Treat them as the subject of an unqualified "this" before
  guessing from the repo.
- Proposed edits land as accept/reject in the editor rather than as applied
  writes, so an edit here is a proposal the user adjudicates. Do not also
  paste the full new file into chat.
- Terminal-shaped habits do not pay off: there is no kitty pane to split, and
  a long foreground command blocks a panel the user is watching rather than a
  terminal they can leave.

## Changing this setup from inside a session

Two things in this directory are writable on purpose, and writing them is part
of the ordinary flow rather than a config change to be reviewed first:

| To add | Write | Shape |
|---|---|---|
| A skill that only makes sense in the editor | `~/.local/state/claude-codium/skills/<name>/SKILL.md` | `name` + `description` frontmatter, then the body |
| A note, preference or correction worth keeping | `~/.local/state/claude-codium/local.md` | append it |

That directory is `$CLAUDE_CONFIG_DIR` for this session. Both take effect for
the next session in this editor, and both survive reboot and deploy.

The global rule imported below — every edit to skills, CLAUDE.md, hooks or
settings goes through a `~/worktrees/claude-<slug>` worktree and a PR, with
agent e2e first — governs `~/.claude`, which is a read-only projection of
`claude-config` read live by every session on the machine. This directory is
neither read-only nor shared. Writing here needs no worktree, no PR and no
e2e: do it in the session the need comes up, without asking.

Three things are still off-limits:

- `CLAUDE.md` in this directory is a store symlink, so it is read-only. Prose
  goes in `local.md`.
- `settings.json` is a symlink to the live one, so permissions and the security
  hooks are identical here. Nothing about this directory is a way around them.
- A skill useful in a terminal too belongs in `claude-config`'s
  `runtime/skills`, through its own PR flow. Scope one here only when it is
  about the diff view, the panel, the file tree, or the accept/reject edit
  flow.

## What happens to it afterwards

`skills/` is assembled at activation: one symlink per skill from
`~/.claude/skills`, plus the Codium-only skills declared in nixos-config under
`home/claude-codium/skills`. Anything else there is left alone — a real
directory you wrote, or a symlink into one of the user's own repos. The only
thing activation removes is a symlink whose target has gone.

`nixos-drift-analyzer` reports what gets left here, so none of it goes
unnoticed:

- *Codium-only skills live but not declared* — the promotion queue. Move the
  directory into `home/claude-codium/skills` in nixos-config once it has
  proven itself.
- *Codium skills shadowing a shared skill of the same name* — a real directory
  beats the inherited skill of that name, so the shared one is unreachable
  from editor sessions. Rename or drop the live copy; do not promote it.
- *Codium session notes live but not declared* — `local.md` has notes past its
  seed. Promote the durable ones into this file.

So the arrangement is: write it live and use it immediately, get reported, get
promoted into declared config when it has earned it. Declared is reviewed and
survives a reinstall; live is immediate and survives everything short of one.

Note that `projects/` here is this directory's own, so an editor session does
not share transcripts or a `--resume` list with a terminal one. The MCP
servers and `.claude.json` ARE shared.

@/home/jonathan/.claude/CLAUDE.md

@/home/jonathan/.local/state/claude-codium/local.md
