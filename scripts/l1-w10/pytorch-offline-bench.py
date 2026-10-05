"""PyTorch CUDA check for a Windows L2 with NO internet (qemu-ad-pve L2: tap to L1 only, no SLIRP).

Run with the python of a venv that was populated offline:
    pip install --no-index --find-links <wheel disk> torch==2.6.0+cu124
Prints torch/CUDA info, nvidia-smi memory (FB + BAR1), fp32/fp16 matmul TFLOP/s and a
200-step MLP training loop. Exit code 0 only on PASS.
"""
import os, subprocess, sys, time

print("python", sys.version)
print("executable", sys.executable)
import torch

print("torch", torch.__version__, "file", torch.__file__)
print("cuda", torch.version.cuda, "avail", torch.cuda.is_available())
if not torch.cuda.is_available():
    print("RESULT FAIL no-cuda"); sys.exit(2)
print("device", torch.cuda.get_device_name(0))
free, total = torch.cuda.mem_get_info()
print("VRAM free_MiB", free >> 20, "total_MiB", total >> 20)
q = subprocess.run(["nvidia-smi", "-q", "-d", "MEMORY"], capture_output=True, text=True, errors="replace").stdout
sect = None
for line in q.splitlines():
    s = line.strip()
    if s.startswith("FB Memory Usage"): sect = "FB"
    elif s.startswith("BAR1 Memory Usage"): sect = "BAR1"
    elif s.startswith("Conf Compute"): sect = None
    elif sect and s.startswith("Total"): print(sect, s)
print(subprocess.run(["nvidia-smi", "--query-gpu=name,driver_version,memory.total,pcie.link.gen.current,pcie.link.width.current",
                      "--format=csv"], capture_output=True, text=True, errors="replace").stdout.strip())


def matmul(dtype, n, reps=20):
    a = torch.randn(n, n, device="cuda").to(dtype)
    b = torch.randn(n, n, device="cuda").to(dtype)
    torch.cuda.synchronize(); _ = a @ b; torch.cuda.synchronize()
    t0 = time.perf_counter()
    for _ in range(reps):
        c = a @ b
    torch.cuda.synchronize()
    dt = (time.perf_counter() - t0) / reps
    tf = 2 * n ** 3 / dt / 1e12
    print(f"matmul {dtype} {n}^3: {dt*1e3:.2f} ms, {tf:.2f} TFLOP/s")
    return tf

# correctness spot-check vs CPU
a = torch.randn(512, 512); b = torch.randn(512, 512)
err = (a @ b - (a.cuda() @ b.cuda()).cpu()).abs().max().item()
print(f"fp32 512^3 max_abs_err_vs_cpu {err:.3e}")
fp32 = max(matmul(torch.float32, 4096) for _ in range(3))
fp16 = max(matmul(torch.float16, 8192) for _ in range(3))

# big allocation: ~12 GiB to exercise VRAM through the nested BAR/IOMMU path
blk = []
try:
    for _ in range(12):
        blk.append(torch.empty(256 * 1024 * 1024, dtype=torch.float32, device="cuda").fill_(1.0))
    s = sum(float(x[::1 << 20].sum()) for x in blk)
    print(f"alloc {len(blk)} GiB ok checksum {s:.0f}")
finally:
    del blk; torch.cuda.empty_cache()

torch.manual_seed(0)
B, D, H, C = 4096, 1024, 4096, 16
teacher = torch.randn(D, C, device="cuda")
W1 = (torch.randn(D, H, device="cuda") * (2 / D) ** 0.5).requires_grad_()
b1 = torch.zeros(H, device="cuda", requires_grad=True)
W2 = (torch.randn(H, H, device="cuda") * (2 / H) ** 0.5).requires_grad_()
b2 = torch.zeros(H, device="cuda", requires_grad=True)
W3 = (torch.randn(H, C, device="cuda") * (1 / H) ** 0.5).requires_grad_()
b3 = torch.zeros(C, device="cuda", requires_grad=True)
opt = torch.optim.SGD([W1, b1, W2, b2, W3, b3], lr=0.05)
losses = []; steps = 200; t0 = time.perf_counter()
for s in range(steps):
    X = torch.randn(B, D, device="cuda"); y = (X @ teacher).argmax(1)
    loss = torch.nn.functional.cross_entropy(torch.relu(torch.relu(X @ W1 + b1) @ W2 + b2) @ W3 + b3, y)
    opt.zero_grad(set_to_none=True); loss.backward(); opt.step()
    if s % 50 == 0 or s == steps - 1:
        losses.append(float(loss.detach())); print(f"  step {s} loss {losses[-1]:.4f}")
torch.cuda.synchronize(); dt = time.perf_counter() - t0
print(f"train {steps} steps in {dt:.1f}s ({steps/dt:.1f} steps/s) loss {losses[0]:.3f}->{losses[-1]:.3f}")
ok = fp32 > 20 and losses[-1] < losses[0] * 0.7 and err < 1e-2
print("RESULT", "PASS" if ok else "FAIL", "fp32", round(fp32, 2), "fp16", round(fp16, 2))
sys.exit(0 if ok else 1)
