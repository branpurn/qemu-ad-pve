# GPU phase: the patched `qemu-ad-pve` binary as the L0 QEMU for the L1 VM 9200 (Intel vIOMMU path)

Date: 2026-10-02 (test window about 17:07-17:24 EDT). Author: Grok Bot for Brandon. Follows [gpu-phase-intel-viommu.md](gpu-phase-intel-viommu.md) (PR #4) and [gpu-phase-windows-l2.md](gpu-phase-windows-l2.md) (PR #5). Everything below was **run**; what was not run is listed at the end. No credentials or private addresses appear here.

## Verdict

* **As-is, the patched binary cannot boot VM 9200 with its normal devices.** The binary starts, has `intel-iommu` and `pcie-pci-bridge`, takes the same launch arguments and attaches both GPU functions, but the guest never reaches an OS: OVMF's boot menu lists only the cloud-init CD-ROM. The anti-detection patch rewrites the PCI vendor id of everything "Red Hat/Qumranet" (virtio-blk/scsi/net, PCIe root ports, PCI bridges, `pcie-pci-bridge`) to `8086`, so OVMF cannot see the `virtio-scsi` root disk (and a Linux guest would not bind virtio either). This is the same reason VM 9102 uses SATA + `e1000e`.
* **With a device-model variant of the launch script (root and data disk on AHCI `ide-hd`, NIC `e1000e`, nothing else changed; the binary itself still untouched) everything from PR #4 and PR #5 still works:**
  * L1 (Debian 13) boots with the RTX 4080 behind the `pcie-pci-bridge`, `intel-iommu` is active, `nvidia-smi` and OpenCL work in L1, **no IO_PAGE_FAULT** anywhere (host count stays at the baseline 53, L1 dmesg clean, `vtd_dmar_fault` 0).
  * Linux L2 (Debian, KVM, GPU on vfio-pci): `nvidia-smi` OK, OpenCL PASS, HDA codec found.
  * Windows 10 L2 (the PR #5 launcher and disk): GPU present, PnP `OK`, **`ConfigManagerErrorCode 0`**, `nvidia-smi` works (RTX 4080, 576.88), OpenCL and CUDA PASS.
* **The anti-detection patch matters only for L1's own view, not for the GPU path.** It does not touch `intel_iommu.c` or `hw/vfio`; the VFIO notifier registration is identical to stock (see trace table). The patch changes what L1 sees (SMBIOS/ACPI/PCI vendor ids/KVM CPUID signature), and it makes L1 stop recognising the host as KVM. The L2 guests run on the stock Debian QEMU inside L1, so the patch has no direct effect on them.
* One difference from the stock runs is **not** caused by the patch but by the QEMU version (10.2.2 vs 11.0.x): the emulated VT-d here advertises pass-through (ecap `f00f5a` vs `f00f1a`), so with `iommu=pt` the GPU's group in L1 is **identity-mapped** (`type=identity`), not `DMA`. In that state QEMU registers no IOMMU notifier at all and the GPU still works in L1; the translated path was tested separately (below).

## What the patched QEMU is

| Item | Value |
| --- | --- |
| Binary | `/opt/qemu-ad/bin/qemu-system-x86_64`, `QEMU emulator version 10.2.2` (built from `/opt/src/qemu-10.2.2` + `qemu-anti-detection/qemu-10.2.2.patch`, installed by `/root/qemu-ad-pve/qemu-ad-pve.sh`), 85 MB, mtime 2026-10-01 20:35 |
| Selected per VMID by | `/usr/bin/kvm` (wrapper script). VMIDs listed in `/etc/qemu-ad/vms` (9101, 9102) exec the side binary; everything else execs `/usr/bin/kvm.pve` (stock `pve-qemu-kvm 11.0.0-4`). VM 9200 is not in the list. |
| What the wrapper does to args for side VMs | drops `-id <n>`, strips `+pveN` from the `-machine` type, `exec -a /usr/bin/kvm`. Nothing else. |
| Standalone? | Yes. Dynamic libs all resolve, firmware/ROMs come from `/opt/qemu-ad/share/qemu`. `intel-iommu`, `amd-iommu`, `pcie-pci-bridge`, `vfio-pci` are all present. |
| How 9102 launches it | `qm start` runs `/usr/bin/kvm ...`; the wrapper execs the side binary with `machine: pc-q35-10.1` and 9102's `args:` (`-cpu host,kvm=off,-hypervisor,migratable=off,+invtsc`, `-smbios` types 0/2/3/4/17, SATA/`e1000e`, `ide-hd.model/serial/ver` globals). |

Patch content relevant here (read from the patch file, not changed): `PCI_VENDOR_ID_REDHAT_QUMRANET` `1af4`->`8086`, `PCI_VENDOR_ID_REDHAT` `1b36`->`8086` (`include/hw/pci/pci.h`); KVM CPUID signature `KVMKVMKVM` -> `GenuineIntel` (`target/i386/kvm/kvm.c`); SMBIOS defaults `ASUS`/`M4A88TD-M`; ACPI OEM id/table id/creator rewritten and an extra `BGRT` table; `QEMU0002` fw_cfg ACPI id -> `ASUS0002`; HDA codec, IDE/ATAPI, USB, EDID strings. No change to `hw/i386/intel_iommu.c`, `hw/vfio/*`, `kvm` accel or CPU feature code beyond the CPUID signature.

## Setup

Raw launch script derived from the PR #5 launcher (`qm showcmd 9200` output with both GPU functions behind a `pcie-pci-bridge`, `intel-iommu,intremap=on,caching-mode=on`, `kernel-irqchip=split`, 12 GiB RAM, extra 80 GB data disk for the Windows L2). Only changes:

```
exec -a /usr/bin/kvm /opt/qemu-ad/bin/qemu-system-x86_64 \     # was /usr/bin/kvm.pve
  (-id 9200 removed)  (type=q35+pve0 -> type=q35)               # what the wrapper does for side VMs
  -trace events=<same vtd/vfio events as PR #4> -D <log>
```
Variant (run 2 and 3): `virtio-scsi-pci`+`scsi-hd` (x2) -> `ahci`+`ide-hd` (x2, same bus slots and bootindex), `virtio-net-pci` -> `e1000e`. VM 9200's config was never edited (no `qm set`; it stayed on the AMD args); `diff` of `/etc/pve/qemu-server/9200.conf` against the pre-test AMD backup is empty at the end. 9102 was shut down cleanly first (`qm shutdown 9102 --timeout 180`, 8 s). The L2 launchers are the PR #4 (`run-l2.sh gpu`) and PR #5 (`run-w10.sh`, `-cpu host`) ones, unchanged. Differences to PR #4/#5 runs: L0 QEMU 10.2.2 (machine `pc-q35-10.2` instead of 11.0's `q35`), AHCI/`e1000e` instead of virtio, 12 GiB for L1.

## Results

### Run 1: patched binary, launch args as-is (virtio root disk and NIC)

* QEMU starts (no error), both vfio-pci functions attach, process runs. `info pci` shows the effect of the patch: host bridge/ICH9 `8086:*` as usual, but also PCIe root ports `8086:000c`, `pcie-pci-bridge` `8086:000e`, PCI bridges `8086:0001`, **virtio-net `8086:1000`, virtio-scsi `8086:1004`** (stock would be `1b36:*` / `1af4:*`).
* Serial console: OVMF `BootManagerMenuApp` listing only `EFI Firmware Setup` and `UEFI ASUS DVD-ROM`. The `virtio-scsi` disk is not offered, L1 never booted, no IP traffic from the L1 NIC on the tap in about 2.5 minutes of waiting. The trace has no `vtd_dmar_enable`/`vfio_listener_region_add_iommu` (no OS ever enabled DMAR).
* Stopped with QMP `system_powerdown` (OVMF ignores it) and then QMP `quit` (graceful QEMU exit, firmware only, no guest OS, nothing written to disks by an OS). GPU reset and returned to vfio-pci (host dmesg: `reset done` on both).
* I did not prove that a Linux guest would also fail to bind virtio with these ids; that is inferred from the OVMF result plus the patch (guest drivers match vendor `1af4`).

### Run 2: variant (AHCI + `e1000e`): L1, Linux L2, Windows L2 in one L1 boot

| Check | Result |
| --- | --- |
| L1 boots (Debian 13, kernel `6.12.111+deb13-amd64`, `iommu=pt` on cmdline), network up | yes (about 1 min) |
| L1 GPU group type | `identity` (see ecap note) |
| L1 `nvidia-smi` (NVIDIA 550.163.01), identity group | OK, RTX 4080, 16376 MiB |
| L1 OpenCL 768 MiB, identity | PASS, 0.42 s |
| L1: unbind GPU+audio, `echo DMA > /sys/kernel/iommu_groups/11/type` (runtime, no reboot), rebind | group type `DMA`; `nvidia-smi` OK; OpenCL PASS, 0.38 s |
| L1 dmesg after the switch | only `NVRM: loading ...`; no DMAR fault, no IO_PAGE_FAULT |
| Linux L2 (stock Debian QEMU 10.0.13 in L1, GPU vfio-pci, group `DMA`) | `nvidia-smi` OK, OpenCL PASS (0.57 s), audio codec `Nvidia GPU a4 HDMI/DP`, driver `nvidia`/`snd_hda_intel` bound in L2 |
| Windows 10 L2 (PR #5 launcher, `-cpu host`, disk copy `/dev/sda` in L1) | SSH answered within about 1 minute of launch, `w10-code43-check.ps1`: `ok`/exit 0, RTX 4080 PnP `OK`, **ConfigManagerErrorCode 0**, driver 32.0.15.7688 (NVIDIA 576.88), `other_code43` empty, `nvidia-smi` 576.88 / 16376 MiB P8 |
| Windows OpenCL / CUDA | OpenCL PASS (about 46.9 TFLOP/s fp32 one-shot, 1.09 s transfer test incl. cold start), CuPy SGEMM 4096^3 4.5 ms (30.5 TFLOP/s), reduction rel. err 6e-8, PASS. One-shot values, not a benchmark. |
| Win32_ComputerSystem | QEMU / `Standard PC (Q35 + ICH9, 2009)`, `HypervisorPresent True` (same as PR #5; L2 is stock QEMU) |
| Shutdown | Windows via `shutdown /s`; L1 via `qm shutdown 9200 --timeout 120` (3 s) |

### Run 3: variant, fresh L1 boot, group left `identity` (the `iommu=pt` default)

Cold boot, no runtime change. Boot only (no GPU use yet): zero IOMMU-notifier registrations (see trace table). Then the PR #4 Linux L2 test with the group in its default `identity` state: L2 up, driver bound, `nvidia-smi` printed its table (rows were filtered out of my saved copy, so only the header/borders are saved), OpenCL PASS (0.57 s), HDA codec found. L1 vfio-pci replaces the identity domain with a translating one when it takes the group, which is why notifiers appear then.

### Trace: VFIO notifier registration with the patched binary

Same trace events as PR #4. Counts per whole L0 QEMU lifetime:

| Event | Run 2 (variant; identity boot, runtime switch to DMA, direct tests, Linux L2, Windows L2) | Run 3 after boot only | Run 3 after Linux L2 | Stock 11.0.0, PR #4 run 2 |
| --- | --- | --- | --- | --- |
| `vfio_listener_region_add_iommu` | **2** | 0 | **2** | 2 |
| `vfio_iommu_map_notify` MAP / UNMAP | 45233 / 15132 | 0 / 0 | 8749 / 6180 | 35777 / 9212 |
| `vtd_dmar_enable` / `vtd_ir_enable` | 1 / 1 | 1 / 1 | 1 / 1 | 1 / 1 |
| `vtd_replay_ce_valid` | 2 | 0 | 2 | 2 |
| `vtd_inv_desc_iotlb_pages` | 4858 | 0 | 1407 | 3383 |
| `vtd_dmar_fault` | **0** | 0 | **0** | 0 |

The same split address space (`vtd-00.0-dmar`, two ranges around the MSI window) is registered as in PR #4, and MAP notifications flow. So the patch does not break vIOMMU or VFIO notifier registration. The totals are not directly comparable to the stock column (different QEMU version, Windows L2 included in run 2).

### What L1 sees (anti-detection effects), run 2 L1 (before any test)

| Item | Patched 10.2.2 | Stock 11.0.0 (PR #4 data, where recorded) |
| --- | --- | --- |
| `systemd-detect-virt` | `vm-other` (no KVM recognised; CPU `hypervisor` flag still present; clocksource `tsc`, no kvm-clock / kvm-guest messages) | not recorded in PR #4 (stock QEMU exposes the `KVMKVMKVM` leaf, so L1 would normally report `kvm`; that was not measured here) |
| DMI | `sys_vendor=ASUS`, `product_name=M4A88TD-M`, `product_version=ASUS-PC`, `chassis_vendor=ASUS`, BIOS vendor still `Proxmox distribution of EDK II` (4.2025.05-2) | n/a |
| ACPI OEM / creator | `INTEL  PC8086`, creator `PTL` (APIC, DMAR, DSDT, FACP, MCFG, SSDT, WAET, BGRT); a second `BGRT` from the firmware (OEM `EDK2`) | `BOCHS  BXPC`, creator `BXPC` (DMAR) |
| PCI ids | all QEMU-made bridges/root ports/virtio `8086:*` (see run 1); VGA `1234:1111` unchanged | `1b36:*` / `1af4:*` |
| Disk / CD model | `ASUS HARDDISK`, `ASUS DVD-ROM` | `QEMU HARDDISK` etc. |
| CPU | `AMD Ryzen 9 7950X` (`cpu: host`; no `-hypervisor` here, 9102's `-cpu` args were not used) | same |
| VT-d | `cap 80d2008c222f0686 ecap f00f5a` (PT bit set) | `cap ...06c6 ecap f00f1a` |
| Nested KVM in L1 | `/dev/kvm` present, `kvm_amd nested=1`, L2s ran with `accel=kvm` | same |

Things that did **not** matter: L1 not recognising KVM (L1 has no KVM guest drivers it needs; the GPU, vIOMMU and nested KVM all work), the `GenuineIntel` KVM signature, SMBIOS/ACPI strings. Things that **do** matter: the PCI vendor id rewrite (virtio unusable; any L1 needs SATA/`e1000e`/NVMe-style devices, or a patch variant without the pci.h hunks), and the machine type (`q35+pve0` not available in 10.2.2, so the wrapper-style `type=q35` is needed).

## Not run / caveats

* No binary variant was made or tried: the PCI-id behaviour is compiled in, and rebuilding or installing anything was out of scope. The "variant" is a device-model variant of the launch script only; the binary in `/opt/qemu-ad` was executed in place, unmodified. No copy of the binary was needed.
* Not isolated: a vanilla (unpatched) QEMU 10.2.2 control. Version-vs-patch attribution (ecap `f00f5a`, identity group) rests on the patch not touching `intel_iommu.c`, plus 11.0.0's `-device intel-iommu,help` listing no `pt` property while 10.2.2 lists `pt` (default on). Not on-disk verified that `/opt/qemu-ad` was built from exactly that patch file; its behaviour (vendor ids, ASUS DMI, `GenuineIntel` signature) is consistent with it.
* Not run: `qm start 9200` through the `/usr/bin/kvm` wrapper (9200 is not in `/etc/qemu-ad/vms`; not added), the AMD vIOMMU path with this binary, 9102-style `-cpu ...,kvm=off,-hypervisor` and SMBIOS args on L1, `hypervisor=off` or the Hyper-V flag set on L1, any performance measurement, long stress, reboot of L1 with the GPU attached, display output, GPU audio playback, `qm`-native topology (still fails with `group used in multiple address spaces`, PR #4).
* L1's `iommu=pt` grub drop-in was not touched this time (runtime `DMA` switch instead, not persistent).

## Versions

| Component | Version |
| --- | --- |
| Host (L0) | AMD Ryzen 9 7950X, PVE 9.2.3, kernel `7.0.12-1-pve`, `amd_iommu=on iommu=pt` |
| L0 QEMU under test | `/opt/qemu-ad/bin/qemu-system-x86_64` = QEMU 10.2.2 + anti-detection patch (`qemu-ad-pve`), machine `pc-q35-10.2` |
| Stock / side-loaded (not used in this run) | `pve-qemu-kvm 11.0.0-4` (installed), `11.0.3-4` under `/opt/qemu-11.0.3` |
| L1 | Debian 13, kernel `6.12.111+deb13-amd64`, `nvidia-kernel-dkms 550.163.01`, `qemu-system-x86 1:10.0.13+ds-0+deb13u1` |
| L2 | Debian 13 (same kernel/driver) and Windows 10 Pro 19045 with NVIDIA 576.88 |
| GPU | RTX 4080 (AD103, 10de:2704) + HDA 10de:22bb |

## State left behind

VM 9200 stopped, config `diff` against the AMD backup empty. No QEMU process left (checked: none for 9200, `w10-l2`, `l2-gpu`). GPU on `vfio-pci` (both functions), host `IO_PAGE_FAULT` count 53 (unchanged baseline). 9102 restarted (about 29 s) and verified: `ConfigManagerErrorCode 0`, `nvidia-smi` 576.88. New files only under `/root/gpu-phase-l1/patched/` on the host (launch scripts, trace logs, notes); inside L1: `/root/w10/VARS.fd` was used by the Windows boot (and a `VARS.before-patched-run.fd` copy made), the Windows data disk copy (VM 9200's own `scsi1` volume) was booted. A stale `/var/run/qemu-server/9200.vnc` socket file remains from the raw launches. No change to `/usr/bin/kvm`, `/opt/qemu-ad`, `/etc/qemu-ad/vms`, host packages, kernel, GRUB, modprobe, or any other VM.

## Next steps

1. If the patched QEMU is wanted at L0 for an L1: either build a variant without the `pci.h` vendor-id hunks (and keep the rest) or always use SATA/`e1000e`/NVMe for L1's own devices; `qm start` would need `9200` added to `/etc/qemu-ad/vms` plus the same bridge workaround from PR #4.
2. Decide whether L1 hiding KVM matters; L1's own `-cpu` flags (`kvm=off`, `-hypervisor`) were not tried here.
