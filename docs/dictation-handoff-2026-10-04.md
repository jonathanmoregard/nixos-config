# Dictation path: state and pickup notes (2026-10-04)

Work on the local dictation path of `tuxedo` was paused on 2026-10-04 with several parts in flight. This
page says where each part stands and what to do next. It lives on the branch `docs/dictation-handoff` only;
it is a handoff note, not documentation of a shipped feature.

The dictation path: the Voquill desktop app records speech and posts the clip to a router
(`local-stt.service`, `scripts/local-stt-router.py`, 127.0.0.1:8766), which forwards it to whisper.cpp servers
(`local-stt-general-short` 8762, `local-stt-general` 8763, `local-stt-swedish` 8764).

## What was asked

1. A NixOS deploy must never cut a dictation in flight (it did on 2026-10-04, when the deploy of #310
   restarted Voquill and the speech units).
2. Streaming transcription, proven end to end on real dictation recordings.
3. Research: can fine-tuning make transcription faster?
4. Mixed Swedish and English speech ("Swinglish") should be handled well.

## Shipped

- #307: short clips go to a server with a 15-second encoder window.
- #310: CPU and IO priority for the speech units, builds yield, `/v1/prepare` holds the performance power
  profile at record start. Deployed and verified 2026-10-04.

## PR #315: ready, waiting for CI and the merge click

Branch `feat/dictation-deploy-safe`, three commits.

- **A deploy no longer cuts a dictation.** Voquill is kept across switches (`X-RestartIfChanged = false`). A
  socket unit owns port 8766, so requests queue across a router restart. The router finishes requests in
  flight on SIGTERM. A request waits for a whisper server that is being restarted and sends the audio again.
  The four speech units restart in place. The speech units are NixOS-level user units, restarted by
  `switch-to-configuration`; only Voquill goes through home-manager's `sd-switch`.
- **Dictation corpus keeper.** Voquill keeps audio for its newest 20 transcriptions only. A new unit copies
  each clip and its database row into `~/.local/share/stt-corpus`, local only, folder mode 0700, at most 400
  clips (`services.sttCorpus.maxClips`), oldest dropped. It only reads Voquill's data.
- **Close-out review fixes.** A changed Voquill table fails the keeper loudly; a burst of recordings no longer
  trips the start limit; reading Voquill's WAL database at rest leaves no files in its folder.

Local gates on the head commit: `stt-corpus`, `vm-local-stt` (four subtests), `local-stt`, tuxedo toplevel
eval and the deterministic gate all pass. `vm-base` and `offline-ai` passed on the first commit.

**Why CI is slow.** The Cachix cache was deleted and recreated on 2026-10-04 (see #312, #317, #318). The job
`build dellan toplevel` now compiles `codex-0.149.0` from source and runs for more than two hours. That is
independent of this PR.

**Before merging.** The deploy of #315 itself restarts the old router one last time, so the merge should not
happen in the middle of a dictation.

**After merging.** The deploy runs by itself (`nixos-deploy.service`). Then run the smoke script kept in the
local notes (`smoke-dictation-deploy-safe.sh`): socket active and handed to the router, units restart in place,
Voquill not restarted by the switch, the deployed router drains a request in flight, keeper triggers armed and
the corpus intact. Then remove the worktree and tick criteria 1 and 2 in the mission notes.

Lanes `local-stt`, `ai-throttle`, `vm-local-stt` and `stt-corpus` are not in the CI matrix. Adding them is an
open decision.

## Follow-up found in review: the audio stack

`pipewire`, `pipewire-pulse` and `wireplumber` are NixOS user units too. A nixpkgs bump that changes them lets
the switch stop them, which would cut a recording in progress. Not fixed yet. Next step: a VM test that
switches between generations with a changed pipewire unit, then keep those units across switches.

## Research results

- **Fine-tuning for speed.** Fine-tuning does not make a model faster by itself; it makes a faster setup
  accurate enough to use. The levers, in order of promise: a smaller audio context (already live for English);
  a different engine (Parakeet-TDT v3 is published as 7 to 10 times faster than full-window turbo on an AMD
  integrated GPU and also runs on CPU; its Swedish is weak; a Swedish-only fine-tune exists); an audio-context
  fine-tune of turbo (an experiment, needs a rented GPU, nothing published for turbo); a fine-tune on one
  speaker (unproven for typical speech). Recommendation: no GPU spend now; measure Parakeet on the harness
  first.
- **Swinglish.** kb-whisper renders other languages as Swedish by design. Candidates: route to kb-whisper only
  when Swedish is detected with high confidence (threshold as an input), and route per segment inside the
  streaming path. Nothing is published on Swedish-English mixing for the alternative models. There are no
  real Swedish or mixed recordings yet, so nothing could be measured on real speech.

## Streaming: prototype and harness exist, results not reviewed

The intended design: a bridge in the router cuts the incoming audio at pauses, transcribes each closed segment
with the existing routing while recording continues, and transcribes only the tail at stop, so the wait after
stop no longer grows with clip length. The router gets a WebSocket endpoint; Voquill gets a new transcription
session that streams to it and falls back to the batch request with the full audio on any failure. Voquill's
client already has streaming sessions for cloud providers, so the client side is one new session type.

A prototype bridge and an end-to-end harness were written and run over 62 clips (41 real-voice clips, 15
synthetic Swedish, 6 composites). The agent that built them stopped before writing its design note, and nobody
has reviewed the numbers. Unreviewed figures from its summary, word error against machine-made references:

| path | word error | wait after stop, p90, clips over 15 s (simulated) |
|---|---|---|
| batch, as in production | 10.3% | grows with clip length |
| streaming, best configurations | about 6% | about 1 s |

In the best configurations two clips still lost a run of two or more words at a cut, so the "no dropped words
at a cut" bar is not met yet. Twelve experiment plans cover pause detection, cut rules, packing, context,
language window and hold-back.

Next steps for streaming:

1. Review the harness and its results; rerun the best configurations with real-time pacing.
2. Fix the remaining dropped-word cuts, then write the design note: cut rules as inputs, routing rule, protocol.
3. Build the endpoint in the router with lane tests (after #315 merges; it touches the same files), then the
   Voquill session, then rebuild Voquill in a separate target directory and swap it when no dictation is in
   flight.

## Where the working material is

Local to the machine, not in any repository:

- `~/.local/state/claude-tasks/offline-ai/`: `mission.md` (acceptance criteria), `progress.md` (log),
  `session-constraints.md` (standing directives), `research-finetune-speed.md`, `research-swinglish.md`,
  `streaming/` (harness, prototype, plans, results), `smoke-dictation-deploy-safe.sh`, `corpus-sync.py`.
- `~/.local/share/stt-corpus/`: the recordings corpus. Until #315 deploys, new clips are copied only by a
  manual run of `corpus-sync.py`.

Recordings and transcript text stay on the machine and never go into a repository.

## Open decisions

- Add the four lanes above to CI?
- Trial a second inference engine (Parakeet) and, if it wins, adopt it?
- Design for keeping the audio stack across switches (updates would then apply at the next login).
