# GPU phase: L1 booted from the gen-launch script end to end + offline PyTorch under qemu-ad-pve L2

Date: 2026-10-05, test window about 14:21–14:35 EDT. Author: Grok Bot for Brandon (decisions
deferred to the 9-9-6 Developer bot). Follows
[gpu-phase-patched-kvm-default.md](gpu-phase-patched-kvm-default.md) and the separate-kvm-feasibility
PRs #10 (gen-launch real showcmd) / #11 (PyTorch on Windows L2), which PR #20 ports here.
Everything below was **run**; what was not run is listed at the end. No credentials or keys appear here.

Closes the two "not run" items left by those PRs:

1. **Boot L1 (VM 9200) from a `tools/gen-launch.py` script**, not the hand-made `launch-l1-kvmmod.sh`.
2. **PyTorch on the Windows L2 started by the qemu-ad-pve QEMU**, which has no SLIRP, so the
   wheels were staged offline on a read-only ISO "wheel disk".

## Verdict

| Item | Verdict |
| --- | --- |
| `qm showcmd 9200` -> `gen-launch.py` -> run script -> L1 up | **PASS** — script unedited; live L0 argv == script argv (91 tokens) |
| L1 still patched-KVM default after that boot | **PASS** — `6.12.111-kvmpatch1` from `updates/dkms`, autoloaded by `systemd-modules-load` |
| Intel vIOMMU + GPU in L1 | **PASS** — DMAR-IR x2apic, both functions behind `pcie-pci-bridge`, `vfio-pci`, one IOMMU group; BAR1 16 GiB mapped |
| Windows L2 (qemu-ad-pve 10.2.2) + RTX 4080 | **PASS** — GPU + both audio functions `ConfigManagerErrorCode 0`; nvidia-smi 576.88, 16376 MiB, BAR1 16384 MiB |
| Brief CuPy / OpenCL | **PASS** — CuPy SGEMM 4096³ 30.0 / 29.9 TFLOP/s; OpenCL FMA ~46.9 TFLOP/s, 768 MiB H2D+kernel+D2H correct |
| L2 has no internet | **confirmed** — `pypi.org` does not resolve, HTTPS to a PyPI IP times out, TCP 1.1.1.1:443 fails |
| Offline torch install (fresh venv, `pip --no-index`, wheels from CD) | **PASS** — `torch-2.6.0+cu124` + 9 deps in 79 s |
| PyTorch CUDA under qemu-ad L2 | **PASS** ×2 — fp32 4096³ **34.7 TFLOP/s** (best of 3; first timing 30.4), fp16 8192³ **101.0 TFLOP/s**, 12 GiB alloc OK, MLP 200 steps loss 3.341 → 1.959 |
| Host PVE stock; 9200 config restored; 9102 back with Code 0 | **PASS** |

## 1. gen-launch end to end

### What ran

