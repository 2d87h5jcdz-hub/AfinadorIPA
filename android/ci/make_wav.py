"""Gera um WAV de teste (30 s, 44,1 kHz estéreo) com bateria, baixo, acordes e uma 'voz'."""
import math, random, struct, sys, wave

sr, secs = 44100, 30
n = sr * secs
L = [0.0] * n
R = [0.0] * n
rnd = random.Random(7)
for k in range(int(secs / 0.5)):  # bumbo e chimbal
    p = int(k * 0.5 * sr)
    for i in range(min(n - p, int(0.25 * sr))):
        t = i / sr
        kick = math.sin(2 * math.pi * (50 + 80 * math.exp(-t * 30)) * t) * math.exp(-t * 12)
        hat = (rnd.random() * 2 - 1) * math.exp(-t * 60) * 0.15
        L[p + i] += 0.6 * kick + hat
        R[p + i] += 0.6 * kick + 0.8 * hat
roots = [110.0, 146.83, 130.81, 98.0]
for k in range(secs // 2):  # baixo e acordes
    p = k * 2 * sr
    r = roots[k % 4]
    for i in range(2 * sr):
        t = i / sr
        b = 0.35 * math.sin(2 * math.pi * r / 2 * t) * math.exp(-t * 1.5)
        c = sum(math.sin(2 * math.pi * r * q * t) for q in (1.0, 1.25, 1.5, 2.0)) * math.exp(-t * 3) * 0.08
        L[p + i] += b + 0.7 * c
        R[p + i] += b + c
for i in range(n):  # "voz"
    t = i / sr
    v = 0.12 * math.sin(2 * math.pi * (220 * t + 3 * math.sin(2 * math.pi * 5 * t))) * (0.5 + 0.5 * math.sin(2 * math.pi * 0.25 * t)) ** 2
    L[i] += v
    R[i] += v
peak = max(max(abs(x) for x in L), max(abs(x) for x in R))
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(b"".join(struct.pack("<hh", int(L[i] / peak * 0.8 * 32767), int(R[i] / peak * 0.8 * 32767)) for i in range(n)))
print("ok", sys.argv[1])
