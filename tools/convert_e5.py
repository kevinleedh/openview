#!/usr/bin/env python3
"""BUILD-TIME, ONE-TIME conversion of intfloat/e5-small-v2 → Core ML (.mlpackage).

This is the ONLY place Python/torch/transformers is used for the embedder, and its output (the .mlpackage
+ vocab.txt + a tiny verification JSON) is what the app bundles. The app itself does inference in pure
Swift + CoreML — no Python at runtime.

Design (per plan): the Core ML graph takes input_ids + attention_mask and outputs last_hidden_state ONLY.
Mean-pooling (attention-mask weighted) + L2 normalization happen in Swift — keeps the graph simple/stable
and the pooling trivially verifiable.

Outputs (to tools/artifacts/, NOT committed; the .mlpackage + vocab are copied into the app at make_app):
  - e5-small-v2.mlpackage   the Core ML model
  - e5-vocab.txt            BERT WordPiece vocab (for the Swift tokenizer)
  - e5-tokenizer.json       {do_lower_case, cls/sep/pad/unk ids, max_len}
  - e5-verify.json          test sentences → reference token ids + reference 384-d embedding (Swift checks both)

Run (build-time, in a venv/conda with torch+transformers+coremltools):
  /opt/homebrew/Caskroom/miniforge/base/bin/python3 tools/convert_e5.py
"""
import json
import os
import sys

import numpy as np
import torch

MODEL_ID = "intfloat/e5-small-v2"
SEQ = 256                                   # fixed sequence length (our windows ~700 chars ≈ <200 tokens)
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "artifacts")
os.makedirs(OUT, exist_ok=True)

