# Codium-only skills

One directory per skill, same shape as a `~/.claude/skills` entry: a
`SKILL.md` with `name` and `description` frontmatter, plus whatever reference
files it needs. At activation, `home/claude-codium-config.nix` scans this
directory and `~/.claude/skills` with the same loop and symlinks each
subdirectory of both into `~/.local/state/claude-codium/skills`. This
directory is scanned second, so a skill declared here shadows a global one of
the same name — declaring it here is deliberate, so it is the one that wins.

Only subdirectories are picked up, so this file is ignored.

Keep this directory small: a skill nobody asked for is worse than none. What
is here documents the two mutable layers of this setup itself — the editor's
settings, and this Claude config directory.

## Adding one

Two routes, and the difference is the point:

1. **Write it here, in nixos-config.** Declared, reviewed, survives a fresh
   install. The right home for anything that has proven itself.
2. **Write it straight into `~/.local/state/claude-codium/skills/<name>/`
   during a session.** No worktree, no PR, usable immediately. Survives
   reboot and deploy, but not a reinstall. A real directory is left alone,
   and so is a symlink to one of your own repos — activation only removes
   symlinks whose target has gone, which is how a skill deleted upstream
   stops resolving without taking hand-made links with it.

Route 2 is the mutable layer, and it is the expected one: a session that wants
a skill writes it there on the spot. `nixos-drift-analyzer` then reports it
under *Codium-only skills live but not declared*, which is the promotion
queue — nothing left there is silent. Promote by moving the directory here.

The analyzer reports a second case separately, *Codium skills shadowing a
shared skill of the same name*, which is the one not to promote: a real
directory in the live layer beats the inherited skill of that name, because
activation leaves it alone rather than relinking over it, so the shared skill
becomes unreachable from editor sessions. Rename or drop the live copy.

A skill scoped to the editor should be one that makes no sense in a terminal —
something about the diff view, the panel, the file tree, or the
accept/reject edit flow. A skill that is useful in both belongs in
`~/.claude/skills` (that is, in claude-config's `runtime/skills`), where both
session kinds already see it.
