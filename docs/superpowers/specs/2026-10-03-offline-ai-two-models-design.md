# offline-ai: two models, the small one by default, the coder on demand

Date: 2026-10-03. Operator ask: "why not have offline-ai support both coder and
the smaller model? With the smaller one being default, and the coder one
possible in case the smaller one stumbles? I have loads of disc."

## What exists

- One model: Qwen3.6-35B-A3B (Unsloth UD-Q4_K_M, 22.7 GB, iGPU, 64k context,
  MTP drafting), unit `offline-ai-llm.service`, memory reservation
  `offline-ai` = 24 GiB, marker `/run/memory-reserve/offline-ai` that the
  evicted services carry as `ConditionPathExists=!marker`.
- Qwen3-Coder-Next (Q4_K_M, four parts, 46 GB) is on disk at
  `~/.local/share/llm-models/qwen3-coder-next/Qwen3-Coder-Next-Q4_K_M/` and
  ran under the old unit (CPU-only, `-ngl 0`, 32k context, 12-13 tok/s, 45 GiB
  reservation) before the 2026-10-02 switch.
- `scripts/offline-ai.py` reads one unit, model path, reservation and marker
  from the environment; `tests/offline-ai.nix` drives it against fakes.
- `offline-ai-smoke` (weekly) calls the CLI with no model argument and watches
  `offline-ai-llm.service`.
- Standing rules: never two models loaded at once; builds, checks and CI never
  load a model; the small model stays the default.

## Design

### Model table (module)

`modules/nixos/offline-ai.nix` keeps a `models` attrset, name → `{ path, unit,
reservation, bytes, flags, fetch }`:

| name  | unit                          | reservation (GiB)  | flags                                                              |
|-------|-------------------------------|--------------------|--------------------------------------------------------------------|
| small | `offline-ai-llm.service`      | `offline-ai` 24    | today's: `-ngl 99 -t 8 -c 65536 -np 1 --jinja -fa on --spec-type draft-mtp --reasoning-budget 8192` |
| coder | `offline-ai-llm-coder.service`| `offline-ai-coder` 48 | `-ngl 0 -t 8 -c 32768 -np 1 --jinja -fa on`                     |

Both units serve `127.0.0.1:8717`, carry `CPUWeight=1000`, `Restart=no`,
`ConditionPathExists=<their model>`, start/stop their own reservation in
`ExecStartPre`/`ExecStopPost`, and each lists the other in `Conflicts=`, so
systemd itself stops one when the other starts: "never two loaded" is enforced
below the CLI. The small model keeps its unit name, so the smoke test, the
harness and every document that names `offline-ai-llm.service` stay true.

Two reservations mean two markers. Every gated service's drop-in carries one
`ConditionPathExists=!<marker>` line per model; the gated system units list
both. The polkit rules already cover any `memory-reserve-*` unit the module
declares (memory-pressure.nix) and the evicted system units.

Fetch hints: small as today; coder
`hf download Qwen/Qwen3-Coder-Next-GGUF --include 'Qwen3-Coder-Next-Q4_K_M/*' --local-dir ~/.local/share/llm-models/qwen3-coder-next`.

### CLI

The wrapper exports `OFFLINE_AI_MODELS`, a JSON object
`{ "<name>": { "unit", "model", "reservation", "marker", "fetch" } }`, and
`OFFLINE_AI_DEFAULT_MODEL=small`. Without `OFFLINE_AI_MODELS` the CLI builds a
one-entry table named `small` from `OFFLINE_AI_UNIT`, `OFFLINE_AI_MODEL`,
`OFFLINE_AI_RESERVATION` and `OFFLINE_AI_MODE_MARKER`, so every existing
harness case runs unchanged.

- `--model NAME` on every form (`offline-ai --model coder "question"`,
  `offline-ai --model coder up`). Unknown name: exit 1 naming the models.
  Selecting a model sets the run's unit, model path, reservation and marker.
- `offline-ai models`: one line per model — name, loaded/not loaded, on disk or
  not, default marked.
- `up`: the selected unit active and answering → nothing to do. Another
  model's unit active or activating → say "switching from X to Y", stop it
  (its `ExecStopPost` drops its reservation), then make room and start as
  today. The missing-model message names the selected model's fetch hint.
- Mode ownership: a conversation entered from default mode (no model unit
  active, no marker) enters and leaves the mode as today. One started while
  the mode is on (after `up`, or with another model loaded) only switches
  models; the model it loaded stays until `down` or the next `--model`.
- `down`: stop the library, stop every model unit, clear every marker,
  restore. Exit 0 only when all of that succeeded.
- `status`: "model server: ready (coder)" or "model server: inactive"; a
  `models:` line as in `offline-ai models`.
- `USAGE` documents `--model`, `models`, and that the coder is the fallback
  "when the small one stumbles" (slower: CPU-only, about 12 tok/s, half the
  context).

### Memory

The coder's 48 GiB reservation leaves builds at the minimum budget while it
is loaded (62 GiB RAM − 48 − 12 desktop), as before the 2026-10-02 switch.
`make_room` and the swap arithmetic already size from the model's bytes on
disk (the split parts are summed), so a 46 GB load gets the same treatment
the 23 GB one does.

### Out of scope

Automatic escalation ("the small model stumbled, retry with the coder"),
mid-conversation switching, a third model. The 27B weights stay on disk
unused; adding them is one more row in the table.

## Testing

`tests/offline-ai.nix` (fake systemctl, no model, seconds), new cases:

1. default run loads `offline-ai-llm.service`; `--model coder` loads
   `offline-ai-llm-coder.service` (the fake records `start <unit>`);
2. with the small unit active, `--model coder up` records
   `stop offline-ai-llm.service` before `start offline-ai-llm-coder.service`
   and the small marker is gone;
3. a `--model coder "question"` while the mode is on (after `up`) leaves the
   coder unit active afterwards (mode stays on); one from default mode
   leaves nothing loaded;
4. `down` with the coder loaded stops it, clears both markers, restores;
5. `--model nope` exits 1 and names `small` and `coder`;
6. `status` and `models` name the loaded model;
7. every existing single-model case passes unchanged (no `OFFLINE_AI_MODELS`).

Eval-level invariant, asserted in the same check from values the flake
passes in: tuxedo's two units name each other in `Conflicts=`, and the gated
drop-in text carries both markers.

The smoke harness (`tests/offline-ai-smoke.nix`) is untouched: the smoke's
CLI call takes the default model.

Host evidence after deploy (no model loaded by any build): `offline-ai models`
lists both with the coder on disk; `systemctl --user cat
offline-ai-llm-coder.service` shows the Conflicts line and the four-part
model path. Loading the coder for real is the operator's call
(`offline-ai --model coder up`).
