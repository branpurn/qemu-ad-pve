# GPU phase: Intel vIOMMU (`intel-iommu`, caching-mode) in L1 makes the RTX 4080 host -> L1 -> L2 hand-off WORK (with caveats)

Date: 2026-10-02 (test window about 16:00-16:45 EDT). Author: Grok Bot for Brandon. Follows [gpu-phase-qemu-11.0.3.md](gpu-phase-qemu-11.0.3.md) (PR #3: AMD vIOMMU blocked, no VFIO notifier ever registered) and [viommu-nested-spike.md](viommu-nested-spike.md) (emulated NVMe passed behind `viommu=intel` on this AMD host). Everything below was **run**; what was not run is listed at the end. No credentials or private addresses appear here.

## Verdict: works, with caveats

With an `intel-iommu` (`intremap=on,caching-mode=on`, `kernel-irqchip=split`) instead of `amd-iommu` in the L1 VM, on the same AMD host:

* QEMU **does** register the VFIO IOMMU notifier (`vfio_listener_region_add_iommu` fires) and L1's IO page-table updates reach the host vfio container (`vfio_iommu_map_notify`: ~45k-57k MAP/UNMAP events per run). The hypothesis from the AMD trace is confirmed.
* L1 drives the 4080 with the NVIDIA driver while its IOMMU group is a **translated (`DMA`) domain**: `nvidia-smi` OK, OpenCL 768 MiB H2D+kernel+D2H PASS, HDA codec found. **0 new host `AMD-Vi IO_PAGE_FAULT`** (53 before, 53 after; the last one dates from the earlier 14:54 EDT AMD run).
* L2 (KVM, GPU handed on with vfio-pci inside L1) also works: driver `nvidia` binds, `nvidia-smi` OK, OpenCL PASS, HDA codec `Nvidia GPU a4 HDMI/DP` found. This is the step that failed with `RmInitAdapter failed! (0x25:0x65:1601)` under `amd-iommu` on QEMU 11.0.0 and 11.0.3.
* Same result on stock `pve-qemu-kvm 11.0.0-4` and on the side-loaded `11.0.3-4`.

Caveats (why it is not a plain "works"):

1. **`qm set 9200 --machine q35,viommu=intel` alone is not enough for this card.** With qm's native topology (both GPU functions directly on the PCIe root port) QEMU exits at start: `vfio 0000:02:00.1: group 13 used in multiple address spaces`. The two functions share one host IOMMU group, and `intel-iommu` gives every PCI function its own address space, which the legacy VFIO container refuses. The workaround used here puts **both functions behind a `pcie-pci-bridge`** (devices behind a conventional-PCI bridge share the bridge's requester-ID alias, hence one address space). qm cannot express that (`hostpci` has no such option), so the successful runs used a **raw QEMU command line** generated from `qm showcmd 9200` and a `sed` edit, not `qm start`. `qm shutdown`, `qm list` and `qm status` still worked on that VM.
2. In L1 the GPU therefore sits on a conventional PCI bus (`02:01.0`/`02:01.1` behind a PCIe-to-PCI bridge, not a PCIe root port). The NVIDIA driver and HDA driver work, but L1 prints `snd_hda_intel ...: Disabling MSI` for the audio function, and PCIe-only features (link state, ASPM, etc.) are not visible. Passing only function 0 (no audio) on a root port was not tested.
3. **`iommu=pt` has no effect inside L1.** The QEMU intel-iommu ecap (`f00f1a`) does not advertise pass-through, so Linux puts the GPU group in a translated `DMA` domain whether or not `iommu=pt` is on the command line (`iommu: Default domain type: Passthrough (set via kernel command line)` yet group type `DMA`). Both required L1 modes were run and are identical in outcome, but there is no identity-mapped mode on this vIOMMU. The L1 kernel needed no `intel_iommu=on`: Debian's default enables DMAR (`DMAR: Intel(R) Virtualization Technology for Directed I/O`, `iommu: Default domain type: Translated`).
4. Performance was **not measured**. Every DMA mapping L1 creates is shadowed by QEMU into the host IOMMU (MAP/UNMAP counts below), and `vtd_inv_desc_iotlb_pages` runs in the thousands. Expect a cost for map-heavy workloads; the 768 MiB OpenCL test took 0.41-0.42 s in L1 and 0.53-0.54 s in L2, which is not a benchmark.
5. Intel vIOMMU on an AMD CPU is "emulated Intel": L1 sees `AMD Ryzen 9 7950X` with DMAR/IR tables from QEMU (`DMAR-IR: Enabled IRQ remapping in x2apic mode`). It worked here but is an unusual combination.
6. Test-harness trap (not a vIOMMU result): inside L1, with the GPU present, OVMF in L2 does not auto-create the disk boot entry and drops to the EFI shell even with a fresh `OVMF_VARS_4M.fd`. Fix used: create a VARS template once by booting L2 without the GPU but with a dummy `pcie-root-port` in the same slot layout, then copy that template per run.

