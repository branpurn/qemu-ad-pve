# vIOMMU nested spike: can an L1 Linux guest get a working virtual IOMMU (AMD-Vi with DMA remapping) so a device can be VFIO-passed to an L2?

Date: 2026-10-02. Author: Grok Bot for Brandon. Phase: no GPU. Everything below was **run** on the nested test node `pvetest` (VM 9000) and a new L1 VM inside it; nothing was run on, or changed on, the bare-metal host. No credentials appear here.

## Verdict: WORKS WITH CAVEATS

On this exact stack (pve-qemu-kvm 11.0.3-4, qemu-server 9.1.15, AMD CPU) an L1 Linux guest gets a working **AMD-Vi with interrupt remapping + DMA remapping**, the test device lands in its own IOMMU group, binds to `vfio-pci`, and an L2 guest (KVM) reads/writes it end to end through the vIOMMU, with and without `iommu=pt` in L1, with zero IOMMU faults.

Caveats (the reason it is not a plain "works"):

1. **`qm` cannot express AMD vIOMMU.** `viommu=` accepts only `intel` or `virtio`. AMD needs raw `args:` (below). The stock `viommu=intel` also works on an AMD CPU (Linux L1 loads `intel_iommu`/DMAR and passes the same test), so there is a fully stock-`qm` fallback.
2. **`dma-remap=on` is mandatory.** Without it the L1 still shows AMD-Vi, groups and a bindable vfio device, but device DMA through vfio does not work (control test, step 3c).
3. **Not proven with a real device.** The test device was an *emulated* NVMe. A real VFIO device (the GPU) behind the vIOMMU additionally exercises QEMU's VFIO<->vIOMMU notifier path (shadowing L1's IO page tables into the host IOMMU). Source review of QEMU v11.0.0 `hw/i386/amd_iommu.c` shows MAP/UNMAP notifier support exists and is gated on `dma-remap=on`, but this phase could not exercise it (VM 9000 has no IOMMU, so there is nothing to VFIO-pass from it).
4. **One extra nesting level versus the real architecture** (below), so performance is not representative, and the real GPU path is still open.
5. `amd-iommu` (no `pci-id`) is marked `unmigratable` in QEMU, and `kernel-irqchip=split` is required (see below): no live migration / RAM snapshot of the L1, and a userspace IOAPIC.

## Nesting levels: what this spike adds versus the real architecture

| | Real architecture | This spike |
| --- | --- | --- |
| Silicon (AMD Ryzen 9 7950X) | bare-metal PVE ("L0") | bare-metal PVE (outer host `proxmox`), **untouched** |
| Level 1 | L1 VM running KVM + QEMU | VM 9000 `pvetest` = plays "the PVE host" |
| Level 2 | L2 Windows guest | new VM 9150 `viommu-l1` = plays "L1" (4 vCPU, 4 GB, runs KVM + QEMU) |
| Level 3 | none | tiny L2 guest booted in 9150 |

So the spike's L2 is the **third** virtualization level over the silicon. Implications:

- It is a **stricter** functional test of nested SVM (KVM on KVM on KVM; it worked, including `-accel kvm` in the innermost guest), but a pessimistic one for speed: absolute timings mean nothing and were not measured.
- The vIOMMU under test is emulated by VM 9000's QEMU (the "host QEMU"), exactly as in the real architecture where the bare-metal PVE's QEMU would emulate it for L1. The code path (L1 kernel `amd_iommu` driver <-> QEMU `amd-iommu`) is the same.
- What the spike **cannot** represent: a real PCI device being assigned to L1 (real host IOMMU, ACS/groups on the host, GPU reset, huge BARs), and bare-metal AVIC/x2AVIC behaviour.

## Versions (all read from the running systems)

