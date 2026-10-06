"""Upgraded CuPy AI path under patched-KVM default (PyTorch wheel not available offline)."""
import cupy as cp, numpy as np, time, subprocess
p = cp.cuda.runtime.getDeviceProperties(0)
free, total = cp.cuda.runtime.memGetInfo()
print("device:", p['name'].decode(), "cc %d.%d" % (p['major'], p['minor']), "total MiB", total >> 20, "free MiB", free >> 20)
def sync(): cp.cuda.Stream.null.synchronize()
def smi_q(q):
    return subprocess.run(["nvidia-smi","--query-gpu="+q,"--format=csv,noheader"],capture_output=True,text=True).stdout.strip()
print("BAR1:", smi_q("memory.total,memory.used,memory.free,pci.bus_id"))
# try BAR1 query (nvidia-smi dmon/query may vary)
try:
    out=subprocess.run(["nvidia-smi","-q","-d","MEMORY"],capture_output=True,text=True).stdout
    for line in out.splitlines():
        if "BAR1" in line or "Total" in line or "Used" in line or "Free" in line:
            if "FB" in line or "BAR" in line or line.strip().startswith(("Total","Used","Free")):
                print(" ", line.strip())
except Exception as e:
    print("BAR query err", e)

# 1) matmul throughput
results={}
for dt, n, label in ((cp.float32, 4096, "fp32"), (cp.float16, 8192, "fp16")):
    a = cp.random.rand(n, n, dtype=cp.float32).astype(dt); b = cp.random.rand(n, n, dtype=cp.float32).astype(dt)
    c = a @ b; sync(); t = time.perf_counter()
    for _ in range(20): c = a @ b
    sync(); d = (time.perf_counter() - t) / 20
    tflops = 2 * n ** 3 / d / 1e12
    print("matmul %s %d^3: %.2f ms, %.1f TFLOP/s" % (label, n, d * 1e3, tflops))
    results[label]=tflops
    del a, b, c

# 2) VRAM capacity
cp.get_default_memory_pool().free_all_blocks(); sync()
chunks = []
free0, _ = cp.cuda.runtime.memGetInfo(); print("free MiB before VRAM test:", free0 >> 20)
try:
    while True:
        i = len(chunks); x = cp.full((256 << 20) // 4, i + 1, dtype=cp.float32); chunks.append(x)
except cp.cuda.memory.OutOfMemoryError:
    pass
sync()
s_ = sum(float(c[::1000003].sum()) for c in chunks)
exp = sum((i + 1) * len(c[::1000003]) for i, c in enumerate(chunks))
pat_ok = abs(s_ - exp) < 1e-3 * exp
held = len(chunks) * 0.25
print("VRAM alloc: %.2f GiB held in %d x 256MiB chunks (of %.2f GiB free), pattern check %s" % (held, len(chunks), (free0 >> 20) / 1024, "OK" if pat_ok else "FAIL"))
vram_ok = pat_ok and held >= 0.80 * (free0 >> 20) / 1024
del chunks; cp.get_default_memory_pool().free_all_blocks()

# 3) H2D/D2H
h = np.random.rand(256 << 20 >> 2).astype(np.float32)
t = time.perf_counter(); g = cp.asarray(h); sync(); d1 = time.perf_counter() - t
t = time.perf_counter(); r = cp.asnumpy(g); d2 = time.perf_counter() - t
bw_ok = bool((r == h).all())
print("pageable H2D %.1f GiB/s, D2H %.1f GiB/s, roundtrip equal %s" % (0.25 / d1, 0.25 / d2, bw_ok))

# 4) MLP training loop
cp.random.seed(0)
B, D, H, C = 4096, 1024, 4096, 16
teacher = cp.random.randn(D, C, dtype=cp.float32)
W1 = cp.random.randn(D, H, dtype=cp.float32) * (2 / D) ** .5; b1 = cp.zeros(H, cp.float32)
W2 = cp.random.randn(H, H, dtype=cp.float32) * (2 / H) ** .5; b2 = cp.zeros(H, cp.float32)
W3 = cp.random.randn(H, C, dtype=cp.float32) * (1 / H) ** .5; b3 = cp.zeros(C, cp.float32)
lr = 0.05; losses = []; t0 = time.perf_counter(); steps = 400
for s in range(steps):
    X = cp.random.randn(B, D, dtype=cp.float32); y = (X @ teacher).argmax(1)
    z1 = X @ W1 + b1; a1 = cp.maximum(z1, 0); z2 = a1 @ W2 + b2; a2 = cp.maximum(z2, 0); lg = a2 @ W3 + b3
    lg -= lg.max(1, keepdims=True); e = cp.exp(lg); p_ = e / e.sum(1, keepdims=True)
    loss = -cp.log(p_[cp.arange(B), y] + 1e-9).mean()
    g = p_.copy(); g[cp.arange(B), y] -= 1; g /= B
    gW3 = a2.T @ g; gb3 = g.sum(0); g2 = (g @ W3.T) * (z2 > 0); gW2 = a1.T @ g2; gb2 = g2.sum(0)
    g1 = (g2 @ W2.T) * (z1 > 0); gW1 = X.T @ g1; gb1 = g1.sum(0)
    for P, G in ((W1, gW1), (b1, gb1), (W2, gW2), (b2, gb2), (W3, gW3), (b3, gb3)): P -= lr * G
    if s % 50 == 0 or s == steps - 1:
        losses.append((s, float(loss))); print("  step %d loss %.4f" % (s, losses[-1][1]))
sync(); dt = time.perf_counter() - t0
acc = float((p_.argmax(1) == y).mean())
print("MLP train: %d steps in %.1f s (%.1f steps/s), loss %.3f -> %.3f, last-batch train acc %.3f" % (steps, dt, steps / dt, losses[0][1], losses[-1][1], acc))
train_ok = losses[-1][1] < losses[0][1] * 0.55 and np.isfinite(losses[-1][1]) and acc > 0.3
print("RESULT:", "PASS" if (vram_ok and bw_ok and train_ok and results.get("fp32",0)>20) else "FAIL")
print("flags vram_ok=%s bw_ok=%s train_ok=%s fp32=%.1f" % (vram_ok, bw_ok, train_ok, results.get("fp32",0)))