## Results

| Test | Stock QEMU 11.0.0-4, L1 `iommu=pt` on cmdline | Stock 11.0.0-4, L1 **without** `iommu=pt` | Side-loaded 11.0.3-4, L1 without `iommu=pt` |
| --- | --- | --- | --- |
| L1 group type of the GPU | `DMA` | `DMA` | `DMA` |
| (a) L1 + NVIDIA 550.163.01: `nvidia-smi` | OK (RTX 4080, 16376 MiB) | OK | OK |
| (a) L1 OpenCL 768 MiB | PASS (0.42 s) | PASS (0.41 s) | PASS (0.42 s) |
| (a) L1 HDA codec | `Nvidia GPU a4 HDMI/DP` | same | same |
| (b) L2 under KVM, GPU via vfio-pci: `nvidia-smi` | OK | OK | OK |
| (b) L2 OpenCL 768 MiB | PASS (0.53 s) | PASS (0.54 s) | PASS (0.54 s) |
| (b) L2 audio codec | `Nvidia GPU a4 HDMI/DP` | same | same |
| New host `IO_PAGE_FAULT` | 0 | 0 | 0 |
| Other host dmesg (AER, Xid, oops, hung task) | none | none | none |

The "pt" column was the first run of the day; its L2 test needed the OVMF harness fix (caveat 6) after two EFI-shell attempts, which are not counted as results. Control: qm's native topology (no bridge) failed at QEMU start as described in caveat 1 (no VM ran).

### (c) Trace: the VFIO notifier registers

QEMU `-trace events=<file> -D <file>` with: `vfio_listener_region_add_iommu`, `vfio_listener_region_del_iommu`, `vfio_iommu_map_notify`, `vfio_listener_region_add_ram`, `vfio_listener_region_skip`, `vtd_replay_ce_valid`, `vtd_switch_address_space`, `vtd_as_unmap_whole`, `vtd_dmar_enable`, `vtd_ir_enable`, `vtd_inv_desc_iotlb_{pages,domain,global}`, `vtd_page_walk_skip_read`, `vtd_dmar_fault`. Counts over each whole L0 QEMU lifetime (L1 boot, L1 direct GPU test, one or more L2 runs):

| Event | Run 1 (11.0.0, pt) | Run 2 (11.0.0, no pt) | Run 3 (11.0.3, no pt) | AMD vIOMMU, PR #3 |
| --- | --- | --- | --- | --- |
| **`vfio_listener_region_add_iommu`** | **2** | **2** | **2** | 0 |
| **`vfio_iommu_map_notify`** (MAP / UNMAP) | 56873 (44267 / 12606) | 44989 (35777 / 9212) | 44989 (35777 / 9212) | 0 |
| `vtd_dmar_enable` / `vtd_ir_enable` | 1 / 1 | 1 / 1 | 1 / 1 | n/a |
| `vtd_replay_ce_valid` | 2 | 2 | 2 | n/a |
| `vtd_inv_desc_iotlb_pages` | 7668 | 3383 | 3388 | n/a |
| `vtd_dmar_fault` | 0 | 0 | 0 | n/a |
| `vfio_listener_region_skip` | 1285 | 1269 | 1269 | ~1210 |

(Run 1 contains three L2 launches, two of them the harness failures; runs 2 and 3 contain one L2 run each. The identical MAP/UNMAP totals in runs 2 and 3 were not investigated further; the guest boot sequence is the same, and the `vtd_inv_desc_iotlb_pages` totals do differ slightly.)

Excerpt (run 2):
```
vtd_dmar_enable enable 1
vfio_listener_region_add_iommu region_add [iommu] vtd-00.0-dmar 0x0 - 0xfedfffff
vtd_replay_ce_valid legacy mode: replay valid context device 02:00.00 domain 0xd hi 0xd02 lo ...
vfio_listener_region_add_iommu region_add [iommu] vtd-00.0-dmar 0xfef00000 - 0xffffffffffffffff
vfio_iommu_map_notify iommu MAP @ 0xfffff000 - 0xffffffff
vfio_iommu_map_notify iommu MAP @ 0xffffe000 - 0xffffefff
...
vfio_iommu_map_notify iommu UNMAP @ 0xfefc0000 - 0xfefc0fff
```
The address space is split around the 0xfee00000 MSI window, as the VFIO listener expects. The `vtd-00.0-dmar` name is the alias address space of the PCIe-to-PCI bridge, shared by both GPU functions: that is why one registration (two ranges) covers both.

Failed control (qm native topology, run once, QEMU log): `kvm: -device vfio-pci,host=0000:02:00.1,...: vfio 0000:02:00.1: group 13 used in multiple address spaces`.

## Versions