| EDT | Step |
| --- | --- |
| 14:21:08 | Host baseline: dmesg 3088 lines, fault-pattern count 53 (all from 2026-10-02 AMD-vIOMMU runs). |
| 14:21:18–14:21:30 | `qm shutdown 9102 --timeout 180` (clean, 12 s). GPU stays on `vfio-pci`. |
| 14:21:35 | Backed up `9200.conf`; set active section to the Intel config used in PR #11 (`machine: q35,viommu=intel`, no `args:` line, `memory: 12288`, `scsi1` Windows disk). Snapshot sections untouched. |
| 14:21:35 | `qm showcmd 9200` captured — byte-identical to the PR #10 sample. |
| 14:21:40 | `gen-launch.py qm-showcmd-9200-raw.txt -o launch-9200-gen.sh` (generator from PR #10 = PR #20). Output identical to PR #10's `samples/gen-launch-9200-from-real-showcmd.sh` apart from the input filename in the header comment. |
| 14:21:49 | `QEMU_BIN=/usr/bin/kvm.pve ./launch-9200-gen.sh` -> rc 0, daemonized, `exe -> /usr/bin/qemu-system-x86_64`, `argv[0]=/usr/bin/kvm`. vfio reset of 02:00.0 in host dmesg, nothing else. |
| 14:22:02 | L1 `systemd-modules-load: Inserted module 'kvm_amd'` (patched build). |
| 14:26:20 | L1 check (below). |

Samples: [`samples/gen-launch-e2e/`](../samples/gen-launch-e2e/).

The script includes the one intentional difference from the old hand-made L0 script:
`-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536` at L0. It booted fine with it, so this run
is the first L0 -> L1 test of that flag (tools/README noted it as "not yet run").

### L1 evidence (booted from the generated script)

```
6.12.111+deb13-amd64
kvm=6.12.111-kvmpatch1 kvm_amd=6.12.111-kvmpatch1 tag=step1-benign
/lib/modules/6.12.111+deb13-amd64/updates/dkms/kvm.ko.xz
/lib/modules/6.12.111+deb13-amd64/updates/dkms/kvm-amd.ko.xz
kvm-patched/1.0, 6.12.111+deb13-amd64, x86_64: installed (Original modules exist)
[    3.643983] kvm_amd: kvm_amd: out-of-tree patched build loaded (tag=step1-benign, version 6.12.111-kvmpatch1)
[    0.125998] DMAR-IR: Enabled IRQ remapping in x2apic mode
01:00.0 PCI bridge [0604]: Red Hat, Inc. QEMU PCIe-to-PCI bridge [1b36:000e]
02:01.0 VGA compatible controller [0300]: NVIDIA Corporation AD103 [GeForce RTX 4080] [10de:2704] (rev a1)
02:01.1 Audio device [0403]: NVIDIA Corporation AD103 High Definition Audio Controller [10de:22bb] (rev a1)
02:01.0 driver=vfio-pci group=11
02:01.1 driver=vfio-pci group=11
	Region 1: Memory at 1000000000 (64-bit, prefetchable) [size=16G]
	Region 3: Memory at 1400000000 (64-bit, prefetchable) [size=32M]
```

### Operational notes

* L1 got a different DHCP lease than the cached one in the host helper (`l1ip`), and the
  helper `hostrun.sh` is not executable; call it as `L1IP=<addr> bash hostrun.sh <script>`.
  First reachability attempts failed only because of that. L1 was up by 14:22.
* `qm status 9200` prints cgroup/uninitialized-value warnings for a raw-launched VM (no
  `9200.scope`); expected, harmless.
* `qm start 9200` still cannot express this topology; the generated script is the launch path.

## 2. PyTorch under the qemu-ad-pve L2 (offline)

### Why a wheel disk

The L2 QEMU is `/opt/qemu-ad/bin/qemu-system-x86_64` (10.2.2). Its netdev backends are
`socket stream dgram hubport tap passt l2tpv3 bridge vhost-user vhost-vdpa` — **no `user`**.
`start-l2.sh` uses tap on the isolated `brl2` bridge (L1 <-> L2 only, no NAT), which is how L1
reaches the L2's sshd, but pip cannot reach an index. PR #11 worked around this by swapping in
Debian's QEMU with usernet. This run keeps qemu-ad and stages every wheel offline.

### Staging (all offline from the L2's point of view)

1. Dependency wheels downloaded from PyPI's JSON API with sha256 verification:
   [`scripts/l1-w10/fetch-win-wheels.py`](../scripts/l1-w10/fetch-win-wheels.py) (pins = the set
   torch 2.6.0+cu124 resolved to in PR #11: filelock, typing-extensions, networkx, jinja2,
   fsspec, setuptools, sympy 1.13.1, mpmath, markupsafe cp312 win_amd64; 9.8 MB).
2. CUDA wheel reused from the host (`/root/gpu-phase-l1/pytorch/`,
   `torch-2.6.0+cu124-cp312-cp312-win_amd64.whl`, 2 532 302 369 B, sha256
   `3313061c1fec4c7310cf47944e84513dcd27b6173b72a349bb7ca68d0ee6e9c0`), copied host -> L1 over
   the L1 NIC and re-verified there.
3. In L1, a read-only ISO (`WHEELS`, 2 542 911 488 B) with `wheelhouse\` +
   [`install-offline.cmd`](../scripts/l1-w10/install-offline.cmd) +
   [`pytorch-offline-bench.py`](../scripts/l1-w10/pytorch-offline-bench.py). The run used the same
   `genisoimage -J -joliet-long -R -iso-level 3` command inline; it is factored into
   [`scripts/l1-w10/mk-wheel-iso.sh`](../scripts/l1-w10/mk-wheel-iso.sh) (shellcheck-clean;
   tested afterwards with dummy wheels, including checksum-failure cleanup).
4. Attached to the L2 through the existing `EXTRA` hook of `start-l2.sh` — no script change:

```
EXTRA="-drive file=/root/w10/wheels.iso,format=raw,if=none,id=whl,media=cdrom,readonly=on -device ide-cd,drive=whl,bus=ide.2" /root/w10/start-l2.sh
```

Windows mounted it as `D:` (CDFS). Nothing was written to the Windows disk from Linux this time
(PR #11 used `ntfs-3g`).

### L2 start (14:27 EDT)

```
kvm ok: version=6.12.111-kvmpatch1 file=/lib/modules/6.12.111+deb13-amd64/updates/dkms/kvm.ko.xz patch_tag=step1-benign
REFUSE /dev/sda: has mounted partition(s)
RESOLVED Windows disk=/dev/sdb score=200 (serial=drive-scsi1 ... label=Windows ntfs+size=85899345920 )
L2 PID=1526 exe=/opt/qemu-ad/bin/qemu-system-x86_64
-netdev tap,id=n0,ifname=tapl2,script=no,downscript=no      (only netdev)
L2_SSH_UP after ~35s
```

### GPU + isolation checks

```
NVIDIA GeForce RTX 4080         Status OK  ConfigManagerErrorCode 0
NVIDIA High Definition Audio    Status OK  ConfigManagerErrorCode 0
High Definition Audio Controller Status OK ConfigManagerErrorCode 0
NVIDIA-SMI 576.88  Driver Version: 576.88  CUDA Version: 12.9   23MiB / 16376MiB
FB Total 16376 MiB / BAR1 Total 16384 MiB
pypi unreachable: No such host is known. (pypi.org:443)
pypi-ip unreachable: The request was canceled due to the configured HttpClient.Timeout of 8 seconds elapsing.
TcpTestSucceeded : False   (1.1.1.1:443)
CuPy  SGEMM 4096^3: 4.6 ms, 30.0 TFLOP/s; RESULT: PASS   (2nd run 29.9)
OpenCL H2D+kernel+D2H 768MiB moved, result_ok=True; FMA ~46880 GFLOP/s; RESULT: PASS (x2)
```

### Offline install (14:29:42–14:31:01 EDT)

`D:\install-offline.cmd C:\gputest\venv-offline` -> `C:\gputest\py\python.exe -m venv` (fresh, no
system site-packages) -> `pip install --no-index --find-links D:\wheelhouse torch==2.6.0+cu124`:

```
Looking in links: d:\wheelhouse
Successfully installed MarkupSafe-3.0.4 filelock-4.0.12 fsspec-2026.9.0 jinja2-3.1.6 mpmath-1.3.0 networkx-3.7 setuptools-84.0.0 sympy-1.13.1 torch-2.6.0+cu124 typing-extensions-4.16.0
INSTALL_RC=0          (wall ~79 s)
```

### Bench (14:31 EDT, `C:\gputest\venv-offline\Scripts\python.exe D:\pytorch-offline-bench.py`, two runs)

```
torch 2.6.0+cu124 file C:\gputest\venv-offline\Lib\site-packages\torch\__init__.py
cuda 12.4 avail True   device NVIDIA GeForce RTX 4080
VRAM free_MiB 15048 total_MiB 16375 ; FB Total 16376 MiB ; BAR1 Total 16384 MiB
fp32 512^3 max_abs_err_vs_cpu 5.531e-05
matmul torch.float32 4096^3: 4.53 ms, 30.37 TFLOP/s
matmul torch.float32 4096^3: 3.97 ms, 34.58 TFLOP/s
matmul torch.float32 4096^3: 3.96 ms, 34.68 TFLOP/s
matmul torch.float16 8192^3: 10.89 ms, 100.95 TFLOP/s
matmul torch.float16 8192^3: 10.90 ms, 100.90 TFLOP/s
matmul torch.float16 8192^3: 10.92 ms, 100.71 TFLOP/s
alloc 12 GiB ok checksum 3072
train 200 steps in 3.4s (58.9 steps/s) loss 3.341->1.959
RESULT PASS fp32 34.68 fp16 100.95          BENCH_RC=0
run 2: fp32 30.40 / 34.70 / 34.60, fp16 100.98 / 100.86 / 100.73, 59.1 steps/s, RESULT PASS fp32 34.7 fp16 100.98
```

(torch prints a harmless "Failed to initialize NumPy" warning: numpy is not a torch dependency
and was deliberately not staged.)

| Metric | PR #11 (stock Debian QEMU + usernet L2, L1 hand script) | This run (qemu-ad-pve L2, no net, L1 gen-launch script) |
| --- | --- | --- |
| fp32 4096³ first timing | 30.79 TFLOP/s (single timing) | 30.37 / 30.40 |
| fp32 4096³ best of 3 | — | **34.68 / 34.70** |
| fp16 8192³ | 95.30 (single timing) | **100.95 / 100.98** (best of 3; all six 100.7–101.0) |
| MLP 200 steps | 56.5 steps/s, 3.341 -> 1.959 | 58.9 / 59.1 steps/s, 3.341 -> 1.959 (same seed) |
| VRAM / BAR1 | 16376 / 16384 MiB | 16376 / 16384 MiB; 12 GiB live allocation OK |
| Driver / Code | 576.88 / 0 | 576.88 / 0 |

The first fp32 timing is the like-for-like number (PR #11's script timed once); it is within
~1.5 %. The best-of-3 and fp16 are higher than PR #11 but PR #11 took a single timing, so this
is not evidence that qemu-ad is faster — only that the qemu-ad L2 costs nothing measurable.

L1 dmesg during the L2 run: 0 lines matching `DMAR.*fault|IO_PAGE_FAULT|BUG|oops|AER`.

## 3. Cleanup and final state (14:31–14:35 EDT)

| Step | Result |
| --- | --- |
| Removed `C:\gputest\venv-offline` in the L2 (4+ GB) | done; C: free 42.3 GB |
| L2 `system_powerdown` via QMP | exited cleanly after ~20 s; `brl2`/`tapl2` torn down |
| Removed the L2 ssh key copy from L1 (`/root/w10/.w10key`, `/tmp/w10key`) | done |
| L1 `systemctl poweroff` | L0 QEMU for 9200 gone by 14:34:11 |
| Restored `9200.conf` from the pre-session backup | identical to backup; active section diff vs `9200.conf.amd-backup-20261002`: **empty** |
| Host GPU driver | `vfio-pci` (both functions) |
| Host dmesg | 3088 -> 3110 lines (vfio resets + `kvm: ignored rdmsr` only); fault-pattern count **53 -> 53**; broad `fault|BUG|oops|error` 235 -> 235 |
| `qm start 9102` (14:34:21) | running; RTX 4080 `ConfigManagerErrorCode 0`, nvidia-smi 576.88, 16376 MiB (14:35) |
| L1 KVM default | still patched: `kvm`/`kvm_amd` `6.12.111-kvmpatch1` from `updates/dkms`, `modules-load.d/kvm-patched.conf`, DKMS `installed` (checked just before poweroff) |
| Host | stock: kernel 7.0.12-1-pve, no reboot (uptime 6 weeks+), no apt, `/usr/bin/kvm` wrapper and `/opt/qemu-ad` unchanged (mtimes 2026-10-01). Only 9200's config was edited, and restored. |

### Leftovers

* Host `/root/gpu-phase-l1/qad-e2e/` (showcmd, generated script, logs, `wheelhouse/` 9.8 MB,
  `iso-extra.tar`), `9200.conf.pre-gen-e2e-20261005142135`, `kvm/e2e-*.sh` helpers. The torch
  wheel stays in `/root/gpu-phase-l1/pytorch/`.
* L1 `/root/w10/wheels.iso` (2.5 GB, reusable; delete to reclaim), `wheels.iso.sha256`,
  `VARS.before-gen-e2e.fd`, `live-argv-l2-e2e.txt`, `dmesg-lines-before-e2e`.
* Windows disk unchanged from PR #11 (still has `C:\gputest\pytorch-whl\` and torch in `C:\gputest\py`).
* Possible stale `/var/run/qemu-server/9200.vnc` socket file (no process), as before.

## Not run

* Linux L2 PyTorch.
* gen-launch with `--qemu-bin /opt/qemu-ad/...` at L0 (L0 stayed stock PVE QEMU by design).
* Re-generating with the generator on current `main` (it differs only by the `gpubr0` bridge id;
  PR #20 brings the `gpubr` fix).
* `mk-wheel-iso.sh` as a file inside L1 (the run used identical inline commands; script tested on a scratch box).
* Host reboot / apt / kernel / module / GRUB changes; edits to `/usr/bin/kvm` or `/opt/qemu-ad`;
  breakglass; VMs other than 9102 (clean shutdown/start) and 9200.
