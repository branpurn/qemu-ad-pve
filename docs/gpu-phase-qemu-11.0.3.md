# GPU phase retry with pve-qemu-kvm 11.0.3-4: still BLOCKED at the vIOMMU DMA step

Date: 2026-10-02. Author: Grok Bot for Brandon. Follows [gpu-phase-nested-viommu.md](gpu-phase-nested-viommu.md) (PR #2), whose "untested lead" was that QEMU 11.0.3 reworked the AMD vIOMMU page walk. This note records the retry on the same bare-metal host with the L0 QEMU replaced (side-loaded, not installed) by 11.0.3-4. Everything below was **run**; things that were not run are listed explicitly. No credentials or private addresses appear here.

## Verdict: still blocked (no change from QEMU 11.0.0)

| Test | QEMU 11.0.3-4 result |
| --- | --- |
| (a) L1 **without** `iommu=pt` (translated DMA domain), GPU driven by the L1 kernel (NVIDIA 550.163.01) | **Fails**, identical to 11.0.0: `RmInitAdapter failed! (0x25:0x65:1601)`, `nvidia-smi: No devices were found`, OpenCL `PLATFORM_NOT_FOUND`, HDA `azx_get_response timeout` / `Codec #0 probe error`. **21 new host `AMD-Vi IO_PAGE_FAULT` lines** for 02:00.0/02:00.1 |
| (a') L1 **with** `iommu=pt` (identity), same driver | **Works** (re-confirmed): `nvidia-smi` shows the RTX 4080, OpenCL 768 MiB H2D+kernel+D2H `RESULT: PASS`, HDA codec `Nvidia GPU a4 HDMI/DP` found, no new host faults |
| (b) L2 (KVM, GPU via vfio-pci) with L1 **without** `iommu=pt` | **Fails**: L2 boots, `nvidia` binds, `RmInitAdapter failed! (0x25:0x65:1601)`, `nvidia-smi: No devices were found`, HDA codec probe error, no L2 audio codec. No new host faults |
| (b) L2 (KVM, GPU via vfio-pci) with L1 **with** `iommu=pt` | **Fails** the same way |
| (c) control with `dma-remap=off` | **Not run** (instructions: skip when (a)/(b) fail) |

So the 11.0.3 `amd_iommu` rework does **not** make the real card's DMA follow the L1 IO page tables. The L1-itself-with-`iommu=pt` fallback still works; L1 -> L2 GPU hand-off and translated L1 DMA do not.

## New diagnostic: QEMU never registers an IOMMU notifier for the GPU

To see why, VM 9200 was relaunched once (translated mode, `dma-remap=on`) with QEMU tracing limited to `amdvi_pages_inval, amdvi_iotlb_inval, amdvi_all_inval, amdvi_command_exec, amdvi_page_fault, amdvi_devtab_inval, vfio_iommu_map_notify, vfio_listener_region_add_iommu, vfio_listener_region_skip`, then the same L1 GPU test as (a) (again 21 host IO_PAGE_FAULTs, same failure). Counts over that run (~4450 trace lines):

| Event | Count |
| --- | --- |
| `amdvi_command_exec` (L1 sent AMD-Vi commands) | ~2300 |
| `amdvi_pages_inval` (L1 invalidated IO page-table ranges) | ~1060 |
| `amdvi_devtab_inval` | 85 |
| `amdvi_all_inval` | 2 |
| `vfio_listener_region_skip` (non-RAM regions, e.g. `0xffc00000-0xffc83fff` and the GPU BAR sub-regions) | ~1210 |
| **`vfio_listener_region_add_iommu`** | **0** |
| **`vfio_iommu_map_notify`** | **0** |

`info mtree -f` shows the AMD IOMMU address spaces (`amd_iommu_devfn_*`, root `amdvi_root`) and the per-device `vfio-pci` bus-master spaces, but the VFIO container listener never sees an IOMMU memory region to attach a notifier to (`..._add_iommu` never fires) and no MAP notification ever reaches VFIO. L1's guest IOMMU programming is emulated (the invalidations arrive), but nothing shadows it into the L0 vfio container. That matches the earlier observation: the host IOMMU only holds the flat L0 mapping, so a real device DMAing to an L1 IOVA (here `0xffbc0000..`, `0xffae0100..`, `0xffff6004`, all in the 2-4 GiB hole of L1's address map) takes an `IO_PAGE_FAULT` in the host domain of VM 9200. Caveat: tracing was limited to the events above (no `vfio_listener_region_add_ram`); this is evidence of *absence of the notifier path*, not of its root cause in the source.

The new host faults are the same pattern as in the 11.0.0 run (domain differs only because it is a new VM start): one at `0xffff6004` on 02:00.1, ten at `0xffbc0000..0xffbc0900`, ten at `0xffae0100..0xffae0a00` on 02:00.0.

## Versions (read from the running systems)

| Component | Version |
| --- | --- |
| Host (L0) | AMD Ryzen 9 7950X, PVE `pve-manager 9.2.3`, kernel `7.0.12-1-pve`, cmdline `iommu=pt amd_iommu=on ...`, installed `pve-qemu-kvm 11.0.0-4` (unchanged) |
| L0 QEMU used for VM 9200 | `QEMU emulator version 11.0.3 (pve-qemu-kvm_11.0.3-4)`, extracted from the `.deb` to `/opt/qemu-11.0.3` and launched by hand (`exec -a /usr/bin/kvm`, `-L /opt/qemu-11.0.3/usr/share/kvm`), same argument list as `qm showcmd 9200`; no package installed, `/usr/bin/kvm` untouched |
| vIOMMU device | `-machine kernel-irqchip=split -device amd-iommu,intremap=on,xtsup=on,dma-remap=on` |
| GPU | RTX 4080 (AD103, 10de:2704) + HDA 10de:22bb, host IOMMU group with only these two, `vfio-pci` on host |
| L1 | Debian 13 cloud image, kernel `6.12.111+deb13-amd64`, `qemu-system-x86 1:10.0.13+ds-0+deb13u1` (this is the QEMU that launched L2), `ovmf 2025.02-8+deb13u1`, `nvidia-kernel-dkms 550.163.01-2` |
| L2 | Debian 13 (qcow2 overlay), same kernel, OVMF, 4 vCPU, 3 GiB, same driver |

Note that only the **L0** QEMU is 11.0.3; the QEMU that runs L2 inside L1 is still Debian's 10.0.13 (not relevant to the failure: L2's own vfio setup was normal).

