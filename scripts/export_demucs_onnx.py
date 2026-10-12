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
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    bag, core, sources, segment = load_demucs(args.model)
    print(f"[modelo] {args.model}: fontes={sources} segmento={segment}")
    net = make_core_net(core)
    path = out / "HTDemucs.onnx"
    export(net, segment, path, args.opset)
    origin = f"{args.model} via torch.onnx (opset {args.opset})"
    add_metadata(path, sources, segment, origin)

    snr = check_onnx(path, bag, segment, len(sources), test_signal(args.seconds))
    if snr < args.min_snr:
        raise SystemExit(f"ONNX reprovado: SNR {snr:.1f} dB < {args.min_snr}")

    T = frames_for(segment)
    contract = {
        "contract": CONTRACT, "origin": origin, "sources": sources, "sample_rate": SAMPLE_RATE,
        "nfft": NFFT, "hop": HOP, "segment_samples": segment, "frames": T,
        "inputs": {"mag": [1, 4, NFFT // 2, T], "mix": [1, 2, segment]},
        "outputs": {"spec_out": [1, len(sources), 4, NFFT // 2, T], "time_out": [1, len(sources), 2, segment]},
        "bytes": path.stat().st_size, "snr_db": round(snr, 1),
    }
    (out / "contract-onnx.json").write_text(json.dumps(contract, indent=2))
    print("[ok]", json.dumps(contract))


if __name__ == "__main__":
    sys.exit(main())
