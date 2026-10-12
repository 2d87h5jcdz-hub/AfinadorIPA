#!/usr/bin/env python3
"""Mostra quais nós do grafo fazem a memória subir (RSS amostrado + profiling do onnxruntime)."""
import json, sys, threading, time
import numpy as np
import onnxruntime as ort

path, lvl = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "ORT_DISABLE_ALL"
def rss():
    with open("/proc/self/status") as f:
        for l in f:
            if l.startswith("VmRSS"): return int(l.split()[1]) // 1024
so = ort.SessionOptions(); so.enable_cpu_mem_arena = False; so.enable_mem_pattern = False
so.intra_op_num_threads = 2; so.graph_optimization_level = getattr(ort.GraphOptimizationLevel, lvl)
so.enable_profiling = True
s = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
print("após carregar:", rss(), "MB")
samples = []; stop = False
def sampler():
    while not stop:
        samples.append((time.perf_counter_ns() // 1000, rss())); time.sleep(0.003)
th = threading.Thread(target=sampler); th.start()
feed = {"mag": np.random.randn(1, 4, 2048, 336).astype(np.float32), "mix": np.random.randn(1, 2, 343980).astype(np.float32)}
t0 = time.perf_counter_ns() // 1000
s.run(None, feed)
stop = True; th.join()
prof = json.load(open(s.end_profiling()))
nodes = [e for e in prof if e.get("cat") == "Node" and e["name"].endswith("_kernel_time")]
# alinha: o primeiro evento do run ~ t0
base = min(e["ts"] for e in nodes)
peak_t, peak_v = max(samples, key=lambda x: x[1])
print("pico:", peak_v, "MB")
def node_at(t):
    rel = t - t0 + base
    for e in nodes:
        if e["ts"] <= rel <= e["ts"] + e["dur"]: return e
    return None
# maiores subidas de RSS
ups = []
for (ta, va), (tb, vb) in zip(samples, samples[1:]):
    if vb - va >= 20:
        e = node_at(tb)
        ups.append((vb - va, vb, e["name"] if e else "?", e["args"].get("op_name") if e else "?",
                    e["args"].get("output_size") if e else "?"))
for u in sorted(ups, reverse=True)[:25]:
    print(f"+{u[0]:4d} MB -> {u[1]:5d} MB  {u[3]:22s} {str(u[2])[:70]} out={u[4]}")
# ops com saída maior
bysize = sorted(nodes, key=lambda e: -int(e["args"].get("output_size", 0)))[:15]
for e in bysize:
    print(f"saída {int(e['args'].get('output_size', 0)) / 1e6:8.1f} MB  {e['args'].get('op_name'):20s} {e['name'][:70]}")