## Command lines

L0 (VM 9200, abbreviated; full list = `qm showcmd 9200`):
```
/usr/bin/kvm(argv0) -L /opt/qemu-11.0.3/usr/share/kvm -id 9200 -name viommu-l1-gpu ... -machine type=q35+pve0
 -device vfio-pci,host=0000:02:00.0,id=hostpci0.0,bus=ich9-pcie-port-1,addr=0x0.0,multifunction=on
 -device vfio-pci,host=0000:02:00.1,id=hostpci0.1,bus=ich9-pcie-port-1,addr=0x0.1
 -machine kernel-irqchip=split -device amd-iommu,intremap=on,xtsup=on,dma-remap=${DMA_REMAP}    # DMA_REMAP=on in all runs
```
L2 (inside L1, `run-l2.sh gpu` with `GPUBDF=01:00`, fresh `OVMF_VARS_4M.fd` per run):
```
qemu-system-x86_64 -name l2-gpu -machine q35,accel=kvm -cpu host -smp 4 -m 3072
 -drive if=pflash,...OVMF_CODE.fd -drive if=pflash,...OVMF_VARS.fd -drive file=l2.qcow2,if=virtio -drive file=seed.iso,...
 -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0
 -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536 -vga none -display none
 -device pcie-root-port,id=rpg,chassis=11,slot=1
 -device vfio-pci,host=0000:01:00.0,bus=rpg,addr=0x0.0x0,multifunction=on
 -device vfio-pci,host=0000:01:00.1,bus=rpg,addr=0x0.0x1
```
L1 kernel cmdline: translated runs `... ro console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0` (`iommu: Default domain type: Translated`, group type `DMA`); pt runs add `iommu=pt` (group type `identity`). The translated mode was produced guest-side by moving `/etc/default/grub.d/99-iommu-pt.cfg` aside and `update-grub`; it was moved back at the end.

## Log excerpts

