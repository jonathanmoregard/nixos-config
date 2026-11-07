---
name: editing-codium-settings
description: Use when changing a VSCodium editor setting from inside the editor — tuning something in the Settings UI or settings.json, asking whether a change survives the next deploy, promoting a setting into nixos-config, or reading a drift report heading about VSCodium settings.
---

# Editing Codium settings

`settings.json` is a real file, re-merged at every activation as
`$dynamic * $static`.

| The key is | What happens to your edit |
|---|---|
| Declared in `home/vscodium.nix` | Reverted at the next deploy, and recorded first |
| Not declared | Survives reboot and deploy; lost on a fresh install |

Try a setting by editing it live. Undeclared keys stick, and the hourly drift
report lists them under *VSCodium settings live but not declared* — the
promotion queue. A reverted declared key comes back under *VSCodium settings
overwritten by the declared config*.

A security-sensitive key is escalated under its own heading instead —
`security.`, `telemetry.`, `chat.tools.` (agent auto-approve), the
`claudeCode.` permission keys, the `git.*` verify and force-push switches,
extension auto-update, `http.proxy`, `task.allowAutomaticTasks`.

Make it permanent by declaring it in `home/vscodium.nix` (worktree + PR).
That is also the only way it survives a reinstall.

Keep comments and formatting out of `settings.json`: the merge writes jq
output and destroys both on every deploy.

`keybindings.json` has no mutable layer — it is a store symlink, so every
change to it goes through nixos-config.

Deleting a declared key from the live file is not detected. Remove the
declaration instead.
