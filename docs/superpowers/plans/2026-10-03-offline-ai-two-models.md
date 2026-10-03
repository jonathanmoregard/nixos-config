# Plan: offline-ai two models

Spec: docs/superpowers/specs/2026-10-03-offline-ai-two-models-design.md.
Worktree: ~/Repos/nixos-config-worktrees/offline-ai-two-models
(feat/offline-ai-two-models off origin/main 31048e0). Test-first throughout;
`git add -A` before every `nix build`/`nix eval` (flakes see tracked files only).
Check: `nix build --no-link .#checks.x86_64-linux.offline-ai -L` (nix on this
host queues behind nix-memory-run; run it detached with a long timeout).

## Task 1 — harness RED (tests/offline-ai.nix)

Read the whole mode section first (from the comment "offline-AI mode, with
systemctl replaced by a fake" to the end) and the fake `systemctl` near the
top: units are files under `mode/system` and `mode/user`, `is-active` answers
from them, `start memory-reserve-*.service` creates `mode/marker`, calls land
in `mode/calls`. Extend the fake so each reservation gets its own marker file
(`mode/marker` for `memory-reserve-offline-ai.service`, `mode/marker-coder`
for `memory-reserve-offline-ai-coder.service`), keeping every existing case
green.

Add a `two()` helper like `mode()` that also exports
`OFFLINE_AI_MODELS` (JSON for `small` = today's values and `coder` =
`offline-ai-llm-coder.service`, a second fake model file, its reservation and
marker) and `OFFLINE_AI_DEFAULT_MODEL=small`. Write the seven cases from the
spec's Testing section as assertions on `mode/calls`, the unit files, the
markers and the CLI's output/exit status. Build the check: it must FAIL on the
first new case (`--model` unrecognised). Record the failing line.

## Task 2 — CLI GREEN (scripts/offline-ai.py)

- Parse `OFFLINE_AI_MODELS`/`OFFLINE_AI_DEFAULT_MODEL` into `MODELS` with the
  single-model fallback. `select_model(name)` assigns the module globals
  `UNIT`, `MODEL`, `RESERVATION`, `MARKER` (they are read by name at call
  time; keep that).
- argparse: `--model` (choices from `MODELS`, default from the env), new
  command `models`.
- `up()`: `loaded_other()` = a model whose unit is active/activating and is
  not the selected one → print the switch, `systemctl_user("stop", unit)`;
  the healthy() shortcut applies only when the selected unit is the active
  one.
- `main()`: `owns_mode = not mode_on()` where `mode_on()` = any model unit
  active or any marker present.
- `leave_offline_mode()`: stop every model unit, `clear_marker()` for every
  model (loop over the table), restore.
- `status_lines()`/`models` output and the fetch hint per model; USAGE text.
- Build the check until green. Then every existing case still green.

## Task 3 — module (modules/nixos/offline-ai.nix)

- `models` attrset as in the spec; generate both units with
  `lib.mapAttrs'`; `Conflicts` = the other unit(s); reservations
  `services.memoryPressure.reservations.offline-ai = 24 GiB`,
  `.offline-ai-coder = 48 GiB`; gated drop-ins and system units list every
  marker; the wrapper exports `OFFLINE_AI_MODELS` (builtins.toJSON) and
  `OFFLINE_AI_DEFAULT_MODEL`, and keeps `OFFLINE_AI_UNIT/MODEL/RESERVATION/
  MODE_MARKER` for the default model (the smoke wrapper reads `OFFLINE_AI_UNIT`).
- Header comment: the table, why the coder is the fallback, both fetch hints.
- flake.nix: pass the two units' `unitConfig.Conflicts` and one gated drop-in
  text into tests/offline-ai.nix for the eval-level assertion (Task 1 wrote
  it; make it pass here).
- `nix eval --raw .#nixosConfigurations.tuxedo.config.system.build.toplevel.drvPath`
  rc 0; `nix build --no-link .#checks.x86_64-linux.offline-ai -L` green;
  `offline-ai-smoke` check still green (`.#checks.x86_64-linux.offline-ai-smoke`).

## Task 4 — ship

Commit with the full `Pre-push checklist:` block, `Type: risky` (ExecStart,
systemd.services, writeShellApplication in the diff; feature-vm.nix not
modified). Behavioural evidence = the harness cases named with their
assertion text plus the eval outputs; no model is loaded by any step. Push
as a separate command, open the PR with `gh pr create` (no `--base`), report
the PR URL. Do not merge.