(a) translated, L1 dmesg:
```
NVRM: loading NVIDIA UNIX x86_64 Kernel Module  550.163.01
snd_hda_intel 0000:01:00.1: azx_get_response timeout, switching to polling mode: last cmd=0x000f0000
snd_hda_intel 0000:01:00.1: Codec #0 probe error; disabling it...
NVRM: GPU 0000:01:00.0: RmInitAdapter failed! (0x25:0x65:1601)
NVRM: GPU 0000:01:00.0: rm_init_adapter failed, device minor number 0
```
(a) host dmesg (new lines, host clock; the 11 older ones are from the 11:3x run on 11.0.0):
```
[14:29:08] vfio-pci 0000:02:00.1: AMD-Vi: Event logged [IO_PAGE_FAULT domain=0x0003 address=0xffff6004 flags=0x0000]
[14:29:16] vfio-pci 0000:02:00.0: AMD-Vi: Event logged [IO_PAGE_FAULT domain=0x0003 address=0xffbc0000 flags=0x0000]   (... 0xffbc0900)
[14:29:25] vfio-pci 0000:02:00.0: AMD-Vi: Event logged [IO_PAGE_FAULT domain=0x0003 address=0xffae0100 flags=0x0000]   (... 0xffae0a00)
```
(a') `iommu=pt`:
```
group 11 type=identity
NVIDIA GeForce RTX 4080 | 1MiB / 16376MiB | Driver 550.163.01 | CUDA 12.4
device: NVIDIA GeForce RTX 4080 mem MiB: 16072
H2D+kernel+D2H 768MiB moved, 0.43s, result_ok=True
RESULT: PASS
Codec: Nvidia GPU a4 HDMI/DP  (Vendor Id: 0x10de00a4)
```
(b) L2, identical in both L1 modes (L2 kernel dmesg):
```
snd_hda_intel 0000:01:00.1: azx_get_response timeout, switching to polling mode: last cmd=0x000f0000
snd_hda_intel 0000:01:00.1: Codec #0 probe error; disabling it...
NVRM: GPU 0000:01:00.0: RmInitAdapter failed! (0x25:0x65:1601)      (repeated per open attempt)
nvidia-smi: No devices were found      lspci: Kernel driver in use: nvidia (01:00.0), snd_hda_intel (01:00.1)
```
Host dmesg during the L2 runs: only `vfio-pci 02:00.x: resetting` / `reset done` pairs, no new IO_PAGE_FAULT (same as with 11.0.0: L2 DMA lands on valid-but-wrong L1 memory).

## Host health

Across all runs (2 cold L0 launches of 9200 for the translated/pt switch, 1 traced launch, several L2 starts, repeated resets of the card): all `vfio-pci ... reset done`, **no** AER, Xid, oops, `BUG:`, "fell off the bus", no hung `qm`. Every VM 9200 stop was a clean `qm shutdown 9200` (3 s each). Total IO_PAGE_FAULT lines in the host ring buffer at the end: 53 = 11 (earlier 11.0.0 run) + 21 (test (a)) + 21 (traced run).

## Observations worth keeping

* **A guest-side warm reboot of L1 in translated mode left L1 without network** (no frames transmitted from its virtio-net; serial console showed the login prompt). A clean `qm shutdown` + relaunch (cold boot) in the same mode had working networking. Seen once, not isolated or reproduced; the earlier 11.0.0 run did one in-guest L1 reboot without noting any problem, but whether that was in translated mode with networking checked is not recorded, so this may be an 11.0.3 vIOMMU reset-state issue or a one-off. Switching L1 modes was therefore done with shutdown + relaunch.
* Test-harness traps (not results): `run-l2.sh` needs `GPUBDF=01:00` (a bare `01` makes `host=0000:01.0`); a stale `OVMF_VARS` from a GPU-less boot drops L2 to the EFI shell (use a fresh `OVMF_VARS_4M.fd` copy per run); piping the test script into `ssh ... bash -s` lets the inner `ssh` swallow the rest of the script, so run it from a file.

## Not run

* (c) `dma-remap=off` control (skipped per plan, because (a) and (b) failed).
* Any QEMU newer than 11.0.3-4, other L0 kernels, the Intel vIOMMU path (`viommu=intel,caching-mode=on`), or any patch to `hw/i386/amd_iommu.c` / the VFIO notifier registration.
* An L2 audio functional test beyond the codec probe (L2 never got a codec).

## Next steps

1. The tracing shows the missing link is on the QEMU side (no IOMMU notifier is registered for the real device). That is worth reproducing on a stock upstream QEMU (current master) to see whether it is a PVE packaging/config issue (`vfio` + `amd-iommu` property interplay) or an upstream gap, and then report/patch upstream. Do not expect a PVE package bump alone to fix it: 11.0.0 and 11.0.3 behave identically.
2. Compare with the Intel vIOMMU path, which `qm` supports natively (`viommu=intel`, `caching-mode=on`, VFIO shadowing is mature there); on this AMD host it is emulated only and its suitability for the GPU is untested.
3. The fallbacks from [feasibility.md](feasibility.md) stand (reboot-selected kernel guest for GPU workloads, or per-VM kvm for non-GPU guests only).

## State left behind

VM 9200 stopped (not deleted); L1 grub has `iommu=pt` again (`/etc/default/grub.d/99-iommu-pt.cfg` restored); L0 QEMU 11.0.3 remains side-loaded under `/opt/qemu-11.0.3` (not installed, not used by any VM at rest) with the launch scripts, trace config and trace log in the host's `/root/gpu-phase-l1`. The RTX 4080 is back on `vfio-pci` and was handed back to VM 9102 (Windows 10): `Get-PnpDevice -Class Display` status OK, `ConfigManagerErrorCode 0`, `nvidia-smi` works (driver 576.88). No host package, kernel, GRUB, modprobe or VM-config changes.
