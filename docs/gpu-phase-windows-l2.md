# GPU phase: Windows 10 as the L2 guest with the RTX 4080 on the Intel-vIOMMU path (host -> L1 -> L2)

Date: 2026-10-02 (test window about 16:45-17:05 EDT). Author: Grok Bot for Brandon. Follows [gpu-phase-intel-viommu.md](gpu-phase-intel-viommu.md) (PR #4: Linux L2 works with `intel-iommu` caching-mode in L1). Everything below was **run**; what was not run is listed at the end. No credentials or private addresses appear here.

## Verdict: works, with caveats

A Windows 10 Pro (build 19045) L2 inside the L1 VM 9200 gets the RTX 4080 with the stock NVIDIA 576.88 driver:

* GPU present, `PnpStatus OK`, **`ConfigManagerErrorCode 0` (no Code 43)**, `nvidia-smi` works (RTX 4080, 16376 MiB, driver 576.88, CUDA 12.9, WDDM).
* The GPU's HDA function (`NVIDIA High Definition Audio`) and the HD Audio controller also show problem code 0.
* OpenCL and CUDA compute checks PASS; `dxdiag` shows Direct3D feature level 12_1, DDI 12, WDDM 2.7, 16050 MB dedicated memory; `dwm.exe` runs on the GPU.
* **Anti-detection is not needed at L2** for this driver: the very first boot with a plain `-cpu host` (no `kvm=off`, no `hv_vendor_id`, KVM signature visible, stock Debian QEMU 10.0.13) already gave Code 0. A second cold boot with `-cpu host,kvm=off,hv_vendor_id=GenuineIntel,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff` also gave Code 0. So both combinations tried work; the patched `qemu-ad-pve` was not involved anywhere in L2.

Caveats: same as PR #4 (raw QEMU launch script for L1 instead of `qm start`; GPU on a conventional-PCI bridge in L1; no identity-mapped mode on the Intel vIOMMU; performance not benchmarked), plus the Windows-specific ones below (first boot applies pending updates; guest clock; only the checks listed were run).

## Setup

### Windows disk (no image built from scratch)

* Source: the 80 GB SATA volume of VM 9101 (`w10-bm`, Win10 with NVIDIA 576.88 already installed). It was **only read**: `qemu-img convert -f raw -O qcow2` from the (inactive) LV, then `qemu-img compare` reported "Images are identical". 9101 was not started, its config and snapshots were not touched; nothing was written to 9101's or 9102's volumes.
* The copy is a new qcow2 on `fast_storage` (80 GiB virtual, about 28 GiB allocated after the copy; the convert took about 20 s). It was attached to 9200 as a second virtual disk (`scsi1`) so L1 sees an 80 GB raw disk (`/dev/sda`, GPT: 100 MB ESP, 16 MB MSR, NTFS). The L1 root disk (30 GB) could not hold it. The L2 uses `/dev/sda` directly as a raw SATA disk.
* The 4 MB EFI vars volume of 9101 was also read once (`dd`) and its first 528 KiB (the real VARS size) used as the L2 `OVMF_VARS`. With this VARS file the L2 booted straight into Windows (the Windows Boot Manager entry was already in NVRAM, at the same q35 AHCI port as in 9101), so the "VARS template built without the GPU" workaround from PR #4 caveat 6 was **not needed** here. (A fresh VARS file was not tried for Windows, so whether Windows also needs it was not determined.)

### VM 9200 (L1) config changes for the run (all restored afterwards)

```
machine: q35,viommu=intel     # was q35
args: (deleted)               # was the amd-iommu args line
memory: 12288                 # was 6144 (Windows L2 uses 6 GiB)
scsi1: fast_storage:9200/vm-9200-disk-2.qcow2,discard=on,size=80G     # new
```
L1 was started with the same raw-launch approach as PR #4 (script generated from `qm showcmd 9200`; both GPU functions behind a `pcie-pci-bridge`; `qm start` would fail with `group 13 used in multiple address spaces`). 9102 was shut down cleanly first (`qm shutdown 9102 --timeout 180`, 7 s).

### L2 QEMU (inside L1: Debian `qemu-system-x86 1:10.0.13+ds-0+deb13u1`, OVMF 2025.02)

```
qemu-system-x86_64 -name w10-l2 -machine q35,accel=kvm -cpu host -smp 4 -m 6144 \
  -drive if=pflash,format=raw,readonly=on,file=OVMF_CODE.fd  -drive if=pflash,format=raw,file=VARS.fd \
  -drive file=/dev/sda,format=raw,if=none,id=wdisk,cache=none,aio=native,discard=unmap \
  -device ide-hd,drive=wdisk,bus=ide.1,rotation_rate=1 \
  -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2223-:22,hostfwd=tcp:127.0.0.1:3390-:3389 -device e1000e,netdev=n0 \
  -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536 \
  -monitor unix:mon,server,nowait -qmp unix:qmp,server,nowait \
  -vga std -display none -usb -device usb-tablet -serial none \
  -device pcie-root-port,id=rpg,chassis=11,slot=1 \
  -device vfio-pci,host=0000:02:01.0,bus=rpg,addr=0x0.0x0,multifunction=on \
  -device vfio-pci,host=0000:02:01.1,bus=rpg,addr=0x0.0x1 \
  -pidfile w10.pid -daemonize
```
(`02:01.x` is the GPU's address inside L1.) Disk is SATA (q35 AHCI), NIC is `e1000e`, no virtio devices, as required. The NIC is QEMU user-mode (NAT), so the guest, which kept 9101's hostname, is isolated and cannot clash with it on the LAN. A virtual `-vga std` adapter is present in addition to the GPU, used for QMP/monitor `screendump` (the Windows desktop is also rendered by the NVIDIA GPU, see below). Remote access was SSH to the guest's OpenSSH via the forwarded port, reached through L1.

Run B differs only in `-cpu`: `host,kvm=off,hv_vendor_id=GenuineIntel,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff`.

## Results

### Device state (`w10-code43-check.ps1`, run inside the guest with `powershell -NoProfile -ExecutionPolicy Bypass -File`)

| | Run A: `-cpu host` (first boot) | Run B: `kvm=off,hv_vendor_id=...` (cold boot) |
| --- | --- | --- |
| `result` / `exit_code` | `ok` / 0 | `ok` / 0 |
| NVIDIA display device | NVIDIA GeForce RTX 4080, `VEN_10DE&DEV_2704`, PnP `OK`, Present | same |
| `ConfigManagerErrorCode` | **0** | **0** |
| Driver (Win32_PnPSignedDriver) | 32.0.15.7688 (= NVIDIA 576.88), dated 2025-06-24 | same |
| `nvidia-smi` | exit 0, RTX 4080, 576.88 | exit 0, RTX 4080, 576.88 |
| `other_code43` | none | none |
| `nvlddmkm` events in System log | none seen (checked after run A) | not checked separately |
| Win32_ComputerSystem `HypervisorPresent` | True | True |
| Guest OS | Windows 10 Pro 10.0.19045, 64-bit, model "Standard PC (Q35 + ICH9, 2009)", manufacturer QEMU | same |

(The Hyper-V `hv_*` flags and the hypervisor CPUID bit keep `HypervisorPresent` True even in run B. `kvm=off` only hides the KVM signature leaf. `hypervisor=off` was not tried.) Other NVIDIA functions in run A: `High Definition Audio Controller`, `NVIDIA High Definition Audio`, both problem code 0. The `Unknown`-status duplicate NVIDIA entries in Device Manager are ghosts from the 9101 history and not present devices.

`nvidia-smi` (run A, abridged): `NVIDIA-SMI 576.88  Driver Version: 576.88  CUDA Version: 12.9`, `NVIDIA GeForce RTX 4080  WDDM  00000000:01:00.0`, `P8  11W / 320W`, `18MiB / 16376MiB`, processes `LogonUI.exe` and `dwm.exe` (type `C+G`, i.e. graphics contexts on the GPU).

### Compute / graphics checks (inside the Windows L2)

Embedded Python 3.12.10 and, for CUDA, CuPy (`cupy-cuda12x[ctk]`, CUDA runtime 12.9) were installed into `C:\gputest` of the copied disk.

| Check | Run A | Run B |
| --- | --- | --- |
| OpenCL (`pyopencl`): platform `NVIDIA CUDA`, device RTX 4080, 76 CUs, 16375 MiB; 768 MiB H2D + add kernel + D2H, result verified | PASS, 1.45 s | PASS, 0.92 s |
| OpenCL FMA kernel (event-profiled, fp32) | about 46.9 TFLOP/s, finite output | about 50.9 TFLOP/s, finite output |
| CUDA (CuPy), cc 8.9: 4096x4096 fp32 matmul x10 | 4.5 ms each, about 30.6 TFLOP/s | 4.4 ms, about 31.0 TFLOP/s |
| CUDA reduction sum of 2^24 floats, relative error | 6e-8 | 6e-8 |

The transfer times include Python/driver cold-start costs and are **not a benchmark** (the Linux L2 in PR #4 took 0.53 s for the same transfer). The TFLOP/s numbers are one-shot values, not stress results.

Graphics: `dxdiag` reports Card `NVIDIA GeForce RTX 4080`, Driver Model WDDM 2.7, DDI Version 12, Feature Levels 12_1 down to 9_1, Dedicated Memory 16050 MB, Hardware Scheduling supported (not enabled). No 3D rendering benchmark or D3D application was run. No physical display was attached to the GPU outputs, so display output was not tested; the screen capture came from the virtual `-vga std` adapter.

### Host health

No hung `qm`, no oops, no AER or Xid. Host `IO_PAGE_FAULT`/AER/Xid-type dmesg matches stayed at the baseline count (53, all from earlier runs, none new); L1's own dmesg after `dmesg -C` at L2 start showed only the disk probe line. The GPU returned to `vfio-pci` on both functions after L1 shutdown.

## Windows-specific observations

* **First boot on new virtual hardware is slow:** about 3-4 minutes of "Working on updates / Updating your system" (a pending update pass plus device re-enumeration) before SSH answered. Later boots took well under a minute. No driver reinstall was needed; the 576.88 driver bound immediately.
* The guest kept 9101's hostname (`W10-BM`) and user accounts. Activation state was not checked.
* The guest clock was 4 h off (QEMU default `-rtc base=utc` while Windows keeps local time). Add `-rtc base=localtime` for a real setup. Not relevant for the GPU result.
* The Windows setup had no virtio drivers and needed none (SATA + e1000e).

## Versions

| Component | Version |
| --- | --- |
| Host (L0) | AMD Ryzen 9 7950X, PVE 9.2.3, kernel `7.0.12-1-pve`, stock `pve-qemu-kvm 11.0.0-4` (no side-loaded QEMU used in this run) |
| L1 | Debian 13, kernel `6.12.111+deb13-amd64`, `qemu-system-x86 1:10.0.13+ds-0+deb13u1`, `ovmf 2025.02-8+deb13u1`, `intel-iommu` caching-mode (as PR #4) |
| L2 | Windows 10 Pro 22H2-era build 19045, NVIDIA 576.88 (WDDM 2.7, CUDA 12.9), Python 3.12.10, pyopencl, CuPy (cupy-cuda12x) |
| GPU | RTX 4080 (AD103, 10de:2704) + HDA 10de:22bb |

## Not run

* The patched `qemu-ad-pve` at L2 (not required), `hypervisor=off`, other `-cpu` variants (e.g. `hv_time`, `hv_stimer`, full Hyper-V enlightenment set), and q35 machine-type variants.
* Any 3D/game workload, display output to a physical monitor, GPU audio playback, driver reinstall or update inside L2, repeated or warm reboots beyond the two cold boots, sleep/hibernate, Windows activation, long stress or thermal tests, performance measurement beyond the one-shot numbers above.
* Whether a fresh (non-9101) OVMF VARS file also boots Windows with the GPU present; a Windows L2 on an MSI/INTx comparison (the Linux HDA "Disabling MSI" caveat was not inspected on the Windows side).
* QEMU 11.0.3 side-loaded in L1 (only the stock L1 QEMU 10.0.13 inside L1 and stock 11.0.0 on L0 were used).

## State left behind

* VM 9200 stopped; its config restored byte-for-byte to the AMD args (`diff` against the pre-test backup is empty). VM 9102 restarted and verified healthy (Display `OK`, `ConfigManagerErrorCode 0`, `nvidia-smi` 576.88). 9101 never started, not modified.
* **Kept:** the Windows disk copy as an unreferenced qcow2 in 9200's image directory on `fast_storage` (80 GiB virtual, about 33 GiB on disk after the run; it now also contains the Python/CuPy test files in `C:\gputest` and the applied Windows updates). `fast_storage` still has more than 1 TB free. Helper files (L1 launch script generated from `qm showcmd`, VARS copy from 9101, config backups) are under `/root/gpu-phase-l1/win/` on the host; the L2 launcher and VARS live in `/root/w10/` inside L1. To remove everything: delete that qcow2 and the two directories.
* No host package, kernel, GRUB, modprobe, wrapper or other VM changes.

## Next steps

1. If this path is wanted for real use: add a reproducible L1 topology (see PR #4 next steps), `-rtc base=localtime`, and measure map-heavy CUDA workloads under the translated-DMA vIOMMU.
2. Try a fresh Windows image/VARS (no 9101 state) and a physical display to close the remaining gaps above.
