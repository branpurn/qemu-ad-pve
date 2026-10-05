# GPU phase: RTX 4080 -> L1 (AMD vIOMMU, DMA remap) -> L2 via vfio-pci

Date: 2026-10-02. Author: Grok Bot for Brandon. Follows [viommu-nested-spike.md](viommu-nested-spike.md) (no-GPU phase, PR #1). Everything below was **run** on the bare-metal PVE host with a new L1 VM 9200; the owner approved the GPU phase explicitly. No credentials appear here.

## Verdict: BLOCKED (at the DMA-remapping step), with a working fallback for L1

| Step | Result |
| --- | --- |
| 4080 (+HDMI audio) passed to a q35/OVMF L1 with `amd-iommu,dma-remap=on` | **Works.** No QEMU error, no `requires dma-remap=1`, GPU + audio visible in L1, own IOMMU group (11), L1 shows AMD-Vi with interrupt remapping |
| L1 kernel drivers use the GPU **with `iommu=pt`** (identity domain) | **Works.** `nvidia-smi` shows the 4080 (driver 550.163.01), OpenCL 768 MiB H2D+kernel+D2H test PASS, HDA codec probes, **0 host IOMMU faults** |
| L1 kernel drivers use the GPU **with a translated DMA domain** (L1 default, no `iommu=pt`) | **Fails.** `RmInitAdapter failed! (0x25:0x65:1601)`, HDA `azx_get_response timeout`, and the **host** logs `AMD-Vi: Event logged [IO_PAGE_FAULT ...]` for 02:00.0/02:00.1 at IOVAs L1 allocated (e.g. `0xffbc0000`, `0xffff6004`) |
| L1 hands the GPU to an L2 guest with vfio-pci (QEMU, KVM) | **GPU visible in L2, driver loads, GPU init fails** in both L1 modes (`iommu=pt` or not): same `RmInitAdapter failed! (0x25:0x65:1601)`, `nvidia-smi: No devices were found`, HDA codec probe fails in polling mode (a pure DMA symptom) |
| Reset behaviour | **No problem seen.** Repeated resets of the real card (L1 boot, one in-guest L1 reboot, six L2 starts/kills, L1 stop): all `vfio-pci ... reset done`, no AER/Xid/"fell off the bus", host never hung, card returned to `vfio-pci` after L1 stop |

Why blocked: the real card's DMA does **not** go through the shadowed L1 IO page tables. The host IOMMU only ever sees the flat L0 mapping (L1 guest-physical -> host-physical). Evidence: (a) in L1 with a translated domain the card DMAs to IOVAs inside the 2-4 GiB hole of L1's address map and the host IOMMU faults, which can only happen if L1's mappings never reached the host IOMMU; (b) in L2 there are no host faults at all while DMA is broken, which fits the card using L2 guest-physical addresses as if they were L1 guest-physical addresses (valid L1 RAM, wrong memory, no fault). In other words the vIOMMU is present and the guest believes it is translating, but the VFIO MAP/UNMAP shadowing path for a real device is not effective on this QEMU. The emulated-NVMe test of the previous phase could not reveal this because emulated DMA goes through QEMU's own translate path.

The result is for this exact stack only (below). One concrete lead, **not tested**: `pve-qemu-kvm 11.0.3-4` (what the previous phase ran inside VM 9000) contains a rework of the AMD vIOMMU page-table walk that 11.0.0 lacks (`amd_iommu: Follow root pointer before page walk and use 1-based levels`, `Reject non-decreasing NextLevel in fetch_pte()`, command-buffer head/tail fixes; diff of `hw/i386/amd_iommu.c` v11.0.0 vs v11.0.3). The host runs 11.0.0-4, and host package changes were out of scope, so whether 11.0.3 fixes the shadowing is open. The L2-GPU-init failure could in principle also have a second, independent cause (0x25/0x65 is a generic RM init error); the L1 identity-mode success only proves the card, driver, BAR/ROM handling and L0 passthrough are fine.

## Versions (read from the running systems)

| Component | Version |
| --- | --- |
| Bare-metal host (L0) | AMD Ryzen 9 7950X, PVE `pve-manager 9.2.3`, kernel `7.0.12-1-pve`, cmdline `iommu=pt amd_iommu=on ...`, `qemu-server 9.1.17`, **`pve-qemu-kvm 11.0.0-4`** (QEMU 11.0.0), `pve-edk2-firmware 4.2025.05-2`, host `kvm_amd`: `nested=1 avic=Y npt=Y` |
| Host QEMU for L1 | vendor binary (`/usr/bin/kvm.pve`) via the stock wrapper; VM 9200 is not in the qemu-ad list, so the side QEMU was not involved |
| GPU | GeForce RTX 4080 (AD103, 10de:2704) 02:00.0 + audio 02:00.1 (10de:22bb), host IOMMU group 13 holds only these two, both on `vfio-pci`, reset methods `flr bus`, BAR1 16 GiB |
| L1 | Debian 13 generic cloud image, kernel `6.12.111+deb13-amd64`, Debian `qemu-system-x86 1:10.0.13+ds-0+deb13u1`, `ovmf 2025.02-8+deb13u1` |
| NVIDIA driver (L1 control test and L2) | Debian `nvidia-kernel-dkms 550.163.01-2` with `firmware-nvidia-gsp 550.163.01-2` (proprietary, non-free) |
| L2 | Debian 13 cloud image (qcow2 overlay), same kernel as L1, OVMF, 4 vCPU, 3 GiB |

## L1 VM 9200 `viommu-l1-gpu` (final config)

```
args: -machine kernel-irqchip=split -device amd-iommu,intremap=on,xtsup=on,dma-remap=on
balloon: 0
bios: ovmf
cores: 8
cpu: host
efidisk0: fast_storage:9200/vm-9200-disk-0.qcow2,efitype=4m,pre-enrolled-keys=0,size=528K
hostpci0: 0000:02:00,pcie=1
ide2: fast_storage:9200/vm-9200-cloudinit.qcow2,media=cdrom
machine: q35
memory: 6144
net0: virtio=...,bridge=vmbr1,firewall=0        # DHCP on the LAN bridge
scsi0: fast_storage:9200/vm-9200-disk-1.qcow2,discard=on,size=30G
scsihw: virtio-scsi-single
serial0: socket
vga: std
```
Relevant parts of `qm showcmd`:
```
-machine pflash0=pflash0,pflash1=drive-efidisk0,hpet=off,type=q35+pve0
-machine kernel-irqchip=split
-device vfio-pci,host=0000:02:00.0,id=hostpci0.0,bus=ich9-pcie-port-1,addr=0x0.0,multifunction=on
-device vfio-pci,host=0000:02:00.1,id=hostpci0.1,bus=ich9-pcie-port-1,addr=0x0.1
-device amd-iommu,intremap=on,xtsup=on,dma-remap=on
```
OVMF is needed so the 16 GiB BAR gets a 64-bit window (L1 kernel shows BAR1 at `0x380000000000-0x3803ffffffff`). Disk snapshot `pre-gpu` was taken before `hostpci0` was added (rolling back to it also removes `hostpci0`).

L1 setup (inside L1, no GPU yet): `/etc/modprobe.d/vfio-gpu.conf` (`options vfio-pci ids=10de:2704,10de:22bb`, `softdep nouveau/snd_hda_intel pre: vfio-pci`, nouveau/nova_core/nvidiafb blacklisted), `vfio vfio_iommu_type1 vfio_pci` in the initramfs, so the card binds to `vfio-pci` at boot before any driver touches it.

## L1 evidence

Kernel cmdline run 1: `BOOT_IMAGE=/boot/vmlinuz-6.12.111+deb13-amd64 root=PARTUUID=... ro console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0` (no `iommu=`). Run 2 adds `iommu=pt`.

```
AMD-Vi: Using global IVHD EFR:0x29d7, EFR2:0x0
iommu: Default domain type: Translated            (run 2: Passthrough (set via kernel command line))
AMD-Vi: Using strict mode due to virtualization
pci 0000:01:00.0: Adding to iommu group 11        <- GPU
pci 0000:01:00.1: Adding to iommu group 11        <- its audio function, same group, nothing else in it
AMD-Vi: Extended features (0x29d7, 0x0): PreF PPR X2APIC GT IA GA HE
AMD-Vi: Interrupt remapping enabled
AMD-Vi: X2APIC enabled
vfio_pci: add [10de:2704[ffffffff:ffffffff]] class 0x000000/00000000
vfio_pci: add [10de:22bb[ffffffff:ffffffff]] class 0x000000/00000000
```
`/sys/kernel/iommu_groups/11/type` = `DMA` in run 1, `identity` in run 2. Both GPU functions `Kernel driver in use: vfio-pci`. In L1 the card shows `ROM` readable (520319 bytes through sysfs) and BAR1 16 GiB.

### Control: the card driven by the L1 kernel itself

| L1 mode | `modprobe nvidia` on 01:00.0 | HDA (01:00.1, `snd_hda_intel`) | host dmesg |
| --- | --- | --- | --- |
| translated (default) | `RmInitAdapter failed! (0x25:0x65:1601)`, `nvidia-smi: No devices were found` | `azx_get_response timeout`, `Codec #0 probe error` | `vfio-pci 0000:02:00.1: AMD-Vi: Event logged [IO_PAGE_FAULT domain=0x0004 address=0xffff6004 flags=0x0000]`, then 10 faults `vfio-pci 0000:02:00.0 ... address=0xffbc0000 ... 0xffbc0900` |
| `iommu=pt` | `nvidia-smi`: `NVIDIA GeForce RTX 4080 ... 16376MiB`, OpenCL test `RESULT: PASS` | codec `Nvidia GPU a4 HDMI/DP` found, card `HDA NVidia` registered | no events |

The host faults happen in *host* domain 0x0004 (the L0 vfio container of VM 9200) at addresses that exist only in L1's own IO page table, so L0 never received L1's mappings.

## L2 evidence (L1 launches Debian QEMU, KVM, OVMF, GPU via vfio-pci)

L2 command line (L1, from `/proc/<pid>/cmdline`, paths shortened):
```
qemu-system-x86_64 -name l2-gpu -machine q35,accel=kvm -cpu host -smp 4 -m 3072
 -drive if=pflash,format=raw,readonly=on,file=OVMF_CODE.fd -drive if=pflash,format=raw,file=OVMF_VARS.fd
 -drive file=l2.qcow2,if=virtio,format=qcow2 -drive file=seed.iso,if=virtio,format=raw,media=cdrom,readonly=on
 -netdev user,id=n0,hostfwd=tcp:127.0.0.1:2222-:22 -device virtio-net-pci,netdev=n0
 -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536 -vga none -display none -serial file:l2-serial.log
 -device pcie-root-port,id=rpg,chassis=11,slot=1
 -device vfio-pci,host=0000:01:00.0,bus=rpg,addr=0x0.0x0,multifunction=on
 -device vfio-pci,host=0000:01:00.1,bus=rpg,addr=0x0.0x1
```
L2 guest (identical in both L1 modes):
```
pci 0000:01:00.0: [10de:2704] type 00 class 0x030000 PCIe Legacy Endpoint
pci 0000:01:00.0: BAR 1 [mem 0x1000000000-0x13ffffffff 64bit pref]      (16 GiB, mapped fine)
nvidia 0000:01:00.0: ... NVRM: loading NVIDIA UNIX x86_64 Kernel Module 550.163.01
snd_hda_intel 0000:01:00.1: azx_get_response timeout, switching to polling mode: last cmd=0x000f0000
snd_hda_intel 0000:01:00.1: Codec #0 probe error; disabling it...
NVRM: GPU 0000:01:00.0: RmInitAdapter failed! (0x25:0x65:1601)
NVRM: GPU 0000:01:00.0: rm_init_adapter failed, device minor number 0
```
`lspci` in L2 shows both functions and `Kernel driver in use: nvidia`; `/proc/driver/nvidia/gpus/*/information` lists `Model: NVIDIA GeForce RTX 4080` but `Video BIOS: ??.??.??.??.??`; `nvidia-smi` -> `No devices were found`. L1 dmesg: no AMD-Vi events, no vfio errors, only `pcieport 0000:00:1c.0: Data Link Layer Link Active not set in 100 msec` after each L2 stop (virtual root port, harmless). L2's QEMU vfio trace showed all 64 RAM regions added, BAR mmaps for the 16 GiB BAR1, INTx then MSI enable and one `vfio_pci_reset_flr`, no vfio errors.

Notes for reproducing: a stale `OVMF_VARS.fd` from a GPU-less boot made the GPU boot fall into PXE (disk entries no longer matched); a fresh VARS copy per run fixed it. The L2 guest needs `PciMmio64Mb` raised only as a precaution (not shown to be required).

## Host evidence

Baseline captured read-only before any change (`qm list`, configs, `lspci -nnk`, IOMMU groups, dmesg, drivers): GPU group 13 clean (02:00.0 + 02:00.1 only), both on `vfio-pci`, `Kernel driver in use: vfio-pci`. Host RAM 49 GB available (>8 GB required). During and after the experiment, host dmesg contains only `vfio-pci ... resetting` / `reset done` pairs, the 11 `IO_PAGE_FAULT` lines above (all from the translated-domain control test), and `kvm: ignored rdmsr/wrmsr` noise from L1; **no** AER, Xid, oops, `BUG:` or "fell off the bus". All `qm` commands returned normally; L1 stopped cleanly with `qm shutdown 9200 --timeout 120` and the card is back on `vfio-pci`.

## Recommended next steps (not done)

1. Re-run this exact test with `pve-qemu-kvm 11.0.3-4` or newer for the L1 VM (needs a package change or a side QEMU on the host: owner approval). Expected checkpoints: no host `IO_PAGE_FAULT` with a translated L1 domain, then L2 GPU init.
2. If still failing, enable tracing in L0's QEMU for VM 9200 (`-trace 'amdvi_*' -trace 'vfio_*' -D file` in `args:`) to see whether `amdvi_sync_shadow_page_table_range` ever emits MAP events to the VFIO container, and compare with the Intel path (`viommu=intel`, `caching-mode=on`, which `qm` supports natively).
3. The fallback from [feasibility.md](feasibility.md) still stands: a GPU-holding guest on a reboot-selected kernel (option D), or per-VM kvm for non-GPU guests only. GPU in L1 itself (identity domain, `iommu=pt`) is fine: it is only the L1 -> L2 hand-off that this phase could not make work.

## State left behind

VM 9200 stopped (not deleted), `hostpci0` still configured, snapshot `pre-gpu`. L1 grub has `iommu=pt` (`/etc/default/grub.d/99-iommu-pt.cfg`), nvidia DKMS installed in L1, L2 image and scripts in `/root/l2` in L1. Host additions: VM 9200 volumes on `fast_storage`, the Debian cloud image in `iso_images` import storage, a throwaway SSH key dir for reaching L1. No host package, kernel, GRUB or modprobe changes.