# Sentences spanning query/passage prefixes + punctuation/casing/numbers — the equivalence + tokenizer test set.
TESTS = [
    "query: what does bert stand for?",
    "passage: BERT stands for Bidirectional Encoder Representations from Transformers.",
    "query: How many layers does BERT-large have (24)?",
    "passage: The Transformer uses multi-head attention with d_model = 512 and h = 8 heads.",
    "query: capital of France",
]


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def main():
    from transformers import AutoConfig, AutoModel, AutoTokenizer

    log(f"[1/5] loading {MODEL_ID} …")
    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    config = AutoConfig.from_pretrained(MODEL_ID)
    config.torchscript = True                      # transformers 5.x: set on config (untie weights, tuple out)
    # transformers 5.x's default SDPA attention masking isn't torch.jit.trace-able → force the classic eager path.
    model = AutoModel.from_pretrained(MODEL_ID, config=config, attn_implementation="eager").eval()

    # ── reference embeddings via the canonical mean-pool + normalize (what Swift must reproduce) ──
    def reference_embed(texts):
        enc = tok(texts, padding="max_length", truncation=True, max_length=SEQ, return_tensors="pt")
        with torch.no_grad():
            lhs = model(input_ids=enc["input_ids"], attention_mask=enc["attention_mask"])[0]
        mask = enc["attention_mask"].unsqueeze(-1).float()
        emb = (lhs * mask).sum(1) / mask.sum(1).clamp(min=1e-9)        # masked mean pool
        emb = torch.nn.functional.normalize(emb, p=2, dim=1)          # L2 normalize
        return emb.numpy(), enc

    log("[2/5] sanity: AutoModel mean-pool vs sentence-transformers (must be ~1.0) …")
    ref, _ = reference_embed(TESTS)
    try:
        from sentence_transformers import SentenceTransformer
        st = SentenceTransformer(MODEL_ID)
        st_emb = st.encode(TESTS, normalize_embeddings=True)
        cos = [float(np.dot(ref[i], st_emb[i])) for i in range(len(TESTS))]
        log("    cos(AutoModel-pool, sentence-transformers) =", [round(c, 4) for c in cos])
        assert min(cos) > 0.999, "pooling does NOT match sentence-transformers — fix before converting"
    except ImportError:
        log("    (sentence-transformers not present; skipping ST cross-check)")

    # ── trace + convert (graph outputs last_hidden_state only) ──
    log("[3/5] tracing + converting to Core ML …")

    class Wrap(torch.nn.Module):
        def __init__(self, m):
            super().__init__(); self.m = m
        def forward(self, input_ids, attention_mask):
            return self.m(input_ids=input_ids, attention_mask=attention_mask)[0]   # last_hidden_state

    wrap = Wrap(model).eval()
    ex_ids = torch.zeros(1, SEQ, dtype=torch.long)
    ex_mask = torch.ones(1, SEQ, dtype=torch.long)
    with torch.no_grad():
        traced = torch.jit.trace(wrap, (ex_ids, ex_mask), check_trace=False)

    import coremltools as ct
    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, SEQ), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="last_hidden_state")],
        minimum_deployment_target=ct.target.macOS14,
        compute_units=ct.ComputeUnit.ALL,
        convert_to="mlprogram",
    )
    pkg = os.path.join(OUT, "e5-small-v2.mlpackage")
    mlmodel.save(pkg)
    log(f"    saved {pkg}  ({_dirsize(pkg)//1024//1024} MB)")

    # ── numerical equivalence: CoreML+Swift-style pooling vs reference ──
    log("[4/5] verifying CoreML ≈ reference (cosine must be ≥ ~0.99) …")
    ref, enc = reference_embed(TESTS)
    coreml_cos = []
    for i, t in enumerate(TESTS):
        ids = enc["input_ids"][i:i+1].to(torch.int32).numpy()
        msk = enc["attention_mask"][i:i+1].to(torch.int32).numpy()
        out = mlmodel.predict({"input_ids": ids, "attention_mask": msk})
        lhs = list(out.values())[0][0]                      # [SEQ, 384]
        m = enc["attention_mask"][i].numpy().astype(np.float32)[:, None]
        emb = (lhs * m).sum(0) / max(m.sum(), 1e-9)
        emb = emb / (np.linalg.norm(emb) + 1e-12)
        coreml_cos.append(float(np.dot(emb, ref[i])))
    log("    cos(CoreML+pool, reference) =", [round(c, 4) for c in coreml_cos])
    ok = min(coreml_cos) >= 0.99
    log(f"    EQUIVALENCE {'PASS ✅' if ok else 'FAIL ❌'} (min cos {min(coreml_cos):.4f})")

    # ── export tokenizer + verification artifacts for the Swift side ──
    log("[5/5] exporting vocab + tokenizer config + verification vectors …")
    vocab = tok.get_vocab()
    inv = [None] * (max(vocab.values()) + 1)
    for k, v in vocab.items():
        inv[v] = k
    with open(os.path.join(OUT, "e5-vocab.txt"), "w") as f:
        f.write("\n".join(tok_id if tok_id is not None else "[UNUSED]" for tok_id in inv))
    cfg = {
        "do_lower_case": bool(getattr(tok, "do_lower_case", True)),
        "cls_id": tok.cls_token_id, "sep_id": tok.sep_token_id,
        "pad_id": tok.pad_token_id, "unk_id": tok.unk_token_id,
        "max_len": SEQ, "vocab_size": len(inv),
    }
    json.dump(cfg, open(os.path.join(OUT, "e5-tokenizer.json"), "w"), indent=2)
    verify = []
    for i, t in enumerate(TESTS):
        ids = tok(t, truncation=True, max_length=SEQ)["input_ids"]
        verify.append({"text": t, "ids": ids, "embedding": [round(float(x), 6) for x in ref[i]]})
    json.dump(verify, open(os.path.join(OUT, "e5-verify.json"), "w"))
    log(f"    cfg = {cfg}")
    log("DONE." if ok else "DONE (equivalence FAILED — do not ship).")
    return 0 if ok else 1


def _dirsize(path):
    total = 0
    for root, _, files in os.walk(path):
        for fn in files:
            total += os.path.getsize(os.path.join(root, fn))
    return total


if __name__ == "__main__":
    raise SystemExit(main())
