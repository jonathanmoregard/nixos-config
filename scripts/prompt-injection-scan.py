"""Local prompt-injection classifier (ProtectAI DeBERTa-v3 v2, ONNX).

Packaged by overlays/prompt-injection-scan.nix, which pins the model files
and points PROMPT_INJECTION_MODEL_DIR at them. Runs fully offline: no
network, no model download at runtime, no torch.

Same contract as the RSI plugin's scan_content.py, which delegates here:

    prompt-injection-scan --text "..."      | --file PATH | stdin
    exit 0  clean     (text echoed on stdout)
    exit 1  injection (warning + score on stderr, text echoed on stdout)
    exit 2  scanner unusable (bad input, model missing) - caller must treat
            the text as UNSCANNED

The model sees at most 512 tokens, so long input is scored in overlapping
windows and the verdict is the highest window score. Truncating instead
(what llm-guard's MatchType.FULL does) would let a payload placed after the
first few hundred tokens pass unseen.

Input may hold several independent documents separated by lines that are
just `---` (the permission-ledger aggregator joins its samples that way).
Each document is windowed and scored on its own: in one shared window, a
few benign neighbours dilute a payload's score far below threshold.
"""
import argparse
import os
import re
import sys

MAX_TOKENS = 512
STRIDE = 448
DOC_SEPARATOR = re.compile(r"^[ \t]*---[ \t]*$", re.MULTILINE)
BATCH = 1


def fail(msg):
    print("prompt-injection-scan: " + msg, file=sys.stderr)
    sys.exit(2)


def windows(ids, size, stride):
    """Overlapping slices covering every id; a short input is one window."""
    if len(ids) <= size:
        return [ids]
    out = []
    start = 0
    while True:
        out.append(ids[start:start + size])
        if start + size >= len(ids):
            return out
        start += stride


def load(model_dir):
    import numpy as np
    import onnxruntime as ort
    from tokenizers import Tokenizer

    tok = Tokenizer.from_file(os.path.join(model_dir, "tokenizer.json"))
    tok.no_truncation()
    tok.no_padding()
    opts = ort.SessionOptions()
    opts.log_severity_level = 3
    sess = ort.InferenceSession(
        os.path.join(model_dir, "model.onnx"),
        sess_options=opts,
        providers=["CPUExecutionProvider"],
    )
    return np, tok, sess


def score(text, model_dir):
    """Highest INJECTION probability over every document's windows, and its index."""
    np, tok, sess = load(model_dir)
    cls_id = tok.token_to_id("[CLS]")
    sep_id = tok.token_to_id("[SEP]")
    pad_id = tok.token_to_id("[PAD]")
    if cls_id is None or sep_id is None or pad_id is None:
        fail("tokenizer lacks [CLS]/[SEP]/[PAD]")
    chunks = []
    for doc in DOC_SEPARATOR.split(text):
        if not doc.strip():
            continue
        ids = tok.encode(doc, add_special_tokens=False).ids
        chunks += [[cls_id] + w + [sep_id] for w in windows(ids, MAX_TOKENS - 2, STRIDE)]
    if not chunks:
        return 0.0, 0, 0
    input_names = {i.name for i in sess.get_inputs()}

    best, best_at = 0.0, 0
    for b in range(0, len(chunks), BATCH):
        batch = chunks[b:b + BATCH]
        width = max(len(c) for c in batch)
        input_ids = np.full((len(batch), width), pad_id, dtype=np.int64)
        mask = np.zeros((len(batch), width), dtype=np.int64)
        for row, c in enumerate(batch):
            input_ids[row, :len(c)] = c
            mask[row, :len(c)] = 1
        feed = {"input_ids": input_ids, "attention_mask": mask}
        if "token_type_ids" in input_names:
            feed["token_type_ids"] = np.zeros_like(input_ids)
        logits = sess.run(None, feed)[0]
        exp = np.exp(logits - logits.max(axis=1, keepdims=True))
        probs = (exp / exp.sum(axis=1, keepdims=True))[:, 1]
        i = int(probs.argmax())
        if float(probs[i]) > best:
            best, best_at = float(probs[i]), b + i
    return best, best_at, len(chunks)


def main():
    parser = argparse.ArgumentParser(description="Scan text for prompt injection")
    parser.add_argument("--file", help="Path to file to scan")
    parser.add_argument("--text", help="Inline text to scan")
    parser.add_argument("--threshold", type=float, default=0.5,
                        help="Detection threshold (0-1)")
    args = parser.parse_args()

    if args.file:
        try:
            with open(args.file, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as exc:
            fail("cannot read %s: %s" % (args.file, exc))
    elif args.text is not None:
        text = args.text
    elif not sys.stdin.isatty():
        text = sys.stdin.read()
    else:
        fail("no input; use --file, --text, or pipe to stdin")

    if not text.strip():
        print(text)
        sys.exit(0)

    model_dir = os.environ.get("PROMPT_INJECTION_MODEL_DIR", "")
    if not model_dir or not os.path.isfile(os.path.join(model_dir, "model.onnx")):
        fail("PROMPT_INJECTION_MODEL_DIR does not hold model.onnx: %r" % model_dir)

    try:
        best, at, n = score(text, model_dir)
    except Exception as exc:  # any inference failure means "not scanned"
        fail("inference failed: %s: %s" % (type(exc).__name__, exc))

    print(text)
    if best >= args.threshold:
        print(
            "WARNING: Prompt injection detected (score=%.2f, window %d of %d). "
            "Content may contain adversarial instructions." % (best, at + 1, n),
            file=sys.stderr,
        )
        sys.exit(1)
    sys.exit(0)


if __name__ == "__main__":
    main()
