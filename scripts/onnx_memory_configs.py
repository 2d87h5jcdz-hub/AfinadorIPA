#!/usr/bin/env python3
"""Pico de memória (VmHWM) de 2 inferências seguidas em várias configurações do onnxruntime."""
import subprocess, sys
path = sys.argv[1]
code = r"""
import sys, numpy as np, onnxruntime as ort
lvl, arena, pattern, strat = sys.argv[1], sys.argv[2] == '1', sys.argv[3] == '1', sys.argv[4]
def hwm():
    for l in open('/proc/self/status'):
        if l.startswith('VmHWM'): return int(l.split()[1]) // 1024
so = ort.SessionOptions(); so.enable_cpu_mem_arena = arena; so.enable_mem_pattern = pattern
so.intra_op_num_threads = 2; so.graph_optimization_level = getattr(ort.GraphOptimizationLevel, lvl)
prov = ['CPUExecutionProvider']
if arena and strat != '-':
    s = ort.InferenceSession(%r, so, providers=[('CPUExecutionProvider', {})])
    cfg = ort.OrtArenaCfg(0, int(strat), -1, -1)
else:
    pass
s = ort.InferenceSession(%r, so, providers=prov)
load = hwm()
feed = {'mag': np.random.randn(1, 4, 2048, 336).astype(np.float32), 'mix': np.random.randn(1, 2, 343980).astype(np.float32)}
s.run(None, feed); a = hwm(); s.run(None, feed); b = hwm()
print(f'carregar {load} | 1ª {a} | 2ª {b} MB')
""" % (path, path)
for lvl in ["ORT_DISABLE_ALL", "ORT_ENABLE_EXTENDED", "ORT_ENABLE_ALL"]:
    for arena, pattern in [(0, 0), (1, 0), (1, 1)]:
        r = subprocess.run([sys.executable, "-c", code, lvl, str(arena), str(pattern), "-"], capture_output=True, text=True)
        print(f"{lvl:20s} arena={arena} padrão={pattern}: {r.stdout.strip()} {r.stderr.strip()[-150:]}", flush=True)
# glibc devolvendo memória (simula alocador que não segura)
for lvl in ["ORT_DISABLE_ALL", "ORT_ENABLE_ALL"]:
    r = subprocess.run([sys.executable, "-c", code, lvl, "0", "0", "-"], capture_output=True, text=True,
                       env={"MALLOC_TRIM_THRESHOLD_": "0", "MALLOC_MMAP_THRESHOLD_": "65536", "PATH": "/usr/bin:/bin"})
    print(f"{lvl:20s} sem arena + malloc devolvendo: {r.stdout.strip()} {r.stderr.strip()[-150:]}", flush=True)
