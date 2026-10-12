#!/usr/bin/env python3
"""Relatório de memória do HTDemucs ONNX: maiores tensores intermediários, pico estimado por
vivacidade (ordem topológica) e pico real no onnxruntime com várias opções."""
import resource
import subprocess
import sys
from collections import defaultdict

import numpy as np
import onnx
from onnx import shape_inference

path = sys.argv[1]
m = shape_inference.infer_shapes(onnx.load(path), data_prop=True)
g = m.graph
size = {}
for vi in list(g.value_info) + list(g.output) + list(g.input):
    t = vi.type.tensor_type
    if not t.HasField("shape"):
        continue
    n = 1
    ok = True
    for d in t.shape.dim:
        if d.HasField("dim_value"):
            n *= d.dim_value
        else:
            ok = False
    if ok:
        size[vi.name] = n * 4 / 1e6
inits = {i.name for i in g.initializer}
print(f"nós: {len(g.node)}, tensores com forma: {len(size)}")
big = sorted(((v, k) for k, v in size.items() if k not in inits), reverse=True)[:25]
producer = {o: n for n in g.node for o in n.output}
for v, k in big:
    n = producer.get(k)
    print(f"{v:9.1f} MB  {k[:60]:60s} {n.op_type if n else '-'}")

# vivacidade
last = {}
for i, n in enumerate(g.node):
    for x in n.input:
        last[x] = i
live, peak, peak_at = 0.0, 0.0, -1
alive = set()
for i, n in enumerate(g.node):
    for o in n.output:
        if o in size:
            live += size[o]; alive.add(o)
    if live > peak:
        peak, peak_at = live, i
    for x in set(n.input):
        if x in alive and last.get(x) == i:
            live -= size[x]; alive.discard(x)
print(f"pico estimado (ordem do grafo): {peak:.0f} MB no nó {peak_at} ({g.node[peak_at].op_type} {g.node[peak_at].name})")
ops = defaultdict(float)
for v, k in sorted(((v, k) for k, v in size.items()), reverse=True)[:200]:
    n = producer.get(k)
    if n: ops[n.op_type] += v
print("ops com mais memória (top 200 tensores):", dict(sorted(ops.items(), key=lambda x: -x[1])[:10]))

code = """
import resource, sys, numpy as np, onnxruntime as ort
lvl, th, arena = sys.argv[1], int(sys.argv[2]), sys.argv[3] == '1'
so = ort.SessionOptions(); so.enable_cpu_mem_arena = arena; so.enable_mem_pattern = arena
so.intra_op_num_threads = th
so.graph_optimization_level = getattr(ort.GraphOptimizationLevel, lvl)
s = ort.InferenceSession(%r, so, providers=['CPUExecutionProvider'])
print('carregado', resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024, flush=True)
s.run(None, {'mag': np.random.randn(1, 4, 2048, 336).astype(np.float32), 'mix': np.random.randn(1, 2, 343980).astype(np.float32)})
print('pico', resource.getrusage(resource.RUSAGE_SELF).ru_maxrss // 1024)
""" % path
for lvl in ["ORT_DISABLE_ALL", "ORT_ENABLE_BASIC", "ORT_ENABLE_EXTENDED", "ORT_ENABLE_ALL"]:
    for th in [1, 2]:
        r = subprocess.run([sys.executable, "-c", code, lvl, str(th), "0"], capture_output=True, text=True)
        print(f"{lvl:22s} threads={th}: {r.stdout.strip().replace(chr(10), ' | ')} {r.stderr.strip()[-200:]}")
