# `pkgs.prompt-injection-scan` — a local, offline prompt-injection
# classifier for the ~/.claude batch jobs: the permission-ledger aggregator's
# injection pass and the RSI plugin's scan_content.py (which delegates to
# this binary when it is on PATH).
#
# Model: ProtectAI deberta-v3-base-prompt-injection-v2 (Apache-2.0, ungated)
# — the same classifier llm-guard's PromptInjection scanner runs — using the
# ONNX export the model repo itself publishes. Pinned to a Hugging Face
# revision as fixed-output fetches, so it is in the store before any job
# runs and nothing is downloaded at runtime. Runtime is onnxruntime +
# tokenizers; no torch.
#
# Why not llm-guard itself: not in nixpkgs, drags in torch + presidio +
# spaCy, and downloads its model on first use — which a cron job without a
# model cache cannot rely on.
#
# Why not PIGuard (leolee99/PIGuard, MIT), which its paper reports as far
# less trigger-word-biased: measured on the 613 unique real permission-ledger
# tool-argument texts (2026-10-02) it flagged 233 at 0.5; this model 33.
#
# Why not the injection-scanner repo (research-agent / futuresearch-gate):
# its layers are hosted (Lakera Guard on a 10k/month quota shared with the
# fleet, plus a paid-API honeypot). Sending captured tool arguments — which
# may hold credentials — to third parties nightly is the wrong trade for a
# scan whose result annotates a digest.
#
# Verified by checks.<system>.prompt-injection-scan.
final: prev:
let
  rev = "90c9989b1a342275dd0d1a95aad283c04e075671";
  hf = file: hash: prev.fetchurl {
    url = "https://huggingface.co/protectai/deberta-v3-base-prompt-injection-v2/resolve/${rev}/onnx/${file}";
    inherit hash;
  };
  model = prev.linkFarm "deberta-v3-base-prompt-injection-v2-onnx" [
    { name = "model.onnx"; path = hf "model.onnx" "sha256-8Op/I592Wu2958nhY6fLOKecW4hT0/dttRUhcgR7Iow="; }
    { name = "tokenizer.json"; path = hf "tokenizer.json" "sha256-dS/l8NVnitVj4b0uzB3fejun4gJNCsHboacpdeJt/y8="; }
  ];
  python = prev.python3.withPackages (ps: [ ps.numpy ps.onnxruntime ps.tokenizers ]);
in
{
  prompt-injection-scan = prev.runCommand "prompt-injection-scan" {
    nativeBuildInputs = [ prev.makeWrapper ];
    passthru = { inherit model; };
    meta.mainProgram = "prompt-injection-scan";
  } ''
    mkdir -p $out/bin $out/libexec
    cp ${../scripts/prompt-injection-scan.py} $out/libexec/prompt-injection-scan.py
    makeWrapper ${python}/bin/python3 $out/bin/prompt-injection-scan \
      --add-flags $out/libexec/prompt-injection-scan.py \
      --set PROMPT_INJECTION_MODEL_DIR ${model}
  '';
}
