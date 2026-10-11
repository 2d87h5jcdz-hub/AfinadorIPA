#!/usr/bin/env python3
"""
Gera o modelo Core ML do separador de instrumentos (Demucs v4 / HTDemucs, Meta, licença MIT)
no formato que Afinador/Practice/DemucsSeparator.swift espera.

CONTRATO (afinador-demucs-v1) — igual ao das conversões públicas schism-audio/htdemucs*-coreml:

  Áudio: 44 100 Hz, estéreo, float32. Um "segmento" = L amostras (htdemucs: L = 343 980 = 7,8 s).
  STFT/iSTFT ficam FORA do modelo (no app, com Accelerate). n_fft = 4096, hop = 1024,
  janela Hann periódica, normalização 1/sqrt(n_fft), T = ceil(L / hop) quadros (336).

  Entradas
    mag      (1, 4, 2048, T)  float32  espectrograma complexo-como-canais do segmento:
                                       canais [esq_re, esq_im, dir_re, dir_im], bins 0…2047
    mix      (1, 2, L)        float32  forma de onda do segmento
  Saídas
    spec_out (1, S, 4, 2048, T)        espectrograma de cada fonte (mesmo layout de `mag`)
    time_out (1, S, 2, L)              ramo temporal de cada fonte
  Fonte s = iSTFT(spec_out[s]) + time_out[s].

  Metadados (user_defined_metadata): sources="drums,bass,other,vocals[,guitar,piano]",
  samplerate, nfft, hop, segment_samples, contract="afinador-demucs-v1".

  A normalização por segmento (média/desvio) fica DENTRO do grafo, como em HTDemucs.forward.
  A normalização global da música (separate.py do demucs) e o overlap-add de 25 % com janela
  triangular ficam no app.

Fontes do modelo (--source):
  convert      baixa os pesos oficiais (demucs.pretrained.get_model) e converte com coremltools
  huggingface  baixa a conversão pronta de schism-audio/htdemucs[-6s]-coreml (MIT)
  auto         tenta convert; se falhar ou não passar na verificação, usa huggingface

Verificação: no macOS o script roda o .mlpackage (coremltools.predict) através da MESMA cadeia
de DSP que o app usa (implementada aqui em numpy, espelho do Swift) e compara com
demucs.apply.apply_model em PyTorch. Também compara a cadeia numpy + rede PyTorch com o
demucs original (valida o DSP do app independentemente do Core ML; roda em qualquer SO).

Uso:  python scripts/convert_demucs.py --model htdemucs_6s --out build/demucs
Saída: <out>/HTDemucs.mlpackage e <out>/contract.json
"""

from __future__ import annotations

import argparse
import json
import math
import platform
import shutil
import sys
import traceback
from pathlib import Path

import numpy as np

CONTRACT = "afinador-demucs-v1"
SAMPLE_RATE = 44100
NFFT = 4096
HOP = 1024
OVERLAP = 0.25
HF_REPOS = {
    "htdemucs": "schism-audio/htdemucs-coreml",
    "htdemucs_6s": "schism-audio/htdemucs-6s-coreml",
}
HF_PACKAGE = "HTDemucs_Core_fp16.mlpackage"
OUTPUT_NAME = "HTDemucs.mlpackage"


# ---------------------------------------------------------------------------------------------
# DSP do app (espelho exato de DemucsSeparator.swift). Só numpy.
# ---------------------------------------------------------------------------------------------

def hann(n: int = NFFT) -> np.ndarray:
    """torch.hann_window(n) (periódica)."""
    return (0.5 - 0.5 * np.cos(2.0 * np.pi * np.arange(n) / n)).astype(np.float64)


def frames_for(length: int) -> int:
    return int(math.ceil(length / HOP))


