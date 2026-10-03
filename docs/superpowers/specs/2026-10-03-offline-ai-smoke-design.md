# offline-ai weekly smoke test — design

Date: 2026-10-03. Repo: nixos-config (`modules/nixos/offline-ai.nix`, `scripts/`, `tests/`).
Companion in `~/.claude`: a SessionStart health hook that reads the result file.

## Why

The local model is an emergency tool: it is loaded a few times a month at most, and
the deployed unit path (reservation, eviction drop-ins, `-c 65536`, MTP) had never been
exercised end to end as of 2026-10-03 — every Qwen3.6 run was an ad-hoc server. A
model that fails to load is discovered exactly when the network is gone. A weekly
smoke run loads the model through the real CLI, asks one trivial question, and reports
when it does not work.

## Behaviour

`offline-ai-smoke` (Python, stdlib only, `scripts/offline-ai-smoke.py`), run by a user
oneshot service from a daily user timer at 03:33 (±20 min, `Persistent=true`):

1. **Due?** Reads `$XDG_STATE_HOME/offline-ai/smoke.json`. If the last `ok` is younger
   than 6 days → exits 0 without running ("weekly", with a daily opportunity so a
   missed night is caught the next night, not a week later).
2. **Right moment?** Skips (status `skipped`, no toast) when on battery. Waits for the
   user to be idle ≥ 15 min (`xprintidle`; if it cannot be read, proceeds), polling
   every 5 min for at most 2 h; still active → `skipped`, try next night. Rationale:
   loading the model evicts voquill/local-stt/aggregator for the duration.
3. **Memory peace.** Runs the model step under `nix-memory-run -- …` (blocking): waits
   for a running nix build and keeps auto-deploy from starting one while the model
   holds 24 GiB.
4. **Ask.** Records whether the model was already up (`offline-ai status`). Runs
   `timeout -k 30 600 offline-ai "<prompt>"` with `OFFLINE_AI_READY_TIMEOUT=600`. The
   CLI enters offline mode if the server is down and leaves it in `finally`, however
   it ends; if the user already had the model up, the CLI leaves it alone and so does
   the smoke. Prompt: a fixed, non-medical sentence asking for the single word PONG.
5. **Judge.** `ok` iff exit 0 and stdout matches `\bPONG\b` (case-insensitive) within
   600 s. Otherwise `fail` with a reason: `exit 1` → model not loadable (stderr tail),
   `exit 2` → answer cut off, `124/137` → timeout, exit 0 without PONG → unexpected
   answer (first 200 chars kept). Wall time and the CLI's "model ready after N s" are
   recorded.
6. **Always clean up.** If the model was not up before and `offline-ai status` still
   shows it active after a failure (e.g. SIGKILL after the grace period), run
   `offline-ai down`.
7. **Report.** Writes `smoke.json` (`last_run`, `last_ok`, `status`, `reason`,
   `elapsed_s`, `model_ready_s`, `answer`, `exit_code`). `fail` → one journal line and
   `notify-send -u critical` ("offline-ai smoke FAILED: <reason>"). `ok`/`skipped` →
   journal only. A SessionStart hook in `~/.claude` (separate PR) announces `fail`, or
   no successful run in 10 days, to the agent and the operator; silent otherwise.

Exit code of the service: 0 for ok/skipped/not-due, 1 for fail (so `systemctl
--user status offline-ai-smoke` shows red and `OnFailure` could be attached later).

## Units (modules/nixos/offline-ai.nix)

- `systemd.user.services.offline-ai-smoke`: `Type=oneshot`, `TimeoutStartSec=3h`,
  `ConditionPathExists=<model>`, `ExecStart=<smoke>/bin/offline-ai-smoke`, PATH with
  the offline-ai wrapper, `xprintidle`, `libnotify`, `coreutils`, and
  `config.services.buildCoordination.runnerPackage` (nix-memory-run).
- `systemd.user.timers.offline-ai-smoke`: `OnCalendar=*-*-* 03:33:00`,
  `RandomizedDelaySec=20min`, `Persistent=true`, `WantedBy=timers.target`.
- Tunables are environment variables on the service with defaults in the script
  (`OFFLINE_AI_SMOKE_INTERVAL_DAYS=6`, `…_IDLE_MIN=15`, `…_WAIT_MAX_MIN=120`,
  `…_BUDGET_S=600`). No enable switch: the smoke ships on wherever offline-ai is.
- `system.build.offline-ai-smoke` exported for the check.

## Test (tests/offline-ai-smoke.nix, flake check `offline-ai-smoke`, no VM, no model)

Runs the built script against fakes on PATH: `offline-ai` (behaviour from env: answer
text, exit code, sleep, status output; records argv), `xprintidle` (idle ms from env),
`notify-send` (records argv), `nix-memory-run` (passthrough, records), `timeout`
(real coreutils), fake `power_supply` dir via `OFFLINE_AI_SMOKE_POWER_SUPPLY_DIR`,
`XDG_STATE_HOME` in the sandbox. Assertions (invariants, not restatements):

- last ok 2 days ago → no `offline-ai` call, exit 0, state unchanged apart from `last_check`.
- due + battery → `skipped`, no call, no notify.
- due + user active for the first two polls (poll interval set to 0.1 s via env) then
  idle → runs.
- due + idle + PONG → `ok`, `last_ok` set, no notify, `offline-ai` ran under
  `nix-memory-run`, no `down` call when the fake said the model was already up.
- answer without PONG → `fail` + `notify-send -u critical`, service exit 1.
- exit 1 / exit 2 / sleep past budget (budget set to 1 s) → `fail` with the matching
  reason; `offline-ai down` called when the model was not up before.
- the script never prints the model answer beyond 200 chars into the state file.

## Assumptions (correct me)

- Weekly cadence = "not more than 6 days since the last pass"; night = 03:33 local.
- Idle gate via `xprintidle` (X11 Cinnamon); on battery the night is skipped.
- Report channels: critical desktop toast + SessionStart hook; no email/TickTick.
- The prompt is non-medical so the citation gate never adds a turn.
- The smoke does not measure tokens/s; wall time and model-ready time are enough for
  "does it work".
