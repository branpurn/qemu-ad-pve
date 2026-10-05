"""PyTorch CUDA matmul + short MLP train (Windows L2). Expects local cu124 wheel optional."""
import subprocess, sys, os, time
print("python", sys.version)
os.chdir(os.environ.get("GPUTEST", r"C:\gputest"))
whl = os.path.join("pytorch-whl", "torch-2.6.0+cu124-cp312-cp312-win_amd64.whl")
if os.path.exists(whl):
    subprocess.call([sys.executable, "-m", "pip", "install", whl,
                     "--index-url", "https://download.pytorch.org/whl/cu124",
                     "--extra-index-url", "https://pypi.org/simple"])
import torch
print("torch", torch.__version__, "cuda", torch.version.cuda, "avail", torch.cuda.is_available())
assert torch.cuda.is_available()
print("device", torch.cuda.get_device_name(0))
print(subprocess.check_output(["nvidia-smi"], text=True, errors="replace")[:800])
free, total = torch.cuda.mem_get_info()
print("VRAM free_MiB", free >> 20, "total_MiB", total >> 20)

def matmul(dtype, n, reps=20):
    a = torch.randn(n, n, device="cuda", dtype=torch.float32).to(dtype)
    b = torch.randn(n, n, device="cuda", dtype=torch.float32).to(dtype)
    torch.cuda.synchronize(); _ = a @ b; torch.cuda.synchronize()
    t0 = time.perf_counter()
    for _ in range(reps):
        c = a @ b
    torch.cuda.synchronize()
    dt = (time.perf_counter() - t0) / reps
    tflops = 2 * (n ** 3) / dt / 1e12
    print(f"matmul {dtype} {n}^3: {dt*1e3:.2f} ms, {tflops:.2f} TFLOP/s")
    return tflops

fp32 = matmul(torch.float32, 4096)
fp16 = matmul(torch.float16, 8192)
torch.manual_seed(0)
B, D, H, C = 4096, 1024, 4096, 16
teacher = torch.randn(D, C, device="cuda")
params = []
W1 = torch.randn(D, H, device="cuda") * (2 / D) ** 0.5; b1 = torch.zeros(H, device="cuda")
W2 = torch.randn(H, H, device="cuda") * (2 / H) ** 0.5; b2 = torch.zeros(H, device="cuda")
W3 = torch.randn(H, C, device="cuda") * (1 / H) ** 0.5; b3 = torch.zeros(C, device="cuda")
for p in (W1, b1, W2, b2, W3, b3):
    p.requires_grad_(True); params.append(p)
opt = torch.optim.SGD(params, lr=0.05)
losses = []; t0 = time.perf_counter(); steps = 200
for s in range(steps):
    X = torch.randn(B, D, device="cuda"); y = (X @ teacher).argmax(1)
    loss = torch.nn.functional.cross_entropy(torch.relu(torch.relu(X @ W1 + b1) @ W2 + b2) @ W3 + b3, y)
    opt.zero_grad(set_to_none=True); loss.backward(); opt.step()
    if s % 50 == 0 or s == steps - 1:
        losses.append((s, float(loss.detach()))); print(f"  step {s} loss {losses[-1][1]:.4f}")
torch.cuda.synchronize()
print(f"train {steps} steps loss {losses[0][1]:.3f}->{losses[-1][1]:.3f}")
print("RESULT", "PASS" if fp32 > 20 and losses[-1][1] < losses[0][1] * 0.7 else "FAIL",
      "fp32", round(fp32, 2), "fp16", round(fp16, 2))