def host_stft(seg: np.ndarray) -> np.ndarray:
    """seg (2, L) -> mag (1, 4, 2048, T). Equivale a HTDemucs._spec + _magnitude (cac)."""
    channels, length = seg.shape
    T = frames_for(length)
    pad = HOP // 2 * 3
    xp = np.pad(seg.astype(np.float64), ((0, 0), (pad, pad + T * HOP - length)), mode="reflect")
    # Quadro t do HTDemucs = quadro t+2 do torch.stft(center=True) = xp[t*hop : t*hop+nfft]
    idx = np.arange(T)[:, None] * HOP + np.arange(NFFT)[None, :]
    win = hann()
    out = np.zeros((1, 2 * channels, NFFT // 2, T), dtype=np.float32)
    for c in range(channels):
        frames = xp[c][idx] * win
        spec = np.fft.rfft(frames, axis=-1)[:, : NFFT // 2] / math.sqrt(NFFT)  # (T, 2048)
        out[0, 2 * c] = spec.real.T
        out[0, 2 * c + 1] = spec.imag.T
    return out


def host_istft(re: np.ndarray, im: np.ndarray, length: int) -> np.ndarray:
    """re/im (2048, T) -> (length,). Equivale a HTDemucs._ispec (pad de 2 quadros e do bin de Nyquist)."""
    F, T = re.shape
    z = np.zeros((NFFT // 2 + 1, T), dtype=np.complex128)
    z[:F] = re + 1j * im
    frames = np.fft.irfft(z.T, n=NFFT, axis=-1) * math.sqrt(NFFT)  # (T, nfft)
    win = hann()
    total = T + 4  # 2 quadros de zeros de cada lado
    buf = np.zeros((total - 1) * HOP + NFFT)
    env = np.zeros_like(buf)
    for f in range(total):
        env[f * HOP: f * HOP + NFFT] += win ** 2
    for t in range(T):
        p = (t + 2) * HOP
        buf[p: p + NFFT] += frames[t] * win
    start = NFFT // 2 + HOP // 2 * 3  # corte do center=True + corte do _ispec
    return (buf[start: start + length] / env[start: start + length]).astype(np.float32)


def triangle_weight(L: int) -> np.ndarray:
    i = np.arange(L)
    w = np.where(i < L // 2, i + 1, L - i).astype(np.float64)
    return w / max(L // 2, L - L // 2)


def host_separate(mix: np.ndarray, predict, segment: int, n_sources: int) -> np.ndarray:
    """mix (2, N) float -> (S, 2, N). Espelho do laço do app (acumulador rolante + escrita
    incremental), com normalização global igual a demucs/separate.py e apply_model(split=True,
    overlap=0.25, shifts=0)."""
    N = mix.shape[-1]
    ref = mix.mean(0)
    mean = float(ref.mean())
    std = float(ref.std(ddof=1)) if N > 1 else 1.0
    if std < 1e-8:
        std = 1.0
    x = (mix - mean) / std
    L = segment
    stride = int((1 - OVERLAP) * L)
    w = triangle_weight(L)
    acc = np.zeros((n_sources, 2, L))
    wacc = np.zeros(L)
    out = np.zeros((n_sources, 2, N), dtype=np.float32)
    written = 0
    offset = 0
    while offset < N:
        chunk_len = min(L, N - offset)
        delta = L - chunk_len
        start = offset - delta // 2
        chunk = np.zeros((2, L), dtype=np.float32)
        a, b = max(0, start), min(N, start + L)
        chunk[:, a - start: b - start] = x[:, a:b]
        spec_out, time_out = predict(host_stft(chunk), chunk[None])
        est = np.zeros((n_sources, 2, L))
        for s in range(n_sources):
            for c in range(2):
                est[s, c] = host_istft(spec_out[0, s, 2 * c], spec_out[0, s, 2 * c + 1], L) + time_out[0, s, c]
        lo = delta // 2
        acc[..., :chunk_len] += w[:chunk_len] * est[..., lo: lo + chunk_len]
        wacc[:chunk_len] += w[:chunk_len]
        last = offset + stride >= N
        final = chunk_len if last else stride
        out[..., written: written + final] = acc[..., :final] / wacc[:final] * std + mean
        written += final
        acc[..., : L - stride] = acc[..., stride:].copy()
        acc[..., L - stride:] = 0
        wacc[: L - stride] = wacc[stride:].copy()
        wacc[L - stride:] = 0
        offset += stride
    assert written == N, (written, N)
    return out


def snr_db(ref: np.ndarray, est: np.ndarray) -> float:
    num = float(np.sum(ref.astype(np.float64) ** 2))
    den = float(np.sum((ref.astype(np.float64) - est) ** 2)) + 1e-20
    return 10 * math.log10(num / den + 1e-20)


def test_signal(seconds: float, seed: int = 7) -> np.ndarray:
    """Sinal sintético com cara de música (bateria, baixo, acordes dedilhados, 'voz')."""
    rng = np.random.default_rng(seed)
    n = int(seconds * SAMPLE_RATE)
    t = np.arange(n) / SAMPLE_RATE
    left = np.zeros(n)
    right = np.zeros(n)
    beat = 0.5
    for k in range(int(seconds / beat)):
        p = int(k * beat * SAMPLE_RATE)
        m = min(n - p, int(0.25 * SAMPLE_RATE))
        tt = np.arange(m) / SAMPLE_RATE
        kick = np.sin(2 * np.pi * (50 + 80 * np.exp(-tt * 30)) * tt) * np.exp(-tt * 12)
        hat = rng.standard_normal(m) * np.exp(-tt * 60) * 0.15
        left[p: p + m] += 0.6 * kick + hat
        right[p: p + m] += 0.6 * kick + 0.8 * hat
    roots = [110.0, 146.83, 130.81, 98.0]
    for k in range(int(seconds / 2) + 1):
        p = int(k * 2 * SAMPLE_RATE)
        if p >= n:
            break
        m = min(n - p, 2 * SAMPLE_RATE)
        tt = np.arange(m) / SAMPLE_RATE
        r = roots[k % len(roots)]
        bass = 0.35 * np.sin(2 * np.pi * r / 2 * tt) * np.exp(-tt * 1.5)
        left[p: p + m] += bass
        right[p: p + m] += bass
        for j, ratio in enumerate((1.0, 1.25, 1.5, 2.0)):
            q = p + int(j * 0.03 * SAMPLE_RATE)
            mm = min(n - q, m)
            ttt = np.arange(mm) / SAMPLE_RATE
            pl = sum(np.sin(2 * np.pi * r * ratio * h * ttt) / h for h in range(1, 6)) * np.exp(-ttt * 3) * 0.08
            left[q: q + mm] += pl * 0.7
            right[q: q + mm] += pl * 1.0
    voice = 0.12 * np.sin(2 * np.pi * (220 * t + 3 * np.sin(2 * np.pi * 5 * t))) * (0.5 + 0.5 * np.sin(2 * np.pi * 0.25 * t)) ** 2
    left += voice
    right += voice
    mix = np.stack([left, right]).astype(np.float32)
    return mix / (np.abs(mix).max() + 1e-9) * 0.8


# ---------------------------------------------------------------------------------------------
# PyTorch / coremltools (importados só quando necessários)
# ---------------------------------------------------------------------------------------------

def load_demucs(name: str):
    from demucs.apply import BagOfModels
    from demucs.pretrained import get_model

    model = get_model(name)
    if isinstance(model, BagOfModels):
        if len(model.models) != 1:
            raise SystemExit(f"{name} é um bag de {len(model.models)} modelos; use htdemucs ou htdemucs_6s.")
        bag = model
        core = model.models[0]
    else:
        bag = model
        core = model
    core.eval()
    from demucs.htdemucs import HTDemucs
    if not isinstance(core, HTDemucs):
        raise SystemExit(f"{name} não é HTDemucs ({type(core).__name__}).")
    if not core.cac:
        raise SystemExit("Este script assume cac=True (complexo-como-canais).")
    if core.nfft != NFFT or core.hop_length != HOP or core.samplerate != SAMPLE_RATE:
        raise SystemExit(f"STFT inesperada: nfft={core.nfft} hop={core.hop_length} sr={core.samplerate}")
    segment = int(core.segment * core.samplerate)
    return bag, core, list(core.sources), segment


def make_core_net(core):
    """Rede do HTDemucs sem STFT/iSTFT. Corpo copiado de demucs/htdemucs.py (HTDemucs.forward,
    commit e976d93) entre `_magnitude` e `_mask`; mesmo state_dict, sem pesos novos."""
    import torch
    from einops import rearrange

    class HTDemucsCore(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        @staticmethod
        def _mean_std(t, dims):
            n = 1
            for d in dims:
                n *= t.shape[d]
            mean = t.mean(dim=dims, keepdim=True)
            var = ((t - mean) ** 2).mean(dim=dims, keepdim=True) * (n / (n - 1))  # torch.std (Bessel)
            return mean, torch.sqrt(var)

        def forward(self, mag, mix):
            m = self.m
            x = mag
            B, C, Fq, T = x.shape
            mean, std = self._mean_std(x, (1, 2, 3))
            x = (x - mean) / (1e-5 + std)

            xt = mix
            length = mix.shape[-1]
            meant, stdt = self._mean_std(xt, (1, 2))
            xt = (xt - meant) / (1e-5 + stdt)

            saved = []
            saved_t = []
            lengths = []
            lengths_t = []
            for idx, encode in enumerate(m.encoder):
                lengths.append(x.shape[-1])
                inject = None
                if idx < len(m.tencoder):
                    lengths_t.append(xt.shape[-1])
                    tenc = m.tencoder[idx]
                    xt = tenc(xt)
                    if not tenc.empty:
                        saved_t.append(xt)
                    else:
                        inject = xt
                x = encode(x, inject)
                if idx == 0 and m.freq_emb is not None:
                    frs = torch.arange(x.shape[-2], device=x.device)
                    emb = m.freq_emb(frs).t()[None, :, :, None].expand_as(x)
                    x = x + m.freq_emb_scale * emb
                saved.append(x)
            if m.crosstransformer:
                if m.bottom_channels:
                    b, c, f, t = x.shape
                    x = rearrange(x, "b c f t-> b c (f t)")
                    x = m.channel_upsampler(x)
                    x = rearrange(x, "b c (f t)-> b c f t", f=f)
                    xt = m.channel_upsampler_t(xt)
                x, xt = m.crosstransformer(x, xt)
                if m.bottom_channels:
                    x = rearrange(x, "b c f t-> b c (f t)")
                    x = m.channel_downsampler(x)
                    x = rearrange(x, "b c (f t)-> b c f t", f=f)
                    xt = m.channel_downsampler_t(xt)

            for idx, decode in enumerate(m.decoder):
                skip = saved.pop(-1)
                x, pre = decode(x, skip, lengths.pop(-1))
                offset = m.depth - len(m.tdecoder)
                if idx >= offset:
                    tdec = m.tdecoder[idx - offset]
                    length_t = lengths_t.pop(-1)
                    if tdec.empty:
                        pre = pre[:, :, 0]
                        xt, _ = tdec(pre, None, length_t)
                    else:
                        skip = saved_t.pop(-1)
                        xt, _ = tdec(xt, skip, length_t)

            S = len(m.sources)
            x = x.view(B, S, -1, Fq, T)
            x = x * std[:, None] + mean[:, None]
            xt = xt.view(B, S, -1, length)
            xt = xt * stdt[:, None] + meant[:, None]
            return x, xt

    net = HTDemucsCore(core)
    net.eval()
    return net


def torch_reference(bag, mix_norm: np.ndarray) -> np.ndarray:
    """demucs.apply.apply_model sobre a mixagem já normalizada (S, 2, N)."""
    import torch
    from demucs.apply import apply_model

    with torch.no_grad():
        out = apply_model(bag, torch.from_numpy(mix_norm)[None], shifts=0, split=True, overlap=OVERLAP, progress=False)
    return out[0].numpy()


def reference_separation(bag, mix: np.ndarray) -> np.ndarray:
    ref = mix.mean(0)
    mean, std = float(ref.mean()), float(ref.std(ddof=1)) or 1.0
    return torch_reference(bag, ((mix - mean) / std).astype(np.float32)) * std + mean


def check_host_dsp(bag, net, segment, n_sources, mix) -> float:
    """DSP do app (numpy) + rede PyTorch vs. demucs original. Valida STFT/iSTFT/overlap-add."""
    import torch

    def predict(mag, seg):
        with torch.no_grad():
            a, b = net(torch.from_numpy(mag), torch.from_numpy(seg))
        return a.numpy(), b.numpy()

    ours = host_separate(mix, predict, segment, n_sources)
    ref = reference_separation(bag, mix)
    snr = snr_db(ref, ours)
    print(f"[verificação] DSP do app + rede PyTorch vs. demucs: SNR {snr:.1f} dB")
    return snr


def convert(net, segment: int, precision: str):
    import coremltools as ct
    import torch

    T = frames_for(segment)
    mag = torch.zeros(1, 4, NFFT // 2, T)
    mix = torch.zeros(1, 2, segment)
    try:  # evita o caminho rápido do MultiheadAttention (op não suportada pelo coremltools)
        torch.backends.mha.set_fastpath_enabled(False)
    except Exception:
        pass
    # Rastreado com gradiente ligado de propósito: o fast path do MHA exige no_grad.
    traced = torch.jit.trace(net, (mag, mix), check_trace=False)

    if precision == "fp32":
        cp = ct.precision.FLOAT32
    elif precision == "fp16":
        cp = ct.precision.FLOAT16
    elif precision == "fp16-reduce32":
        cp = ct.transform.FP16ComputePrecision(op_selector=lambda op: not op.op_type.startswith("reduce_"))
    else:
        raise ValueError(precision)

    mlmodel = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="mag", shape=tuple(mag.shape), dtype=np.float32),
            ct.TensorType(name="mix", shape=tuple(mix.shape), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="spec_out"), ct.TensorType(name="time_out")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS16,
        compute_precision=cp,
        compute_units=ct.ComputeUnit.ALL,
        skip_model_load=platform.system() != "Darwin",
    )
    return mlmodel


def download_hf(model_name: str, revision: str, workdir: Path):
    import coremltools as ct
    from huggingface_hub import snapshot_download

    repo = HF_REPOS[model_name]
    local = workdir / "hf"
    snapshot_download(repo_id=repo, revision=revision, local_dir=str(local),
                      allow_patterns=[f"{HF_PACKAGE}/*"])
    path = local / HF_PACKAGE
    if not path.exists():
        raise RuntimeError(f"{HF_PACKAGE} não encontrado em {repo}@{revision}")
    print(f"[hf] baixado {repo}@{revision}/{HF_PACKAGE}")
    return ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.ALL,
                             skip_model_load=platform.system() != "Darwin")


def check_contract(mlmodel, segment: int, n_sources: int):
    spec = mlmodel.get_spec()
    def shape(f):
        return list(f.type.multiArrayType.shape)
    ins = {f.name: shape(f) for f in spec.description.input}
    outs = {f.name: shape(f) for f in spec.description.output}
    T = frames_for(segment)
    want_in = {"mag": [1, 4, NFFT // 2, T], "mix": [1, 2, segment]}
    for k, v in want_in.items():
        if ins.get(k) != v:
            raise RuntimeError(f"entrada {k}: esperado {v}, modelo tem {ins.get(k)} (entradas: {ins})")
    for k in ("spec_out", "time_out"):
        if k not in outs:
            raise RuntimeError(f"saída {k} ausente (saídas: {list(outs)})")
        if outs[k] and outs[k][1] != n_sources:
            raise RuntimeError(f"saída {k}: S={outs[k][1]}, esperado {n_sources}")
    print(f"[contrato] ok — entradas {ins}, saídas {outs}")


def check_coreml(mlmodel, bag, segment, n_sources, mix) -> float:
    if platform.system() != "Darwin":
        print("[verificação] coremltools.predict só roda no macOS — pulando comparação Core ML.")
        return float("nan")

    def predict(mag, seg):
        r = mlmodel.predict({"mag": mag.astype(np.float32), "mix": seg.astype(np.float32)})
        return np.asarray(r["spec_out"], dtype=np.float32), np.asarray(r["time_out"], dtype=np.float32)

    ours = host_separate(mix, predict, segment, n_sources)
    ref = reference_separation(bag, mix)
    snr = snr_db(ref, ours)
    per = ", ".join(f"{s}" for s in range(n_sources))
    print(f"[verificação] Core ML + DSP do app vs. demucs PyTorch: SNR {snr:.1f} dB (fontes {per})")
    return snr


def finalize(mlmodel, sources, segment, out_dir: Path, origin: str):
    mlmodel.short_description = "HTDemucs (Meta, MIT) — separação de instrumentos para o Afinador"
    mlmodel.author = "facebookresearch/demucs (Rouard, Massa, Défossez); conversão: " + origin
    mlmodel.license = "MIT"
    md = mlmodel.user_defined_metadata
    md["contract"] = CONTRACT
    md["sources"] = ",".join(sources)
    md["samplerate"] = str(SAMPLE_RATE)
    md["nfft"] = str(NFFT)
    md["hop"] = str(HOP)
    md["segment_samples"] = str(segment)
    md["origin"] = origin
    out_dir.mkdir(parents=True, exist_ok=True)
    dest = out_dir / OUTPUT_NAME
    if dest.exists():
        shutil.rmtree(dest)
    mlmodel.save(str(dest))
    contract = {
        "contract": CONTRACT, "origin": origin, "sources": sources, "sample_rate": SAMPLE_RATE,
        "nfft": NFFT, "hop": HOP, "segment_samples": segment, "frames": frames_for(segment),
        "inputs": {"mag": [1, 4, NFFT // 2, frames_for(segment)], "mix": [1, 2, segment]},
        "outputs": {"spec_out": [1, len(sources), 4, NFFT // 2, frames_for(segment)],
                    "time_out": [1, len(sources), 2, segment]},
    }
    (out_dir / "contract.json").write_text(json.dumps(contract, indent=2))
    print(f"[ok] {dest}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", choices=sorted(HF_REPOS), default="htdemucs_6s")
    ap.add_argument("--source", choices=["auto", "convert", "huggingface"], default="auto")
    ap.add_argument("--precision", choices=["auto", "fp16", "fp16-reduce32", "fp32"], default="auto")
    ap.add_argument("--hf-revision", default="main")
    ap.add_argument("--out", default="build/demucs")
    ap.add_argument("--min-snr", type=float, default=20.0, help="SNR mínimo (dB) contra o PyTorch")
    ap.add_argument("--seconds", type=float, default=18.0, help="duração do sinal de teste")
    ap.add_argument("--skip-verify", action="store_true")
    args = ap.parse_args()

    out_dir = Path(args.out)
    work = out_dir / "work"
    work.mkdir(parents=True, exist_ok=True)

    bag, core, sources, segment = load_demucs(args.model)
    print(f"[modelo] {args.model}: fontes={sources} segmento={segment} amostras ({segment / SAMPLE_RATE:.2f} s)")
    net = make_core_net(core)
    mix = test_signal(args.seconds)

    if not args.skip_verify:
        snr = check_host_dsp(bag, net, segment, len(sources), mix)
        if snr < 50:
            raise SystemExit(f"DSP do app diverge do demucs (SNR {snr:.1f} dB) — corrija antes de converter.")

    def accept(mlmodel, label) -> bool:
        check_contract(mlmodel, segment, len(sources))
        if args.skip_verify:
            return True
        snr = check_coreml(mlmodel, bag, segment, len(sources), mix)
        if math.isnan(snr):
            print(f"[aviso] {label}: sem verificação numérica (não é macOS).")
            return True
        ok = snr >= args.min_snr
        print(f"[{'ok' if ok else 'reprovado'}] {label}: {snr:.1f} dB (mínimo {args.min_snr})")
        return ok

    if args.source in ("auto", "convert"):
        ladder = ["fp16", "fp16-reduce32", "fp32"] if args.precision == "auto" else [args.precision]
        for prec in ladder:
            label = f"convert/{prec}"
            try:
                print(f"[convert] coremltools, precisão {prec}…")
                mlmodel = convert(net, segment, prec)
                if accept(mlmodel, label):
                    finalize(mlmodel, sources, segment, out_dir, f"{args.model} via coremltools ({prec})")
                    return
            except Exception:
                traceback.print_exc()
                print(f"[falhou] {label}")
        if args.source == "convert":
            raise SystemExit("Conversão não passou. Tente --source huggingface.")

    try:
        mlmodel = download_hf(args.model, args.hf_revision, work)
        if accept(mlmodel, "huggingface"):
            finalize(mlmodel, sources, segment, out_dir,
                     f"{HF_REPOS[args.model]}@{args.hf_revision} ({HF_PACKAGE})")
            return
    except Exception:
        traceback.print_exc()
    raise SystemExit("Nenhuma fonte de modelo passou na verificação.")


if __name__ == "__main__":
    sys.exit(main())
