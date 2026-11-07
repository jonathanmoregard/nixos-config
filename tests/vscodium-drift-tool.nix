# vscodium-drift-tool: behavioural harness for the drift recorder/reporter
# that home/vscodium.nix runs from its activation entry and
# home/drift-analyzer.nix runs from the hourly probe.
#
# Not a VM lane: it boots nothing and drives the real wrapper against fixture
# settings files in a temp dir. Runs in seconds, so it sits beside
# kitty-scripts and rust-analyzer-devshell as a plain check derivation.
#
# Drives `driftTool` — the same derivation both call sites import — rather
# than the .py by path, for the reason that file's own header gives: a second
# copy drifts toward "looks observed, isn't". In particular the wrapper runs
# `python3 -I`, and isolated mode is load-bearing here. The first draft of
# this tool shipped without json5 in its closure and quarantined a perfectly
# valid settings.json as a result, so "the interpreter can import json5" is
# part of what must be proven, not a detail of how the test is invoked.
#
# What the assertions pin down, in the order the file walks them: an
# undeclared key survives and is queued for promotion; a declared key edited
# live is recorded as an override and the live file is never moved, rewritten
# or deleted; JSONC comments come back intact; store paths and the
# `claudeCode.` subtree produce no findings; a deleted declared key is NOT a
# finding (absent and never-written are the same state on disk); an
# unparseable file is reported as the user's to fix while an internal error is
# reported as ours; and a live-only key under a sensitive prefix is escalated
# apart from the cosmetic promotion queue.
#
# Run: nix build .#checks.x86_64-linux.vscodium-drift-tool -L
{ pkgs, driftTool }:

pkgs.runCommand "vscodium-drift-tool"
{
  nativeBuildInputs = [ pkgs.python3 pkgs.coreutils ];
} ''
  set -euo pipefail

  # The assertions shell out to the wrapper, so `--tool` names the deployed
  # binary. $HOME is set because tempfile honours TMPDIR, not HOME, but a
  # stray HOME lookup in a future assertion should not reach the builder's.
  export HOME=$PWD/home
  mkdir -p "$HOME"

  python3 ${./vscodium-drift-tool-assertions.py} \
    ${driftTool}/bin/vscodium-drift-tool 2>&1 | tee result.log

  # `pipefail` already fails the build on a non-zero runner, and the runner
  # exits non-zero on any FAIL. These two are the belt to that braces, for
  # the one shape neither catches: a runner that exits 0 without having
  # tested anything. Verified by pointing the assertions at a do-nothing
  # stub -- it dies on the first missing report instead of passing.
  if grep -q '^FAIL ' result.log; then
    echo "a case failed" >&2
    exit 1
  fi
  grep -qx 'all green' result.log || {
    echo "the assertion runner did not reach its verdict" >&2
    exit 1
  }

  touch $out
''
