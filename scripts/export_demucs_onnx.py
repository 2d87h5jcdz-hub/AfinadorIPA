#!/usr/bin/env python3
"""
Exporta o HTDemucs para ONNX (versão Android do Pestana: ONNX Runtime).

Mesmo contrato do Core ML ("afinador-demucs-v1", ver convert_demucs.py): a STFT/iSTFT e o
overlap-add ficam FORA do modelo (no app, em Kotlin), o grafo recebe
    mag (1, 4, 2048, T) e mix (1, 2, L)
e devolve
    spec_out (1, S, 4, 2048, T) e time_out (1, S, 2, L).

Verificação: roda o .onnx no onnxruntime através da MESMA cadeia de DSP do app
(host_separate, espelho do Kotlin) e compara com o demucs original em PyTorch.

Uso:  python scripts/export_demucs_onnx.py --model htdemucs_6s --out build/onnx
Saída: <out>/HTDemucs.onnx e <out>/contract-onnx.json
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from convert_demucs import (  # noqa: E402
    CONTRACT, HOP, NFFT, SAMPLE_RATE, frames_for, host_separate, load_demucs, make_core_net,
    reference_separation, snr_db, test_signal,
)


ATTN_CHUNK = 256


def patch_attention(chunk: int = ATTN_CHUNK):
    """Atenção em blocos de consultas (matematicamente igual): o HTDemucs tem ~2700 tokens e a
    matriz de atenção inteira (8 cabeças × 2688²) passava de 200 MB por operação — no celular o
    pico de memória chegava a ~2,3 GB e o Android fechava o app. Em blocos de 256 consultas,
    cada pedaço tem ~22 MB."""
    import torch
    import torch.nn.functional as F

    original = torch.nn.MultiheadAttention.forward

    def forward(self, query, key, value, key_padding_mask=None, need_weights=True, attn_mask=None,
                average_attn_weights=True, is_causal=False):
        if (not self.batch_first or key_padding_mask is not None or attn_mask is not None
                or not self._qkv_same_embed_dim or self.in_proj_bias is None or self.bias_k is not None):
            return original(self, query, key, value, key_padding_mask=key_padding_mask, need_weights=need_weights,
                            attn_mask=attn_mask, average_attn_weights=average_attn_weights, is_causal=is_causal)
        E, H = self.embed_dim, self.num_heads
        D = E // H
        W, b = self.in_proj_weight, self.in_proj_bias
        q = F.linear(query, W[:E], b[:E])
        k = F.linear(key, W[E:2 * E], b[E:2 * E])
        v = F.linear(value, W[2 * E:], b[2 * E:])
        B, Lq, _ = q.shape
        Lk = k.shape[1]
        q = q.reshape(B, Lq, H, D).transpose(1, 2) * (D ** -0.5)
        kt = k.reshape(B, Lk, H, D).permute(0, 2, 3, 1)
        v = v.reshape(B, Lk, H, D).transpose(1, 2)
        outs = []
        for s0 in range(0, Lq, chunk):
            a = torch.softmax(torch.matmul(q[:, :, s0:s0 + chunk], kt), dim=-1)
            outs.append(torch.matmul(a, v))
        o = torch.cat(outs, dim=2).transpose(1, 2).reshape(B, Lq, E)
        return self.out_proj(o), None

    # Confere com a implementação original antes de usar.
    torch.manual_seed(0)
    m = torch.nn.MultiheadAttention(64, 8, batch_first=True).eval()
    x, y = torch.randn(1, 600, 64), torch.randn(1, 300, 64)
    with torch.no_grad():
        ref = original(m, x, y, y, need_weights=False)[0]
        got = forward(m, x, y, y, need_weights=False)[0]
    err = (ref - got).abs().max().item()
    assert err < 1e-5, f"atenção em blocos diverge: {err}"
    print(f"[atenção] em blocos de {chunk} (erro {err:.1e})")
    torch.nn.MultiheadAttention.forward = forward


def peak_memory_mb(path: Path, segment: int, threads: int = 2) -> float:
    """Pico de memória (RSS) de UMA inferência no onnxruntime, com as opções do app, num processo à parte."""
    import subprocess
    code = f"""