| Component | Version |
| --- | --- |
| Host (L0) | AMD Ryzen 9 7950X, PVE 9.2.3, kernel `7.0.12-1-pve`, cmdline `iommu=pt amd_iommu=on ...` |
| L0 QEMU | stock `QEMU 11.0.0 (pve-qemu-kvm_11.0.0-4)` (installed); `QEMU 11.0.3 (pve-qemu-kvm_11.0.3-4)` side-loaded under `/opt/qemu-11.0.3` (not installed) |
| GPU | RTX 4080 (AD103, 10de:2704) + HDA 10de:22bb, one host IOMMU group (13) with only these two |
| L1 | Debian 13 cloud image, kernel `6.12.111+deb13-amd64`, `nvidia-kernel-dkms 550.163.01-2`, `qemu-system-x86 1:10.0.13+ds-0+deb13u1`, `ovmf 2025.02-8+deb13u1` |
| L2 | Debian 13 (qcow2), same kernel and driver, 4 vCPU, 3 GiB, OVMF |

## Command lines

VM 9200 config used for the runs (`qm config` diff versus the AMD config; everything else, including `hostpci0: 0000:02:00,pcie=1`, unchanged):
```
machine: q35,viommu=intel          # was: q35
args: -trace events=<events file> -D <log file>     # was: -machine kernel-irqchip=split -device amd-iommu,intremap=on,xtsup=on,dma-remap=on
```
`qm showcmd 9200` then yields `-device intel-iommu,intremap=on,caching-mode=on` and `-machine ...,kernel-irqchip=split`. The VM was **started from a raw launch script** built from that output (`qm start` fails, caveat 1). The only edits to the `qm showcmd` output:
```
-device 'pcie-pci-bridge,id=gpubr,bus=ich9-pcie-port-1,addr=0x0'
-device 'vfio-pci,host=0000:02:00.0,id=hostpci0.0,bus=gpubr,addr=0x1.0,multifunction=on'
-device 'vfio-pci,host=0000:02:00.1,id=hostpci0.1,bus=gpubr,addr=0x1.1'
```
(replacing the two `bus=ich9-pcie-port-1,addr=0x0.x` vfio-pci lines); the launcher is `exec -a /usr/bin/kvm /usr/bin/kvm.pve <args>` for 11.0.0 and `exec -a /usr/bin/kvm /opt/qemu-11.0.3/usr/bin/qemu-system-x86_64 -L /opt/qemu-11.0.3/usr/share/kvm <args>` for 11.0.3.

Inside L1 the GPU is `02:01.0`/`02:01.1`; the L2 launch is the earlier `run-l2.sh gpu` with `GPUBDF=02:01` (so `host=0000:02:01.0/.1`), L2 sees it at `01:00.x` on its own PCIe root port.

L1 dmesg (both modes):
```
DMAR: dmar0: reg_base_addr fed90000 ver 1:0 cap 80d2008c222f06c6 ecap f00f1a
DMAR-IR: Enabled IRQ remapping in x2apic mode
iommu: Default domain type: Translated          (no iommu=pt)
iommu: Default domain type: Passthrough (set via kernel command line)   (with iommu=pt; groups are still type DMA)
DMAR: Intel(R) Virtualization Technology for Directed I/O
pci 0000:02:01.0 / 02:01.1: Adding to iommu group 11   (with the bridge 01:00.0)
```
L1 no-`iommu=pt` mode was made by moving `/etc/default/grub.d/99-iommu-pt.cfg` aside and `update-grub`; it was moved back at the end, and L1 was always cold-booted between modes (`qm shutdown` + relaunch).

## Not run

* Passing only the VGA function on a PCIe root port (no bridge, no audio), and any qm-native way to get both functions into one address space.
* `iommufd` backend, `device-iotlb=on`, `aw-bits`, `x-scalable-mode`/PASID options.
* Any performance measurement or long-running stress; an in-guest warm reboot of L1; more than one L2 GPU run per mode after the harness fix.
* The Windows 10 guest on this path (9102 was only shut down to free the card and restored afterwards).
* The AMD `dma-remap=off` control and anything newer than QEMU 11.0.3.

## State left behind

VM 9200 stopped, its config restored byte-for-byte to the AMD args (`diff` against the pre-test backup is empty). New files only under `/root/gpu-phase-l1/intel/` on the host (launch scripts, trace events, trace logs, config backups). L1's `iommu=pt` grub drop-in restored. 9102 restarted and verified healthy (Display `OK`, `ConfigManagerErrorCode 0`, `nvidia-smi` works). No host package, kernel, GRUB, modprobe, wrapper or other VM changes.

## Next steps

1. If this path is wanted: make the topology reproducible without a hand-edited command line (qemu-server patch or `args:` that replaces the `hostpci` devices), and decide whether the conventional-PCI placement of the GPU in L1 is acceptable.
2. Measure map-heavy workloads (CUDA with pinned buffers, repeated alloc/free) to quantify the shadowing cost.
3. The AMD vIOMMU notifier gap (PR #3) is still unexplained; this result only shows that the Intel one works on the same host.
