# Roadmap: a patched KVM for one dev VM, living alongside an unchanged PVE

Date: 2026-10-03 (integrated into qemu-ad-pve 2026-10-05). Status: planning document plus the tooling in-tree (`dkms/`, `tools/`, `.github/`). Lab notes referenced as "PR #n" are the notes from [`branpurn/separate-kvm-feasibility`](https://github.com/branpurn/separate-kvm-feasibility) (merged to that repo's `main`; copies live under `docs/` here).

Scope: lab/dev use. This project does not research or implement anti-cheat evasion (see `docs/feasibility.md` 1.2).

## Intent and ground rules

One dev VM gets a bare-metal-like KVM environment (a patched `kvm`), AI workloads run inside it on the real RTX 4080, and **everything else on the PVE host stays as it is**.

1. **Host kernel and modules stay stock.** The bare-metal PVE host (9.2.x, `7.0.x-pve`) never gets a patched `kvm`/`kvm-amd`, DKMS packages, or module parameters from this project.
2. **The patched KVM lives only in the nested L1** (VM 9200 today). The dev VM is an **L2** inside it.
3. **Minimal footprint, easy removal.** Every component below has a "Host impact / Rollback" entry; removal never needs more than deleting a file, stopping a VM, or `dkms remove` inside the L1.
4. **GPU passthrough into the dev VM is a hard requirement, not a stretch goal** (acceptance criterion A1 below).

## Host impact and rollback, per component

| Component | Where it runs / lives | Host impact | Rollback |
| --- | --- | --- | --- |
| `dkms/` (patched kvm build) | **inside the L1 only**; `scripts/l1-dkms.sh` refuses on a PVE host or bare metal | **None.** Writes only to the L1's `/usr/src`, `/var/lib/dkms`, `/lib/modules/<kver>/updates/dkms` | `scripts/l1-dkms.sh uninstall`, reload stock modules or reboot the L1; or restore the L1's cold snapshot |
| `tools/gen-launch.py` and generated launch scripts | script on any machine; generated file is run on the host as the *only* way to start the L1 (qm can't express the topology) | **None for the tool.** The generated script starts one QEMU like `qm start` would, with the L1's existing disks/NICs/tap; `/etc/pve` VM config is not modified (PR #4: `diff` against backup empty) | Delete the script. `qm start 9200` still works for the L1 without the GPU/vIOMMU setup (it fails with GPU + vIOMMU, PR #4) |
| `check-new-kernel.py` + `kernel-watch` workflow | GitHub Actions | **None.** Reads the public Proxmox apt index | Delete the workflow file |
| L1 VM 9200 (nested PVE/Debian, Intel vIOMMU) | existing VM | Uses the RTX 4080 exclusively: **VM 9102 (`w10-bm2`) and VM 500 cannot run at the same time** (they were shut down for the PR #4-#6 tests and restarted afterwards). This is the one real coupling to the rest of the host | Stop 9200, start 9102/500 as before (done in the PR #4-#6 test runs) |
| Patched `qemu-ad-pve` as L0 QEMU for the L1 (optional) | existing side install under `/opt/qemu-ad` plus the `/usr/bin/kvm` wrapper; **not changed by this repo** | None added here. (Pre-existing: the wrapper redirects only VMIDs listed in `/etc/qemu-ad/vms`.) The launch script calls `/opt/qemu-ad/bin/qemu-system-x86_64` directly and leaves the wrapper alone | Don't use `--qemu-bin`; remove a VMID from `/etc/qemu-ad/vms` |
| Intel vIOMMU on an AMD host | per-VM QEMU arguments | None host-wide (host keeps `amd_iommu=on iommu=pt`) | Drop the arguments |

## Where we are (verified facts, from the notes PRs)

| Fact | Evidence |
| --- | --- |
| AMD vIOMMU (`amd-iommu,dma-remap=on`) in the L1: no VFIO notifier registered (`vfio_listener_region_add_iommu` = 0), GPU hand-off L1 -> L2 fails (`RmInitAdapter failed`) on QEMU 11.0.0 and 11.0.3 | PR #2, #3 |
| **Intel vIOMMU works:** `-machine kernel-irqchip=split` + `intel-iommu,intremap=on,caching-mode=on`; notifier registers, RTX 4080 works in L1 and in an L2 (Linux: `nvidia-smi`, OpenCL, HDA codec), 0 new host `IO_PAGE_FAULT` | PR #4 |
| qm-native topology fails (`group 13 used in multiple address spaces`); workaround: both GPU functions behind a `pcie-pci-bridge` under a root port, started from a **raw launch script** (qm can't express it) | PR #4 |
| **Windows 10 L2 + RTX 4080 works**: Code 0, `nvidia-smi` 576.88, OpenCL and CUDA (CuPy) checks pass, `dxdiag` FL 12_1; plain `-cpu host` is enough | PR #5 |
| **Patched qemu-ad-pve (QEMU 10.2.2) as L0 QEMU for the L1 works** on the same path once virtio is replaced by AHCI + e1000e (its PCI vendor-id rewrite makes OVMF/guests unable to use virtio); VFIO notifier registration intact | PR #6 |
| Caveats carried forward | L1 sees the GPU on a conventional-PCI bus (HDA "Disabling MSI"); `iommu=pt` has no effect in L1 (DMA-translated group, or identity with QEMU 10.2); performance not measured; L1 warm-reboot with GPU not tested |  PR #4-#6 |

Tooling status in this PR: `tools/gen-launch.py` reproduces the PR #4 launch-script edits automatically; `dkms/` builds the example patch into the three modules for the L1's kernel `6.12.111+deb13-amd64` (compile + link only, see `dkms/README.md`).

## Acceptance criteria (apply to every phase that changes the stack)

**A1 - GPU passthrough with AI compute is retained (hard requirement).** In the dev VM (L2), with the stack under test:
1. Both GPU functions (video + HDA) are present; the GPU shows no error (Windows `ConfigManagerErrorCode 0` / Linux driver bound, `nvidia-smi` lists the RTX 4080 with the full 16 GiB).
2. **Compute check** (one script, kept in the repo once written - TODO): CUDA/PyTorch (`torch.cuda.is_available()`, fp16/fp32 matmul with result verification), host<->device copies with **pinned and repeatedly alloc/free'd buffers** (the map-heavy case that stresses vIOMMU shadowing), and a small model forward/backward pass, all with checked results. PR #5 only ran OpenCL and CuPy one-shot checks.
3. Large BAR / 64-bit MMIO works: the full VRAM is addressable (`nvidia-smi -q` BAR1 / memory total), launch script carries `X-PciMmio64Mb >= 32768` (enforced by `gen-launch.py`).
4. 10 stop/start cycles of the L2 and 3 of the L1 without hangs, no new host `IO_PAGE_FAULT`/AER/Xid (baseline today: 53, all old).
5. Throughput recorded against the stock-KVM L1 as reference (no hard threshold yet; set one after the first measurement - open item).

**A2 - Host unchanged.** `uname -r`, `lsmod | grep kvm`, `dkms status`, `/etc/pve` VM configs, `/usr/bin/kvm` wrapper, and other VMs' state identical before and after; other VMs (110/115/200/245 etc.) unaffected.

**A3 - Reversible in minutes** using the rollback column above, drilled once per phase.

## Phases

### Phase 0 - baseline (done): Intel vIOMMU + GPU + Windows L2 on stock KVM
State per the table above. Exit met by PR #4-#6.

### Phase 1 - reproducible launch (this PR plus follow-ups)
* Done here: `gen-launch.py` with defaults for vIOMMU, both GPU functions, large 64-bit MMIO, optional `--qemu-bin`, `--no-virtio`; unit tests; CI.
* Next: (a) run the generated script for VM 9200 and compare with the hand-edited PR #4 script (diff only in intended places; **first real use of `X-PciMmio64Mb` at L0 and of `intel-iommu` as the first device**); (b) lifecycle helpers (graceful stop via QMP, pidfile handling so `qm shutdown/status` keep working as in PR #4); (c) run A1 on stock KVM to get the reference numbers.
* Exit: A1 + A2 pass using only the generated script.

### Phase 2 - patched qemu-ad-pve at L0 for the L1 (optional, userspace only)
Already works with `--no-virtio` (PR #6). Decide whether to keep AHCI/e1000e for the L1 or rebuild the QEMU variant without the PCI vendor-id hunks so virtio can be used. No kernel change. Exit: A1 on that stack.

### Phase 3 - patched KVM in the L1 only
1. Take a cold snapshot of 9200 (never with RAM while an L2 runs, `docs/feasibility.md` 5.1).
2. In the L1: `dkms/fetch-kvm-source.sh 6.12.111`, `scripts/l1-dkms.sh install`, load the example-patch modules (`/sys/module/kvm/version` = `l1-dkms-0.1`), run A1 with the **benign patch** to prove the pipeline end to end (build, sign if Secure Boot, load, L2 GPU run, unload).
3. Replace the example patch by the real patch (requirement still to be named - open item 1); re-run A1.
4. Rebuild/rebase drill when the L1's kernel updates (`AUTOINSTALL` stays off until the CI build step exists).
* Exit: A1-A3 pass with the real patch; rollback drilled.
* Not in scope here: anything that changes the host's `kvm`. L1 `kvm-amd` runs on emulated SVM (feasibility 5.1/5.5), so conclusions about real-hardware SVM/ASID behaviour do not transfer.

### Phase 4 - promotion decisions (decision gates, no work implied)
| Decision | Options | Default |
| --- | --- | --- |
| D1. Which stack becomes the day-to-day dev environment | (a) stock-KVM L1 (cheapest); (b) L1 with patched `kvm` (this project's goal); (c) also patched QEMU at L0 | (b) only if Phase 3 exits cleanly and the patch is demonstrably needed |
| D2. L1 flavour | Debian 13 (current, kernel `6.12.111+deb13`) vs a PVE-in-L1 on `proxmox-kernel-7.0.x` (matches the host's kernel line; needs `pve-kernel` source, not a mainline tag) | stay on Debian until a reason appears |
| D3. Automation | Enable `AUTOINSTALL`, add the CI build/smoke step to `kernel-watch.yml` (needs a self-hosted runner with a nested L1) | manual until the patch set stabilises |
| D4. GPU ownership | The 4080 is held by the L1 (and thus the dev VM) while it runs; 9102/500 need it back by stopping 9200 | keep manual; a mutual-exclusion guard in the launch/stop helpers is an open item |
| D5. Anything touching the **host** kernel/modules | Out of this project's scope by the ground rules above; would need Brandon's explicit decision, a maintenance window and the Phase 3 of `docs/feasibility.md` | **No** |

## Open items

1. **Name the requirement the patch must satisfy** (feasibility Q2). Until then `0001` is an example only and Phase 3 step 3 is blocked.
2. Write the A1 compute-check script (PyTorch/CUDA + pinned-buffer stress) and decide the throughput bar after a stock-KVM measurement.
3. Verify `gen-launch.py` output against real `qm showcmd` output of VM 9200 (the unit-test sample is synthetic, modelled on the PR descriptions and qemu-server's usual layout) and against `qemu-system-x86_64 -device help` of QEMU 11.0.x (flag names were checked against QEMU `master` sources/wiki, **not** run on 11.0.x).
4. Test `intel-iommu` first-device placement vs qm's order, `device-iotlb=on`/`aw-bits`, and `iommufd` (all listed "not run" in PR #4).
5. ~~GPU on a root port without the audio function, or a qm-supported way to share one address space (so `qm start` works again)~~ **Done** without a qemu-server patch: `machine: q35,viommu=intel` + `args:` (bridge + both functions) + a 9200-only PCI-reservation hookscript; see [gpu-phase-qm-native-9200.md](gpu-phase-qm-native-9200.md).
6. L1 warm reboot and GPU reset behaviour (FLR/bus reset) with the GPU attached; repeated L1 restarts.
7. Unexplained: why AMD vIOMMU registers no VFIO notifier (PR #3); candidate upstream report.
8. Secure Boot in the L1 (VM 9200 is not known to use it); MOK drill from `dkms/README.md`.
9. DKMS: build verification in a real L1 (`dkms add/build/install`), Proxmox-kernel source fetching (`pve-kernel.git`), patch rebase automation, other kernel versions (only 6.12.111 was compiled).
10. `kernel-watch.yml`: baseline file is manual; build step is a TODO; issue creation is off unless the repo variable `KERNEL_WATCH_OPEN_ISSUE=true`.
11. GPU exclusivity with VM 9102/500 is the one visible host-side coupling (D4).
12. Performance of map-heavy GPU workloads under the translated (shadowed) vIOMMU DMA path is unmeasured.
