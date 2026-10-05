# GPU phase: PyTorch CUDA on Windows L2 under default patched KVM

Date: 2026-10-05 (test window about 10:45–10:55 EDT). Author: Grok Bot for Brandon
(decisions deferred to 9-9-6 Developer). Follows
[gpu-phase-patched-kvm-default.md](gpu-phase-patched-kvm-default.md) (PR #9).
Everything below was **run**; what was not run is listed at the end.

## Verdict

| Item | Verdict |
| --- | --- |
| Default patched KVM on L1 (`6.12.111-kvmpatch1`) | **PASS** — verified before L2 start |
| Windows L2 + RTX 4080 Code 0 / nvidia-smi 576.88 | **PASS** |
| Local PyTorch CUDA wheel install (cp312, cu124) | **PASS** — `torch-2.6.0+cu124` from staged `.whl` |
| Matmul TFLOP/s | **fp32 4096³ ≈ 30.8 TFLOP/s**; **fp16 8192³ ≈ 95.3 TFLOP/s** |
| Short training loop | **PASS** — 200-step MLP, loss 3.34 → 1.96 |
| VRAM / BAR1 | FB **16376 MiB**; BAR1 **16384 MiB** total |
| Host PVE stock; L1 left on patched default | **PASS** (restored after run) |

## Setup notes

* L1 launched with existing Intel+bridge raw script (`launch-l1-kvmmod.sh`); `qm start`
  still wrong topology.
* Windows disk already held `C:\gputest\py` (Python 3.12.10) from earlier CuPy work.
* Staged `torch-2.6.0+cu124-cp312-cp312-win_amd64.whl` (~2.4 GiB, sha256
  `3313061c1fec4c7310cf47944e84513dcd27b6173b72a349bb7ca68d0ee6e9c0`) onto the NTFS
  volume from L1 (`ntfs-3g`), then booted L2.
* **qemu-ad-pve (10.2.2) has no SLIRP/`-netdev user`.** For this session L2 used
  **stock Debian QEMU 10.0.13** with user-mode NAT + SSH hostfwd (`127.0.0.1:2223`)
  so pip could fetch small pure-Python deps. GPU path and patched KVM unchanged.
  Default one-command `start-l2.sh` (tap/`brl2` + qemu-ad) remains the offline path.
* Wheel install: `pip install <whl> --index-url https://download.pytorch.org/whl/cu124
  --extra-index-url https://pypi.org/simple` (deps: sympy/networkx/jinja2/…).

## Results (Windows L2, patched KVM)

```
torch 2.6.0+cu124 cuda 12.4 avail True
device NVIDIA GeForce RTX 4080
nvidia-smi: Driver 576.88, CUDA 12.9, 16376 MiB
VRAM free_MiB ~15048 total_MiB 16375 (before heavy alloc)
BAR1 Memory Usage Total 16384 MiB
matmul torch.float32 4096^3: ~4.46 ms, 30.79 TFLOP/s
matmul torch.float16 8192^3: ~11.54 ms, 95.30 TFLOP/s
train 200 steps in ~3.5s (56.5 steps/s) loss 3.341->1.959
RESULT PASS
```

Compare to PR #9 CuPy baselines under the same nested path: CuPy SGEMM ~30–31 TFLOP/s
fp32 — PyTorch fp32 matmul lands in the same band; fp16 ~95 TFLOP/s (Tensor-core path).

## What was run

| # | Step | L1 | Host |
| --- | --- | --- | --- |
| 1 | `qm shutdown 9102` | — | GPU freed to vfio-pci |
| 2 | Set 9200 active Intel+scsi1; `qm showcmd` capture; raw L1 launch | — | one QEMU for 9200 |
| 3 | Verify kvmpatch default; stage wheel on NTFS; start Windows L2 (stock QEMU + usernet) | scripts under `/root/w10/`; disk writes | — |
| 4 | pip install local cu124 wheel; matmul + train + nvidia-smi | — | — |
| 5 | Clean L2/L1 shutdown; restore 9200 AMD active from backup; `qm start 9102` | L1 disk keeps patched default | host stock |

## Final state

| Item | State |
| --- | --- |
| L1 (9200) | **Stopped**. Next raw boot still autoloads patched kvm (`6.12.111-kvmpatch1`) via `modules-load.d`. |
| Host | Stock PVE KVM/QEMU/kernel. 9200 active config restored from AMD backup (empty active diff). |
| 9102 | **Running**; nvidia-smi 576.88, 16376 MiB, RTX 4080, ConfigManagerErrorCode **0**. GPU on host: `vfio-pci`. |
| Host dmesg fault-pattern count | Session start 57; end 57 (unchanged). |
| Leftovers | Host `/root/gpu-phase-l1/pytorch/` wheel + helpers; L1 `/root/w10/start-l2-usernet.sh`; Windows `C:\gputest\pytorch-whl\` + installed torch. |

## Not run

* PyTorch via qemu-ad L2 (no user networking in that binary)
* Linux L2 PyTorch path (Windows succeeded)
* Host reboot / host apt / GRUB / module changes
* Functional (non-benign) KVM patches
* Booting L1 from newly generated `gen-launch.py` script (compared offline; see PR #10)