| Component | Version |
| --- | --- |
| Outer host (bare metal) | not touched; inferred only: AMD Ryzen 9 7950X (family 25 model 97, Zen 4) from VM 9000's `lscpu` (cpu=host) |
| VM 9000 `pvetest` | PVE `pve-manager 9.2.2`, `proxmox-ve 9.2.0`, kernel `7.0.2-6-pve`, `qemu-server 9.1.15`, `libpve-common-perl 9.1.12` |
| QEMU in VM 9000 | **`pve-qemu-kvm 11.0.3-4`** (`QEMU emulator version 11.0.3 (pve-qemu-kvm_11.0.3-4)`). The node notes say 11.0.0-3; apt history shows it was upgraded to 11.0.3-4 on 2026-10-01 before this spike. This spike changed no packages |
| Wrapper | `/usr/bin/kvm` is the qemu-ad-pve wrapper; VM 9150 is not in `/etc/qemu-ad/vms`, so it runs the vendor QEMU (`/usr/bin/kvm.pve`, symlink to `qemu-system-x86_64`, identical binary) |
| L1 guest | Debian 13 (trixie) generic cloud image (`debian-13-generic-amd64.qcow2`, sha512 verified), kernel `6.12.111+deb13-amd64` |
| L2 launcher inside L1 | Debian `qemu-system-x86` `10.0.13 (Debian 1:10.0.13+ds-0+deb13u1)`, SeaBIOS 1.16.3, L2 kernel = L1's own kernel with a tiny busybox initramfs |
| `kvm_amd` in VM 9000 | `nested=1`, `avic=N`, `npt=Y`, `vgif=1`, `vnmi=Y`, `lbrv=1`, `tsc_scaling=1`, `sev*=N`; kernel 7.0.2-6 has **no `x2avic` parameter** (AVIC is a single `avic` param plus `force_avic`, `enable_ipiv`) |
| `kvm_amd` in L1 | `nested=1`, `avic=N` |
| Host CPU flags seen in VM 9000 | `svm npt vgif vnmi nrip_save lbrv tsc_scale flushbyasid pausefilter x2apic`; no `avic`/`x2avic` flag visible (not exposed to guests) |

Inferring the bare-metal host read-only: from VM 9000 one can see the CPU model, that nested SVM is exposed (`svm`, `/dev/kvm`), and the KVM features the host passes through. One **cannot** see the host's `kvm_amd` params, its IOMMU state, groups or kernel cmdline from inside the guest (VM 9000's own dmesg only shows `iommu: Default domain type: Translated`, no AMD-Vi, so it has no vIOMMU). Nothing was changed on the host.

## Task 1: what QEMU / qm / the kernel support

### QEMU 11.0.3 (pve build)

```
$ qemu-system-x86_64 -device help | grep -i iommu
amd-iommu            "AMD IOMMU (AMD-Vi) DMA Remapping device"   (also AMDVI-PCI)
intel-iommu          "Intel IOMMU (VT-d) DMA Remapping device"
virtio-iommu-pci / virtio-iommu-device
iommu-testdev

$ -device amd-iommu,help
  device-iotlb=<bool>    (default: off)
  dma-remap=<bool>       (default: off)      <-- required for DMA translation
  dma-translation=<bool> (default: on)
  intremap=<OnOffAuto>   (default: auto)
  pci-id=<str>
  xtsup=<bool>           (default: off)      <-- x2APIC (xtsup) support
$ -device intel-iommu,help
  aw-bits (48) caching-mode device-iotlb dma-translation eim intremap fs1gp snoop-control stale-tm svm version x-flts x-pasid-mode x-scalable-mode
```

- `amd-iommu` is a sysbus device; PVE's `q35` machine is required (needs ACPI IVRS and PCIe topology). It has no `aw-bits` option (that is intel/virtio only; PVE's `aw-bits` machine key is not applicable to AMD).
- `dma-remap=on` (new in this QEMU) turns on actual DMA translation and VFIO MAP/UNMAP notifiers; per v11.0.0 source, `notify_flag_changed` rejects a MAP notifier with `requires dma-remap=1` otherwise.
- `kernel-irqchip=split` was used (PVE does the same for `viommu=intel`). `xtsup=on` with split irqchip also calls `kvm_enable_x2apic()`. Guests with more than 255 vCPUs need `xtsup=on`.
- `amd-iommu` without `pci-id` is `.unmigratable = 1`.

### qm / qemu-server 9.1.15

`/usr/share/perl5/PVE/QemuServer/Machine.pm` defines `viommu => enum ['intel','virtio']` and `aw-bits`. `QemuServer.pm` (line ~3736) emits `-device intel-iommu,intremap=on,caching-mode=on[,aw-bits=N]` (and `kernel-irqchip=split` in `-machine`) for `intel`, or `-device virtio-iommu-pci` for `virtio`. **There is no `amd` value.** So the AMD vIOMMU must go in `args:`. Verified: `args: -machine kernel-irqchip=split ...` merges with PVE's own `-machine` option (a second `-machine` is accepted by QEMU).

### Kernel/cmdline needed in L1

None required: stock Debian 6.12 with default cmdline picked up AMD-Vi from the ACPI IVRS table. `iommu=pt` is optional (tested both ways). `amd_iommu=on` is not needed on AMD (it is on by default when IVRS is present). `amd_iommu=force_isolation` was not tested. L1 dmesg also prints `AMD-Vi: Using strict mode due to virtualization`.

