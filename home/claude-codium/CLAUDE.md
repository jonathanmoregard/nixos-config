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

## Iterating on this setup

`skills/` in this config directory is assembled at activation: one symlink per
skill from `~/.claude/skills`, plus the Codium-only skills declared in
nixos-config under `home/claude-codium/skills`. A skill you write in there
yourself is left alone — both a real directory and a symlink into one of the
user's own repos — so it survives reboot and deploy, and is lost on a fresh
install until it is promoted into `home/claude-codium/skills` in nixos-config.
The only thing activation removes is a symlink whose target has gone.

Note that `projects/` here is this directory's own, so an editor session does
not share transcripts or a `--resume` list with a terminal one. The MCP
servers and `.claude.json` ARE shared.

`local.md`, imported at the end of this file, is the same deal for prose: it
is writable, it needs no worktree and no PR, and it is the right place to put
something learned mid-session. Promote the parts that prove durable into this
file, which IS declared.

That split is deliberate: declared is reviewed and survives a reinstall,
written-live is immediate and survives everything short of one. Nothing
reports on the live half yet — `nixos-drift-analyzer` does not look in this
directory — so a skill or a note left here is invisible until someone reads
it. Promote the things worth keeping rather than relying on being reminded.

@/home/jonathan/.claude/CLAUDE.md

@/home/jonathan/.local/state/claude-codium/local.md