import resource, numpy as np, onnxruntime as ort
so = ort.SessionOptions(); so.enable_cpu_mem_arena = False; so.enable_mem_pattern = False
so.intra_op_num_threads = {threads}; so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
s = ort.InferenceSession({str(path)!r}, so, providers=['CPUExecutionProvider'])
T = -(-{segment} // 1024)
s.run(None, {{'mag': np.random.randn(1, 4, 2048, T).astype(np.float32), 'mix': np.random.randn(1, 2, {segment}).astype(np.float32)}})
print(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 1024)
"""
    out = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True, check=True).stdout
    return float(out.strip().splitlines()[-1])


def export(net, segment: int, path: Path, opset: int):
    import torch

    try:  # o caminho rápido do MultiheadAttention não exporta
        torch.backends.mha.set_fastpath_enabled(False)
    except Exception:
        pass
    T = frames_for(segment)
    mag = torch.zeros(1, 4, NFFT // 2, T)
    mix = torch.zeros(1, 2, segment)
    with torch.no_grad():
        torch.onnx.export(
            net, (mag, mix), str(path),
            input_names=["mag", "mix"], output_names=["spec_out", "time_out"],
            opset_version=opset, do_constant_folding=True, dynamo=False,
        )
    print(f"[onnx] exportado {path} ({path.stat().st_size / 1e6:.1f} MB)")


def add_metadata(path: Path, sources, segment, origin):
    import onnx

    m = onnx.load(str(path))
    meta = {
        "contract": CONTRACT, "sources": ",".join(sources), "samplerate": str(SAMPLE_RATE),
        "nfft": str(NFFT), "hop": str(HOP), "segment_samples": str(segment), "origin": origin,
        "license": "MIT (facebookresearch/demucs)",
    }
    del m.metadata_props[:]
    for k, v in meta.items():
        p = m.metadata_props.add()
        p.key, p.value = k, v
    onnx.checker.check_model(m)
    onnx.save(m, str(path))


def check_onnx(path: Path, bag, segment, n_sources, mix) -> float:
    import onnxruntime as ort

    sess = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    print("[onnx] entradas:", [(i.name, i.shape) for i in sess.get_inputs()])
    print("[onnx] saídas:", [(o.name, o.shape) for o in sess.get_outputs()])

    def predict(mag, seg):
        a, b = sess.run(["spec_out", "time_out"], {"mag": mag.astype(np.float32), "mix": seg.astype(np.float32)})
        return a, b

    ours = host_separate(mix, predict, segment, n_sources)
    ref = reference_separation(bag, mix)
    snr = snr_db(ref, ours)
    print(f"[verificação] ONNX Runtime + DSP do app vs. demucs PyTorch: SNR {snr:.1f} dB")
    return snr


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default="htdemucs_6s", choices=["htdemucs", "htdemucs_6s"])
    ap.add_argument("--out", default="build/onnx")
    ap.add_argument("--opset", type=int, default=17)
    ap.add_argument("--min-snr", type=float, default=35.0)
    ap.add_argument("--seconds", type=float, default=18.0)
    ap.add_argument("--full-attention", action="store_true", help="exporta sem a atenção em blocos (mais memória)")
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    bag, core, sources, segment = load_demucs(args.model)
    print(f"[modelo] {args.model}: fontes={sources} segmento={segment}")
    net = make_core_net(core)
    path = out / "HTDemucs.onnx"
    if not args.full_attention:
        patch_attention()
    export(net, segment, path, args.opset)
    origin = f"{args.model} via torch.onnx (opset {args.opset})"
    add_metadata(path, sources, segment, origin)

    snr = check_onnx(path, bag, segment, len(sources), test_signal(args.seconds))
    if snr < args.min_snr:
        raise SystemExit(f"ONNX reprovado: SNR {snr:.1f} dB < {args.min_snr}")

    peak = peak_memory_mb(path, segment)
    print(f"[memória] pico de uma inferência (2 threads): {peak:.0f} MB")
    T = frames_for(segment)
    contract = {
        "contract": CONTRACT, "origin": origin, "sources": sources, "sample_rate": SAMPLE_RATE,
        "nfft": NFFT, "hop": HOP, "segment_samples": segment, "frames": T,
        "inputs": {"mag": [1, 4, NFFT // 2, T], "mix": [1, 2, segment]},
        "outputs": {"spec_out": [1, len(sources), 4, NFFT // 2, T], "time_out": [1, len(sources), 2, segment]},
        "bytes": path.stat().st_size, "snr_db": round(snr, 1), "peak_mb": round(peak),
    }
    (out / "contract-onnx.json").write_text(json.dumps(contract, indent=2))
    print("[ok]", json.dumps(contract))


if __name__ == "__main__":
    sys.exit(main())