## Task 2: L1 VM inside VM 9000

VM 9150 `viommu-l1` (VM 9100 `w10-gpu`, 9001-9003 pre-existed and were not touched). Final config:

```
agent: 0
args: -machine kernel-irqchip=split -device amd-iommu,intremap=on,xtsup=on,dma-remap=on -device pcie-root-port,id=rp1,chassis=21,slot=1,bus=pcie.0 -drive file=/var/lib/vz/images/9150/nvme-test.raw,format=raw,if=none,id=nvmetest -device nvme,drive=nvmetest,serial=nvmetest0,bus=rp1
balloon: 0
bios: seabios
boot: order=scsi0
cores: 4
cpu: host
ide2: local:9150/vm-9150-cloudinit.qcow2,media=cdrom
machine: q35
memory: 4096
net0: virtio=...,bridge=vmbr150
scsi0: local:9150/vm-9150-disk-0.qcow2,discard=on,size=10G
scsihw: virtio-scsi-single
serial0: socket
sockets: 1
vga: serial0
```
(cloud-init: user `debian`, key-only login with a throwaway key kept inside VM 9000, static `10.99.0.2/24`.) Network: a runtime-only private bridge `vmbr150` (10.99.0.1/24) with a MASQUERADE rule inside VM 9000 (`/root/viommu-spike/net-up.sh`), so the L1 never touches the home LAN.

Resulting QEMU command line (from `qm showcmd`, abridged to the relevant parts):

```
/usr/bin/kvm -id 9150 -name viommu-l1 ... -smp 4,sockets=1,cores=4,maxcpus=4 -nographic -cpu host,+kvm_pv_eoi,+kvm_pv_unhalt -m 4096
  -readconfig /usr/share/qemu-server/pve-q35-4.0.cfg ...
  -machine hpet=off,smm=off,type=q35+pve0
  -machine kernel-irqchip=split
  -device amd-iommu,intremap=on,xtsup=on,dma-remap=on
  -device pcie-root-port,id=rp1,chassis=21,slot=1,bus=pcie.0
  -drive file=/var/lib/vz/images/9150/nvme-test.raw,format=raw,if=none,id=nvmetest
  -device nvme,drive=nvmetest,serial=nvmetest0,bus=rp1
```

L1 evidence (kernel cmdline: `BOOT_IMAGE=/boot/vmlinuz-6.12.111+deb13-amd64 root=PARTUUID=... ro console=tty0 console=ttyS0,115200 earlyprintk=ttyS0,115200 consoleblank=0`, i.e. no `iommu=` option):

```
AMD-Vi: Using global IVHD EFR:0x29d7, EFR2:0x0
x2apic enabled / APIC: Switched APIC routing to: cluster x2apic
iommu: Default domain type: Translated
AMD-Vi: Using strict mode due to virtualization
pci 0000:01:00.0: Adding to iommu group 11          <- the NVMe on rp1, alone in its group
AMD-Vi: Extended features (0x29d7, 0x0): PreF PPR X2APIC GT IA GA HE
AMD-Vi: Interrupt remapping enabled
AMD-Vi: X2APIC enabled
/sys/class/iommu/ivhd0 present; 12 groups; group 11 type DMA; 01:00.0 = "Red Hat QEMU NVM Express Controller [1b36:0010]"
```

Bind to vfio-pci (`driver_override` + `drivers_probe`): `Kernel driver in use: vfio-pci`, `/dev/vfio/11` appears. **PASS.**

## Task 3: L2 inside L1 with the device passed via vfio-pci

L1 had `/dev/kvm` (so `-accel kvm`, not TCG; kvm_amd `nested=1` in both VM 9000 and L1). L2 launch (run inside L1, device `0000:01:00.0` bound to vfio-pci):

```
qemu-system-x86_64 -M q35 -accel kvm -cpu host -smp 2 -m 512 -nographic -no-reboot \
  -kernel /root/l2/vmlinuz -initrd /root/l2/l2-initrd.gz -append "console=ttyS0 panic=-1 loglevel=4" \
  -device vfio-pci,host=0000:01:00.0
```
The initramfs (busybox + `nvme`, `nvme-core`, `nvme-auth` modules) writes 64 MiB of random data to `/dev/nvme0n1` with `oflag=direct`, reads it back with `iflag=direct` and compares md5 (the L2 guest runs `dd`/`md5sum` only; no fio).

| Config | Result |
| --- | --- |
| L1 default (no `iommu=pt`, group default domain `DMA`) | **PASS x5** (md5 written == read), 0 IO_PAGE_FAULT / `AMD-Vi: Event` lines in L1 dmesg |
| L1 with `iommu=pt` (`Default domain type: Passthrough (set via kernel command line)`) | **PASS x3 + 10/10 loop**, 0 faults |
| L2 with TCG (`-accel tcg -cpu max`), pt | **PASS** (~10 s) |
| L1 rebooted once, no pt (restart cycle / "forcedac" worry from the DMA-remap series) | **PASS x5**, 0 faults |
| Control 3c: `amd-iommu,intremap=on,xtsup=on` **without** `dma-remap=on` | L1 still shows AMD-Vi, 12 groups, binds vfio, L2 starts, but L2 `nvme: I/O tag 8 QID 0 timeout, disable controller` / `Identify Controller failed`: **FAIL** (DMA does not work) |
| Stock `qm set 9150 --machine q35,viommu=intel` (L0 QEMU `-device intel-iommu,intremap=on,caching-mode=on`, `kernel-irqchip=split`) | L1 dmesg `DMAR: ... DMAR-IR: Enabled IRQ remapping in x2apic mode`, 12 groups; L2 NVMe test **PASS x3**, 0 faults |

Proof that DMA really went through the vIOMMU (not a bypass): with `-D file -trace amdvi_*` on the L0 QEMU, 987 `amdvi_cache_update ... devid: 01:00.0` translation events were logged for the NVMe (IOVA -> host-physical, e.g. `domid 0xd devid: 01:00.0 gpa 0x1ffdd000 hpa 0x13b400000`), 12,349 `amdvi_ir_remap_msi` events (interrupt remapping active), and 0 `amdvi_page_fault`/`amdvi_err`. The `dma-remap` control above shows the converse. The trace args were removed again afterwards.

## Blockers / open items

- **None for the vIOMMU itself** at this level. Nothing required a change on the bare-metal host or to VM 9000's config (nested virtualization was already on).
- Not proven: real VFIO device in L0 -> L1 behind `amd-iommu,dma-remap=on` (needs the real host IOMMU and a spare device; the next phase). Things to check there: that QEMU's VFIO container accepts the MAP notifier on the pve build (`... requires dma-remap=1` is the failure message if not), large-BAR/64-bit-window handling for the 4080, AVIC left off (`avic=N`), IOMMU group of the card on the host, and reset behaviour.
- PVE side: `qm` has no `viommu=amd`; either keep `args:` (works but the 9150-style args are opaque to the GUI and `kernel-irqchip=split` must be repeated) or send an upstream patch adding `amd` to `PVE::QemuServer::Machine`. Also `args:` + the qemu-ad-pve wrapper: unaffected here (9150 not listed), untested for listed VMs.
- Feasibility doc 5.3 item "unconfirmed whether PVE's pve-qemu-kvm 11.0.x supports AMD vIOMMU DMA remap": **confirmed for 11.0.3-4**; still unconfirmed for 11.0.0-3 (not tested).

## State left behind (inside VM 9000 only)

- VM 9150 `viommu-l1` **stopped, not deleted** (config above; disk `/var/lib/vz/images/9150/` ~1.6 GB incl. 1 GiB sparse `nvme-test.raw`). L1 grub has no `iommu=pt` (a drop-in `/etc/default/grub.d/99-spike.cfg` with `GRUB_CMDLINE_LINUX="$GRUB_CMDLINE_LINUX iommu=pt"` re-enables it). L2 files are in L1 under `/root/l2/` (`bind.sh`, `run-l2.sh kvm|tcg`, initrd).
- `/root/viommu-spike/` in VM 9000 (~4 MB): `net-up.sh`, `restart-l1.sh`, throwaway L1 ssh key, the trace log. The 435 MB base image download was deleted.
- Runtime-only: bridge `vmbr150` (10.99.0.1/24) and an iptables MASQUERADE rule + `ip_forward=1`. Re-run `/root/viommu-spike/net-up.sh` before starting 9150 after a reboot of VM 9000.
- VM 9000 packages/config/snapshots unchanged; VM 9100 (running, pre-existing) untouched.

## Reproduce

```
/root/viommu-spike/net-up.sh && qm start 9150            # wait ~10 s, then:
ssh -i /root/viommu-spike/l1key debian@10.99.0.2         # (sudo inside)
/root/l2/bind.sh && /root/l2/run-l2.sh kvm               # expect: L2-RESULT: PASS
```
