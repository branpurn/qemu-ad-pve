# Feasibility study: a VM on a separate KVM from the Proxmox host's own

Date: 2026-10-02. Author: Grok Bot for Brandon. Status: desk study; **no commands were run on the PVE host or any VM.**

Contents

1. [Question, interpretations, assumptions, scope](#1-question-interpretations-assumptions-scope)
2. [What "KVM" is here (and what already exists)](#2-what-kvm-is-here-and-what-already-exists)
3. [Interpretation (a): custom/out-of-tree kvm module](#3-interpretation-a-customout-of-tree-kvm-module)
4. [Per-VM selection mechanisms](#4-per-vm-selection-mechanisms)
5. [Interpretation (b): nested L1 host](#5-interpretation-b-nested-l1-host-vs-bare-metal)
6. [Interpretation (c): kexec / dual-kernel](#6-interpretation-c-kexec-or-dual-kernel-boot)
7. [Interpretation (d): other stacks](#7-interpretation-d-alternative-stacks)
8. [Interpretation (e): hardware KVM switch](#8-interpretation-e-hardware-kvm-switch)
9. [Cross-cutting: Proxmox, DKMS, Secure Boot, VFIO/IOMMU, Windows guest](#9-cross-cutting-concerns)
10. [Anti-detection impact (architectural only)](#10-anti-detection-impact-architectural-only)
11. [Risks](#11-risks)
12. [Effort estimates](#12-effort-estimates)
13. [Recommendation](#13-recommendation)
14. [Phased PoC plan (nested PVE first, then VM 9102)](#14-phased-poc-plan)
15. [Open questions for Brandon](#15-open-questions-for-brandon)
16. [Sources](#16-sources)

---

## 1. Question, interpretations, assumptions, scope

### 1.1 Interpretations covered

The request is "let a VM use a SEPARATE KVM from the one the Proxmox host uses". "KVM" can mean five things; each is assessed:

| | Meaning | Verdict (short) |
| --- | --- | --- |
| (a) | A second/patched **kernel module** build (`kvm.ko` + `kvm-amd.ko`) loaded next to, or instead of, the PVE kernel's | *Replace*: feasible. *Coexist*: constructible but unsafe (section 3) |
| (b) | A **second kernel + hypervisor instance**: an L1 VM running its own kernel, KVM and QEMU, with L2 guests inside | Feasible for everything except (probably) GPU passthrough to L2 (section 5) |
| (c) | A **separate kernel** via kexec or dual boot | Dual boot: easy but host-wide and needs a reboot. kexec: same, no simultaneity. Multikernel: experimental RFC (section 6) |
| (d) | **Alternative stacks** (Cloud Hypervisor, Firecracker, Xen, ...) | Mostly still use `/dev/kvm`; no gain for this goal (section 7) |
| (e) | A **hardware KVM switch** (keyboard/video/mouse) | Unrelated to hypervisors; one paragraph (section 8) |

### 1.2 Assumptions and scope

- **A1.** Host is bare-metal PVE on an **AMD Ryzen 9 7950X** (so `kvm.ko` + `kvm-amd.ko`, not `kvm-intel`), kernel `7.0.x-pve`, IOMMU on. These come from earlier lab notes and were **not re-checked** today.
- **A2.** Other production VMs (110, 115, 200, 245) run on the same host. Anything that touches the host's kvm modules affects them.
- **A3.** VM 9102 already runs under the custom QEMU from `qemu-ad-pve` (userspace only; the kernel's KVM is stock). Its limits (virtio IDs rewritten, SATA + e1000e only, no live backup/migration) stay.
- **A4.** The goal is a *different KVM kernel component for selected VMs*. The reason for wanting it is not stated. Section 15 asks.
- **A5.** "Do not touch the host/VMs": every step in section 14 is a plan. Nothing was executed.
- **Scope limit (deliberate).** The brief lists anti-detection (CPUID/MSR/timing hiding) as a motive. This study treats that **only architecturally** (section 10: which layer owns what, and what a separate KVM would or would not change). It does **not** research or provide methods for defeating particular game anti-cheat services, and it does not give a timing-evasion roadmap. Using such a setup to evade an online game's anti-cheat is also likely to breach that game's terms of service and can get accounts banned. The `qemu-ad-pve` README itself frames the tool as a lab/dev-compatibility tool.

---

## 2. What "KVM" is here (and what already exists)

- **Kernel side:** on x86 the build produces `kvm.ko` (generic + x86 core) and a vendor module `kvm-amd.ko` (or `kvm-intel.ko`). In the v7.0 tree: `obj-$(CONFIG_KVM_X86) += kvm.o`, `obj-$(CONFIG_KVM_AMD) += kvm-amd.o` ([arch/x86/kvm/Makefile @ v7.0](https://github.com/torvalds/linux/blob/v7.0/arch/x86/kvm/Makefile)). Userspace talks to it through one character device, `/dev/kvm`.
- **Userspace side:** QEMU. `-accel kvm` uses `/dev/kvm` by default, and since QEMU commit [aef158b (Oct 2023)](https://github.com/qemu/qemu/commit/aef158b093b9d67381f88468d39ac8dd62ae9e8b) the accelerator takes **`device=path`** ("Sets the path to the KVM device node. Defaults to /dev/kvm", also `/dev/fdset/NN`) ([QEMU invocation docs](https://www.qemu.org/docs/master/system/invocation.html)). Both PVE's QEMU (11.0.x) and the side QEMU (10.2.2) are newer than that commit, so the property should exist in both (not tested).
- **Already in place:** `qemu-ad-pve` swaps the *QEMU binary* per VMID via a `/usr/bin/kvm` wrapper reading `/etc/qemu-ad/vms` ([README](https://github.com/branpurn/qemu-ad-pve#how-it-is-put-together)). That is the natural place to also inject `-accel kvm,device=/dev/kvm-xxx` for listed VMs.
- **Prior internal note:** the lab notes contain a `parallel-kvm-research.md` stub (empty, "in progress") and a README line "Parallel-KVM verdict: not feasible safely". This study backs the "coexist" part of that verdict with source-level reasons and separates out the options that *are* feasible.

---

## 3. Interpretation (a): custom/out-of-tree kvm module

### 3.1 Replace the stock module (same names)

- Build `kvm.ko` and `kvm-amd.ko` from the PVE kernel source (Proxmox publishes `pve-kernel.git`, branch for `proxmox-kernel-7.0`; the Ubuntu-derived tree is patched, so use *that* source, not mainline) plus your patches, with headers from `proxmox-headers-<ver>-pve`. The PVE wiki documents the DKMS flow for third-party modules (`dkms`, matching headers) and its Secure Boot implications ([Host Bootloader wiki](https://pve.proxmox.com/wiki/Host_Bootloader), [Secure Boot Setup](https://pve.proxmox.com/wiki/Secure_Boot_Setup)).
- Module loading order: install into `/lib/modules/<ver>/updates/` so depmod prefers it over `kernel/` (standard depmod behaviour, see depmod.d(5); not re-verified here). Then `modprobe -r kvm_amd kvm && modprobe kvm_amd`, which needs **all VMs stopped** (the module has a refcount while VMs exist).
- Both modules must be rebuilt for **every** kernel update. Proxmox ships frequently: the `pve-kernel` git log shows `7.0.14-20` and `7.0.14-21` within about a week ([git.proxmox.com](https://git.proxmox.com/?p=pve-kernel.git)). KVM internals are not a stable ABI; a patch against `7.0.x` may need rebasing at every point release. A known real-world example of the same DKMS-vs-7.0 pain: NVIDIA's 550/580 DKMS builds failed on 7.0 API changes ([Proxmox forum](https://forum.proxmox.com/threads/nvidia-dkms-driver-failure-on-proxmox-ve-9-2-4-with-kernel-7-0-x-quadro-p2000-%E2%80%94-seeking-guidance.185092/)).
- Verdict: **feasible; host-wide; affects all VMs; no per-VM choice.**

### 3.2 Coexist with the stock module (two kvm implementations at once)

I read the v7.0 source ([kvm_main.c excerpts already in the lab notes; mainline files below](https://github.com/torvalds/linux/tree/v7.0)). Findings, from cheapest to hardest to fix:

| # | Conflict | Evidence | Fix in a fork |
| --- | --- | --- | --- |
| 1 | **Module name** `kvm` / `kvm-amd` is unique in the kernel | module core refuses a second module of the same name | Rename (e.g. `kvm_ad`, `kvm_amd_ad`); trivial |
| 2 | **Exported symbols collide.** `kvm.ko` exports hundreds of symbols. A second module exporting the same names is rejected at load: `"%s: exports duplicate symbol %s (owned by %s)"` and `-ENOEXEC` ([kernel/module/main.c](https://github.com/torvalds/linux/blob/v7.0/kernel/module/main.c), `verify_exported_symbols`) | see source | Prefix/rename all exports or link kvm + kvm-amd into **one monolithic module** so nothing is exported |
| 3 | **v7.0 restricts who may import KVM's internal symbols by module name.** `EXPORT_SYMBOL_FOR_KVM_INTERNAL(sym)` expands to `EXPORT_SYMBOL_FOR_MODULES(sym, KVM_SUB_MODULES)`, i.e. only modules named `kvm-amd`/`kvm-intel` may import them ([include/linux/kvm_types.h](https://github.com/torvalds/linux/blob/v7.0/include/linux/kvm_types.h), [include/linux/export.h](https://github.com/torvalds/linux/blob/v7.0/include/linux/export.h)). A *renamed* vendor module therefore cannot resolve the symbols of a renamed core | see source | Change `KVM_SUB_MODULES` in the fork's build, or go monolithic (also fixes #2) |
| 4 | **`/dev/kvm` is a fixed misc device**: `static struct miscdevice kvm_dev = { KVM_MINOR, "kvm", &kvm_chardev_ops }` and `KVM_MINOR` is 232 ([kvm_main.c](https://github.com/torvalds/linux/blob/v7.0/virt/kvm/kvm_main.c), [miscdevice.h](https://github.com/torvalds/linux/blob/v7.0/include/linux/miscdevice.h)) | see source | Use `MISC_DYNAMIC_MINOR` (255) and a new name (`kvm-ad`); QEMU then uses `device=/dev/kvm-ad` |
| 5 | **perf guest callbacks are a single global**: `perf_register_guest_info_callbacks()` does `if (WARN_ON_ONCE(rcu_access_pointer(perf_guest_cbs))) return;` ([kernel/events/core.c](https://github.com/torvalds/linux/blob/v7.0/kernel/events/core.c)); x86 KVM calls it from `__kvm_register_perf_callbacks()` | see source | The second registrant is silently ignored (plus a WARN). Needs a patch to skip registration in the fork; host `perf` guest attribution will only work for one of them |
| 6 | **CPU hotplug state is a fixed slot**: KVM calls `cpuhp_setup_state(CPUHP_AP_KVM_ONLINE, "kvm/cpu:online", ...)` from `kvm_enable_virtualization()`; `cpuhp_store_callbacks()` returns `-EBUSY` if the slot already has a name ([kernel/cpu.c](https://github.com/torvalds/linux/blob/v7.0/kernel/cpu.c)) | see source | The fork's first VM creation fails with `-EBUSY` while the stock module holds the slot (and with `enable_virt_at_load=1`, default, already at module load). Needs a dynamic state or its own hotplug handler |
| 7 | **VFIO binds to KVM by symbol name**: `vfio_device_get_kvm_safe()` does `symbol_get(kvm_put_kvm)` / `symbol_get(kvm_get_kvm_safe)` ([drivers/vfio/vfio_main.c](https://github.com/torvalds/linux/blob/v7.0/drivers/vfio/vfio_main.c)). These are `EXPORT_SYMBOL_GPL`, not restricted | see source | `vfio.ko` will always resolve to whichever module exports those names. A fork must either keep exporting them (then vfio gets the stock copy while the `struct kvm` belongs to the fork; works only if struct layout and semantics match) or not export them (then vfio uses the stock one, which must be loaded). Needs an audit; GPU passthrough is exactly the path it affects |
| 8 | **Per-CPU hardware virtualization state is shared hardware.** `svm_enable_virtualization_cpu()` sets `EFER.SVME` and writes `MSR_VM_HSAVE_PA`; the disable path writes `MSR_VM_HSAVE_PA = 0` and clears SVME; per-CPU `svm_cpu_data` holds a *module-private* ASID pool (`asid_generation`, `next_asid`, `min_asid..max_asid`) ([svm.c, lines ~484-533, 1844-1854](https://github.com/torvalds/linux/blob/v7.0/arch/x86/kvm/svm/svm.c)) | see source | **Not fixable by renaming.** Two instances would (i) overwrite each other's host-save area pointer, (ii) turn SVM off underneath the other when one disables it (e.g. last VM exits, CPU hotplug, suspend), and (iii) hand out the **same ASIDs** to different guests on the same CPU without coordinated flushes, which is a correctness and cross-guest isolation bug. A fix means a shared arbiter for the SVM enable state and ASIDs, i.e. writing a hypervisor multiplexer. Partitioning CPUs between the two modules is conceivable but KVM enables virtualization on all online CPUs, so it would need further invasive changes |

Additional items to audit if anyone attempts it (not verified, listed so they are not forgotten): AVIC/posted-interrupt global state, IRQ bypass consumers, `kvm.enable_virt_at_load` semantics, shadow MMU/`mmu_shrinker` registration, `debugfs`/tracepoint name collisions (`kvm:` trace events are a global namespace), `kvm_x86_ops` static calls (per-module, probably fine), and the SEV code in `kvm-amd` (consumer Ryzen has no host SEV, but the module still contains it).

**Conclusion for (a)-coexist:** rows 1-7 are engineering work (a rename + a few patches, "a fork you must carry forever"). Row 8 is the real wall: two independent KVMs cannot safely share the same CPUs' SVM state. It would only be safe if the second instance never runs at the same time as the first on the same host CPUs, which is the same as "replace" (3.1), or if the second one lives in a **nested L1** (section 5), where it gets its own *virtual* SVM state.

### 3.3 Intel vs AMD note

The host is AMD, so the vendor module is `kvm-amd`. Everything above is the same for `kvm-intel` (VMX has its own per-CPU VMXON regions and a VPID pool; same class of problem). If the host were ever replaced by an Intel box, redo the audit.

---

## 4. Per-VM selection mechanisms

| Mechanism | Works? | Notes |
| --- | --- | --- |
| **QEMU `-accel kvm,device=/dev/kvm-alt`** | Yes, if a second device node exists | Needs a fork exposing a second misc device (3.2 row 4) *and* solving the rest of 3.2. Easy to inject from the existing `/usr/bin/kvm` wrapper for VMIDs in `/etc/qemu-ad/vms` (e.g. `args:` or wrapper rewrite). Cheap on the QEMU side, expensive on the kernel side |
| **Device-node permissions / bind mount in a mount namespace** | Partly | A container or `unshare -m` can bind-mount a different node onto `/dev/kvm` for one QEMU process. Does not create a second KVM; it only chooses between nodes that already exist. `/dev/kvm` itself is not namespaced |
| **Containers/cgroups (device cgroup)** | Access control only | Can allow/deny a node, not provide a second implementation |
| **Boot-time selection** | Yes | One KVM per boot; pick a kernel with `proxmox-boot-tool kernel pin <ver> [--next-boot]` ([Host Bootloader wiki](https://pve.proxmox.com/wiki/Host_Bootloader)). Per-boot, not per-VM |
| **Whole VM inside a nested L1** | Yes | L1 has its own kernel, its own `/dev/kvm`, its own QEMU. Per-VM at the granularity of "which L1 the VM lives in" (section 5) |
| **Different VMM** | Only for non-KVM accelerators | QEMU lists `kvm, xen, hvf, nitro, nvmm, whpx, mshv, tcg` ([QEMU docs](https://www.qemu.org/docs/master/system/invocation.html)); on a Linux/AMD host only `kvm`, `xen` (needs Xen as host), `tcg` (software, too slow for Windows+GPU) apply |

---

## 5. Interpretation (b): nested L1 host vs bare-metal

Terminology (from [kernel docs](https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html)): **L0** = bare-metal PVE host, **L1** = the guest hypervisor (VM running its own KVM), **L2** = the nested guest. In this study, L1 is either the existing **VM 9000 `pve-test-qad`** (a PVE 9.2.2 instance) or a new minimal Linux VM.

### 5.1 What nesting needs (and what is already true)

- AMD nested SVM is on by default since Linux 4.20 (`nested` parameter) ([kernel docs](https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html)). PVE requires the L1 VM CPU type `host` (`qm set <vmid> --cpu host`) ([PVE Nested Virtualization](https://pve.proxmox.com/wiki/Nested_Virtualization)). The lab notes say VM 9000 already has `cpu=host`, nested on and `/dev/kvm` present.
- **VMs with nesting active cannot be live-migrated** ([PVE wiki](https://pve.proxmox.com/wiki/Nested_Virtualization)). On AMD, saving/migrating an L1 while an L2 is running gives "undefined behavior" including kernel BUGs ([kernel docs](https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html)). So: **no RAM snapshots of L1 while L2 runs; use cold snapshots** (VM 9000's existing `pre-qemu-ad` is cold: good).
- A separate KVM in L1 is *genuinely separate*: its own `kvm.ko`, own misc device, own `SVME` state (virtual), own ASID pool. None of the 3.2 collisions apply, because L0 emulates SVM for L1 and keeps L1's state apart from L0's.

### 5.2 Performance

- PVE's own wiki: nested without hardware-assisted extensions is "10x slower or more"; with `cpu=host` + nested enabled it is much better but still "adds an overhead" ([PVE wiki](https://pve.proxmox.com/wiki/Nested_Virtualization)). I found no authoritative number for AMD nested L2 overhead for a given workload, so I give none: **measure it** (Phase 1 measures boot time, disk, a CPU benchmark, interrupt latency in L2 vs L1 vs L0).
- Why it is slower in principle: on AMD, every L2 `#VMEXIT` goes to L0 first, which then synthesizes an exit to L1 (L0 emulates `VMRUN`, VMCB merging). The Hyper-V "nested specific" enlightenments (`hv-emsr-bitmap`, `hv-tlbflush-direct`, with SVM support) exist for **Hyper-V as L1**, not for Linux L1 ([QEMU Hyper-V doc](https://www.qemu.org/docs/master/system/i386/hyperv.html)); they don't apply to a PVE L1.
- GPU work in L2 would not be exit-bound once the GPU is really passed through (the guest talks to the card directly); CPU-bound, exit-heavy and timer-heavy workloads in L2 will feel the nesting.

### 5.3 GPU passthrough with nesting (the hard part)

- To give the RTX 4080 to an L2, it must first be given to **L1** (normal `hostpci`, exclusively; VM 500 and VM 9102 can't hold it at the same time. Lab notes: "VM 500 must stay stopped while the GPU is held").
- Then L1 must hand it to L2 with VFIO, which needs an **IOMMU inside L1**. VFIO's safe mode requires an IOMMU; no-IOMMU mode exists but has no container/IOMMU API, so QEMU's normal VFIO device assignment cannot be used with it ([kernel VFIO docs](https://docs.kernel.org/driver-api/vfio.html)).
- QEMU documents the pattern for *Intel*: `intel-iommu,intremap=on,caching-mode=on` in L0's QEMU for L1, so L1 can shadow L2's DMA mappings ([QEMU VT-d wiki, "Nested Guest Device Assignment"](https://wiki.qemu.org/Features/VT-d)). Our host is **AMD**: a vIOMMU DMA-remapping series for AMD (`amd-iommu,dma-remap=on`) was posted to qemu-devel in April and September 2025 ([v1](https://lists.nongnu.org/archive/html/qemu-devel/2025-04/msg01911.html), [v3](https://lists.libreplanet.org/archive/html/qemu-devel/2025-09/msg04038.html)) and states testing with Linux guests and VFs, and it notes an open issue on guest reboot with `forcedac`. I **could not confirm** from the sources whether it is in PVE's `pve-qemu-kvm 11.0.x`, whether PVE's `qm` can enable it, or whether it works with a consumer GPU (BAR sizes, resizable BAR, reset behaviour, ACS/IOMMU groups inside L1). Treat "GPU to L2 on AMD" as **unproven; budget a spike and expect it may fail**.
- Even if it works: every GPU DMA translation is shadowed through two software layers, mapping updates are slower, and device reset (FLR/bus reset) paths of a GeForce card inside two layers of virtual PCI topology are a classic source of hangs. Failure mode: L1 or the GPU wedged, which requires stopping the L1 and sometimes a host reboot.

### 5.4 Windows guest quirks under nesting

- Windows guest as **L2**: fine in principle; do not enable Hyper-V/VBS/WSL2 *inside* it (that would be L3).
- Windows 10 1803+ BSOD on KVM was fixed by `kvm.ignore_msrs=1` (PVE wiki "Bluescreen at boot since Windows 10 1803"); on a fork or in L1 the equivalent module parameter must be set again (`options kvm ignore_msrs=1` in the L1's modprobe.d).
- Hyper-V enlightenments (`hv-*`) change CPUID 0x40000000.. to Hyper-V identity when enabled; KVM identity moves to 0x40000100 ([QEMU Hyper-V doc](https://www.qemu.org/docs/master/system/i386/hyperv.html)). Recommended set for plain Windows guests: relaxed, vapic, spinlocks, vpindex, runtime, time, synic, stimer, tlbflush, ipi, frequencies. Every added layer re-runs this tuning.
- `qemu-ad-pve` limits carry over unchanged: guests must use SATA + e1000e (virtio IDs are rewritten to 8086:*), no qemu-ga, no live backup (README).

### 5.5 Nested vs bare-metal: what each stage can validate

| Question | Nested (L1 = VM 9000) | Bare metal (host, VM 9102) |
| --- | --- | --- |
| Does the fork **build** against PVE headers/DKMS and survive `apt` kernel updates? | **Yes** (use the same PVE package line; confirm L1 kernel ABI string vs host's) | Yes (final proof) |
| **Symbol / name / misc-device / perf / cpuhp** collisions when loading two modules | **Yes** (software-only logic; same source) | Yes |
| `-accel kvm,device=` and wrapper-based per-VM selection | **Yes** | Yes |
| Rename/monolithic module loads, VM runs, module refcounts, unload | **Yes**, and a crash only kills L1 | Yes, but a crash takes the host |
| Real **SVME/HSAVE/ASID** behaviour of two modules on one CPU | **No.** L1's SVM is emulated by L0, so hardware ASID/TLB-isolation hazards are not representative; only the software logic is | Required, and dangerous |
| Windows L2 boots, stable for hours, enlightenments | **Partly** (works, but slower; timing differs) | Yes |
| **GPU passthrough** (VFIO, IOMMU groups, reset, Code 43-class issues) | **No**, unless the GPU is given to L1 (needs 9102/500 off the card, and vIOMMU in L1; see 5.3) | **Yes**, the only real test |
| **Performance / latency / VM-exit cost** | **No** (nested exits cost more, numbers don't transfer) | Yes |
| Behaviour of **other host VMs** (110/115/200/245) | No | Yes |
| **Secure Boot** + signed DKMS module + MOK enroll | Only if L1 is switched to OVMF with Secure Boot (VM 9000 is currently q35/SeaBIOS per lab notes) | Yes |
| Rollback of kernel pin / boot | Yes (L1 snapshot rollback is easy) | Needs console/IPMI access |

Rule: **nested validates logic and build; only bare metal validates hardware sharing, GPU and timing.**

---

## 6. Interpretation (c): kexec or dual-kernel boot

- **Dual boot (two PVE kernels in the boot menu).** Easy: `proxmox-boot-tool kernel pin <version>` selects the kernel (permanent or `--next-boot`) ([PVE Host Bootloader](https://pve.proxmox.com/wiki/Host_Bootloader)). Gives "a separate KVM" per boot, host-wide. Needs a reboot to switch and a second kernel build that carries the patched KVM (or the same kernel + DKMS). Good as a **rollback** story, bad as a "per-VM" story.
- **kexec.** `kexec` loads and boots another kernel from the running one **without** firmware/BIOS hardware initialisation ([kexec(8)](https://man7.org/linux/man-pages/man8/kexec.8.html)). It is still a full replacement of the running kernel: all VMs go down. With Secure Boot lockdown `kexec_file_load` is required for a signed kernel (same man page). Devices that were passed through to VMs/VFIO are not reset by firmware during a kexec; a GPU that was not cleanly reset is a hazard for the next kernel's driver and for VFIO. The VFIO "live update" patches preserve a device across kexec only experimentally and reset it to idle first ([KHO docs](https://www.kernel.org/doc/html/latest/core-api/kho/index.html), [VFIO live update series](https://www.spinics.net/lists/kexec/msg39375.html)). Net effect: nothing a normal reboot doesn't give, except speed.
- **Multikernel** (two independent Linux kernels on disjoint CPUs of one machine). Cong Wang's RFC v2 (Oct 2025) proposes this using kexec plumbing and IPIs; it is an RFC and explicitly not production-ready, tested on the author's hardware ([LWN](https://lwn.net/Articles/1042586/), [RFC cover letter](https://www.spinics.net/lists/kernel/msg5885956.html)). Not usable on a PVE host today.
- Verdict: **(c) is a deployment tool for (a)-replace, not a way to run two KVMs at once.**

---

## 7. Interpretation (d): alternative stacks

- **Firecracker:** no PCI/VFIO (its device model omits PCI/PCIe emulation), so no GPU passthrough ([mvm research notes citing Firecracker](https://docs.rs/crate/mvmctl/latest/source/specs/research/gpu-passthrough.md)); also uses `/dev/kvm`. Not relevant.
- **Cloud Hypervisor:** *does* support VFIO PCI passthrough and Windows 10/Server 2019 guests (UEFI only, virtio drivers) ([vfio.md](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/vfio.md), [windows.md](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/windows.md), [README](https://github.com/cloud-hypervisor/cloud-hypervisor/blob/master/README.md)). It still opens `/dev/kvm` (or `/dev/mshv` on Hyper-V). So it is a different **VMM**, not a different **KVM**. Also, a different VMM does not hide QEMU-specific strings by itself; it has its own guest-visible identity. Interesting only if you want a non-QEMU device model.
- **crosvm:** similar category; limited Windows story.
- **Xen:** a different hypervisor entirely (Dom0 + Xen microkernel, PCI passthrough supported), but Proxmox does not run on it; it would replace PVE on that box. Out of scope.
- **QEMU TCG:** software emulation, no `/dev/kvm`; far too slow for Windows + 4080.
- Verdict: **(d) offers nothing for "a separate kvm.ko".**

## 8. Interpretation (e): hardware KVM switch

If "KVM" meant keyboard-video-mouse: a hardware KVM switch (or a USB switch + HDMI/DP switch) shares one keyboard, display and mouse between machines. For a passed-through GPU the monitor is on the GPU's output, so a DP/HDMI switch + USB switch (or evdev passthrough with a hotkey, e.g. QEMU `input-linux`) does it. Unrelated to the hypervisor. Mentioned only for completeness; the brief makes it unlikely.

---

## 9. Cross-cutting concerns

### 9.1 Proxmox kernel, headers, DKMS
- PVE 9.2 ships `proxmox-kernel-7.0` (git shows `7.0.14-21` as of 2026-09-30). Headers are `proxmox-headers-<ver>-pve` (`pve-headers-$(uname -r)` / `proxmox-default-headers` in practice) ([forum](https://forum.proxmox.com/threads/nvidia-dkms-driver-failure-on-proxmox-ve-9-2-4-with-kernel-7-0-x-quadro-p2000-%E2%80%94-seeking-guidance.185092/), [guide](https://geekistheway.com/2026/06/17/fixing-nvidia-driver-compilation-failures-on-proxmox-9-2-debian-trixie-linux-kernel-7-x/)).
- KVM is **not** a normal out-of-tree-friendly module: it depends on kernel-internal headers (`arch/x86/kvm/*.h`) that are not shipped in a typical headers package. Building a forked `kvm` realistically needs the **full kernel source tree** (the `pve-kernel` git + Ubuntu submodule), not only `-headers-`. Config options (`CONFIG_KVM_AMD_SEV`, `CONFIG_KVM_HYPERV`, ...) and the vermagic/ABI of the exact PVE kernel must match. (Inference from the Makefile structure; confirm by attempting the build in Phase 1.)
- A rebuild hook is needed per kernel (DKMS `AUTOINSTALL`), plus a "refuse to boot into mismatch" guard. Each Proxmox kernel update after a security fix means retesting.

### 9.2 Secure Boot / module signing
- With Secure Boot on, the kernel only loads modules signed by a trusted key; DKMS generates `/var/lib/dkms/mok.{key,pub}` and the pub key must be enrolled with `mokutil --import` + reboot confirmation ([Host Bootloader wiki](https://pve.proxmox.com/wiki/Host_Bootloader), [Secure Boot Setup](https://pve.proxmox.com/wiki/Secure_Boot_Setup)). Kernels from 6.2.16-8 have `CONFIG_MODULE_SIG`; stock modules are signed with an ephemeral key embedded in that kernel image.
- A replaced `kvm.ko` under Secure Boot must be signed with an enrolled key; a failure leaves the host without KVM (VMs won't start) after reboot. Whether the host runs Secure Boot is unknown to me (open question).
- Lockdown also affects `kexec_load` (kexec(8) above).

### 9.3 VFIO / IOMMU / GPU
- VFIO and the IOMMU are independent of which KVM module runs the VM; the passthrough path is `vfio-pci` + IOMMU group (group 13 holds the 4080 and its audio function per lab notes). Swapping KVM doesn't change IOMMU groups.
- The *only* coupling points are: (i) vfio's `symbol_get(kvm_get_kvm_safe/kvm_put_kvm)` (3.2 row 7), (ii) KVM's VFIO pseudo-device (`virt/kvm/vfio.c`, used for coherency and, on x86, for non-coherent DMA/WBINVD handling), (iii) interrupt posting via irqbypass. Each must be re-checked in a fork.
- Never assign the same PCI device to two VMs; the card can have only one owner (an L1 and a bare-metal VM can't both hold it).

### 9.4 Windows 10 guest
- Keep SATA + e1000e, `vga none` + `x-vga=1` GPU, `cpu host,hidden=1` as in the current working config for 9101/9102 (lab notes). A nested or forked KVM must be re-validated against that known-good config: Device Manager Code 0 for the 4080, `nvidia-smi` OK.

---

## 10. Anti-detection impact (architectural only)

Not a how-to; just where things live, so the decision about *whether a separate KVM is even needed* can be made.

- Guest-visible identity has three layers: **(1) QEMU** (device models, PCI IDs, SMBIOS/ACPI strings), **(2) KVM's CPUID/MSR handling** (what the guest reads from CPUID/MSRs; much of it is policy set by userspace through the KVM ioctl interface, e.g. `KVM_SET_CPUID2`, and by QEMU `-cpu` flags), and **(3) timing** (what the hardware does under virtualization). `qemu-ad-pve` already works at layer 1, and uses the stock `hidden=1`/`kvm=off` mechanism at layer 2. Its README states it "does not hide timing".
- A **separate kvm.ko** is only needed for behaviour that userspace cannot configure through the existing KVM API. Before building anything, list exactly which behaviour that is. If the list is empty, nothing in this study is needed.
- A **nested L1** *adds* a virtualization layer: from the inside it is *more* virtualized than bare metal (L2 under L1 under L0, with L0 also visible through nested SVM emulation behaviours), not less. It is a poor match for any goal of looking like physical hardware. It remains useful as a safe **test bench for kernel work**.
- A **second module in the same host** does not change what the guest sees by itself; it only changes who services the exits.
- Out of scope here, deliberately: methods to defeat specific anti-cheat vendors, and timing-compensation designs. See 1.2.

---

## 11. Risks

| Risk | Where | Severity | Mitigation |
| --- | --- | --- | --- |
| Host crash/hang when loading a patched/forked KVM on the production host (other VMs 110/115/200/245 down) | (a) bare metal | High | Phase 1 in nested L1 first; maintenance window; serial/IPMI/console access; kernel pin as rollback |
| Cross-guest memory/TLB isolation bugs from two SVM instances on one CPU (ASID reuse, SVME toggled under the other) | (a)-coexist | High (security + corruption) | Don't coexist on one host; use replace or nested |
| Perf callbacks / cpuhp conflicts: second module fails or silently loses features | (a)-coexist | Medium | Patches; or don't |
| Patch rot at every PVE kernel bump (weekly-ish) | (a) | High ongoing cost | CI that rebuilds against each new `proxmox-kernel`; pin kernel until validated |
| `apt upgrade` pulls a kernel without the module → VMs fail to start after reboot | (a) | High | DKMS autoinstall + pre-reboot check script; keep previous kernel pinned |
| Secure Boot: unsigned module not loaded; MOK enroll needs console access at reboot | (a) | Medium | Test in L1 with OVMF+SB; enroll MOK beforehand |
| GPU not reset properly / host hang when VM restarts (esp. in nested) | (b) | Medium-High | Test restart cycles; keep a host-level break-glass; don't test with GPU in L1 until the vIOMMU path is proven |
| Nested L1 snapshot/migration on AMD with a running L2 → undefined behaviour | (b) | Medium | Cold snapshots only; never migrate L1 |
| L1 bugs reaching L0 nested-SVM code (nested virt has had real CVEs) | (b) | Low-Medium | Keep L0 kernel current; L1 runs only lab guests |
| Third-party module taints the kernel and voids support/bug reports | all | Low | Note for forum/enterprise support |
| TOS/legal: using the stack to evade a game's anti-cheat | purpose-dependent | Account bans | Out of scope; see 1.2 |

---

## 12. Effort estimates

These are my engineering judgements for one experienced person, not sourced numbers.

| Option | PoC | Productionised (per-kernel upkeep) | Confidence |
| --- | --- | --- | --- |
| A. Replace stock kvm/kvm-amd with patched DKMS build | 2-4 days (build env, one patch, boot test in nested L1) | 0.5-2 days per PVE kernel bump, if patch is small | Medium |
| B. True coexistence fork (rename + 7 conflict fixes) | 2-4 weeks | Ongoing, high; plus a **hard unsolved problem** (row 8) | Low |
| C. Nested L1 (PVE or plain Linux) running L2 Linux/Windows, no GPU | 1-3 days (VM 9000 exists) | Low | High |
| C'. C with the RTX 4080 passed to L2 via vIOMMU on AMD | 1-3 weeks spike, **may be impossible** | Medium | Low |
| D. Dual-boot pinned alternate kernel | 1 day | Low | High |
| E. Cloud Hypervisor / other VMM | 1-2 weeks to get a Windows + GPU guest comparable to today's | Medium | Low-Medium |
| F. Do nothing at kernel level (keep qemu-ad-pve in userspace) | 0 | 0 | n/a |

---

## 13. Recommendation

1. **Pin down the requirement first** (section 15, Q1-Q3). If everything needed is reachable through QEMU/`-cpu` and the KVM userspace API, the answer is F: no separate KVM.
2. If a kernel change is truly required: do **A (replace)**, not B. Implement the change as a small patch to the PVE kernel's `kvm`/`kvm-amd`, delivered by DKMS and pinned kernel, with a boot-time guard and a break-glass revert.
3. If a **per-VM** choice is required, use the **nested L1** route (C) for non-GPU work, and for GPU work only after a spike proves a vIOMMU path (C') on this exact hardware. A reboot-selected kernel (D) is the fallback for GPU VMs.
4. Treat a simultaneous dual-module coexistence (B) as **out**, unless someone is prepared to write and maintain an SVM arbiter. The sources show the blocker (3.2 row 8), not a missing patch.
5. Start the PoC on the **nested PVE (VM 9000)** (section 14), because it can validate everything in 3.2 rows 1-7, packaging, and selection, with no risk to the host or to 9102, then graduate to 9102.

---

## 14. Phased PoC plan

All phases are plans. Each phase has an exit criterion; do not proceed without it. Nothing here has been run.

### Phase 0: read-only fact finding (no changes)
On the host and on VM 9000, collect (Brandon/Infra to run; all read-only): `uname -r`, `pveversion -v`, `lsmod | grep -E 'kvm|vfio'`, `modinfo kvm_amd`, `cat /sys/module/kvm_amd/parameters/{nested,avic}`, `ls -l /dev/kvm` (expected: char 10,232), `mokutil --sb-state`, `dkms status`, `proxmox-boot-tool status`, `dmesg | grep -i -E 'kvm|svm'`, `lscpu | grep -i -E 'svm|model name'`.
Exit: facts match assumptions A1-A2; Brandon has answered Q1-Q3.

### Phase 1: nested PVE (L1 = VM 9000 `pve-test-qad`), no GPU

Why here: VM 9000 is an AMD-nested PVE 9.2.2 with `/dev/kvm`, 8 vCPU, 16 GB, 100 GB disk, and a cold snapshot `pre-qemu-ad`. Failure costs a rollback, not the host. It also already has `qemu-ad-pve` installable (it was built as its test node).

Preconditions / constraints of the nested stage (see 5.1-5.5):
- Take a **new cold snapshot** (no RAM) before every experiment; never save RAM or migrate with an L2 running (AMD).
- L1 kernel must be the **same `proxmox-kernel` ABI** as the host (check against Phase 0), otherwise results about build/vermagic do not transfer. VM 9000 has PVE 9.2.2; the host runs a newer `pve-manager` (9.2.3 at last check), so update L1's kernel to the host's version for like-for-like.
- L2 guests: a tiny Linux (Alpine) for fast loops; later a Windows 10 clone (SATA + e1000e, `vga std`) for a smoke test. No GPU. L2 will be slower; judge correctness, not speed.
- Do not touch the 4080: VM 500 stays stopped and 9102 keeps it.

Steps:
1. **1a Baseline** (L1 untouched): start L2 Linux with the vendor QEMU and with the side QEMU (via the existing wrapper); record boot time, a CPU benchmark, `perf stat` exit rates. This becomes the nested reference, to be compared only with itself.
2. **1b Build mechanics:** fetch `pve-kernel` source for the exact L1 kernel; build **unmodified** `kvm` + `kvm-amd` as `updates/` overrides (same names). Load by `modprobe -r kvm_amd kvm` (no L2 running) then `modprobe`. Check `vermagic`, `dmesg`, Secure Boot signing path (only meaningful if L1 is OVMF+SB; otherwise note as not validated).
3. **1c Coexistence reproduction (negative tests):** build the same source with only a rename and try `insmod` beside the stock module. Expected failures to observe and log: duplicate export (row 2), import restriction (row 3), misc minor busy (row 4). This confirms the table in 3.2 against the real kernel.
4. **1d Fork fixes in order:** monolithic renamed module with exports removed → dynamic misc minor + name `kvm-ad` → skip perf callback registration → dynamic cpuhp state. After each, record what still fails. Expect row 8 to remain a design issue, not a crash; design a *logging-only* probe (counts of SVME toggles, ASID values per CPU for both modules) instead of running two real guests concurrently on real hardware logic.
5. **1e Per-VM selection:** with the renamed module loaded and the stock one unloaded (replace mode), run L2 with `-accel kvm,device=/dev/kvm-ad` via the wrapper for a listed VMID; confirm via `lsof /dev/kvm-ad` / `/proc/<pid>/fd` and module refcounts that the right device is in use. Also test the failure path (device missing).
6. **1f Lifecycle:** CPU offline/online, VM start/stop 200 times, `rmmod` with VM running (must refuse), reboot, kernel upgrade with DKMS rebuild, and rollback via `proxmox-boot-tool kernel pin`.
7. **1g Windows L2 smoke (no GPU):** Windows 10 clone boots and is stable for 2 hours with the forked KVM; compare against the stock-KVM L2.

Exit criteria: (i) the 3.2 table is confirmed or corrected from real logs; (ii) replace-mode fork builds, loads, selects per VM, survives lifecycle tests, DKMS rebuilds on a kernel bump; (iii) a written decision: replace-only vs. more work on coexistence.

What Phase 1 **cannot** tell you: real SVM/ASID/TLB behaviour, GPU, performance, other-VM impact, true Secure Boot on the host (5.5).

### Phase 2 (optional spike): GPU into L1/L2 on nested
Only if the requirement needs a per-VM kvm with the GPU. Requires: Brandon's approval; 9102 and 500 off the card; a **new** L1 (not VM 9000, to keep it clean); `hostpci` of the 4080 to L1; vIOMMU for L1 (`amd-iommu` with DMA remap, if PVE's QEMU supports it; otherwise stop); in L1, VFIO bind and pass to L2. Exit: L2 Windows sees the 4080 with Code 0 and survives 10 restarts without hanging L1 or L0. Expectation: may fail; that is itself the answer (then use D).

### Phase 3: graduate to bare metal, VM 9102
Preconditions: Phase 1 exit met; Brandon's go-ahead; maintenance window (all other VMs stopped or accepted down); console/IPMI access; full backup; cold snapshot of 9102 (it already has snapshot rollback points per lab notes); `qemu-ad-breakglass.sh` available.
1. 3a: build the same fork for the host's exact kernel; install as `updates/`; **do not load yet**. Verify signature/MOK if Secure Boot.
2. 3b: with all VMs stopped, swap modules (replace mode); start a throwaway Linux VM, then 9102 on the vendor flow; verify 9102 Windows boots, 4080 Code 0, `nvidia-smi`, 1-hour soak. Record exit rates vs stock for 9102 (the real performance comparison).
3. 3c: only if per-VM selection is required and coexistence was shown safe (it probably won't be): run 9102 on `kvm-ad` and a Linux VM on stock simultaneously; this is the first and riskiest bare-metal coexistence test and should only be attempted if Phase 1 produced an ASID/SVME arbiter design that passed review.
4. 3d: rollback drill: remove `updates/` module, `depmod -a`, reboot to the pinned stock kernel (or `proxmox-boot-tool kernel pin <stock> --next-boot`), confirm all VMs start.

Exit: 9102 passes the same checks it passes today, and rollback is proven.

### Phase 4: operate
CI that rebuilds + smoke-tests on each new `proxmox-kernel` in an L1 before allowing it on the host; kernel pin policy; documented break-glass; decision log.

---

## 15. Open questions for Brandon

1. **What do you mean by "separate KVM"?** (a) a patched `kvm.ko`/`kvm_amd.ko`, (b) a second hypervisor/L1 instance, (c) a different kernel, (d) a different VMM, (e) a hardware KVM switch? The study assumes (a)/(b).
2. **What concrete behaviour do you need that QEMU + `-cpu` flags + the existing KVM userspace API cannot do?** If none, we stop at F (no separate KVM). If some, name it so the patch can be scoped.
3. **Per-VM or host-wide?** Is it acceptable that *all* VMs (110/115/200/245 too) run the patched KVM (replace mode)? Or must the other VMs stay on stock at the same time?
4. **Is a host reboot / maintenance window acceptable** for the bare-metal phase, and do you have console/IPMI access?
5. **Is Secure Boot on** on the host? (needed for MOK/DKMS planning)
6. **Which exact kernel is the host on** (`7.0.12-1-pve` from notes vs the current `7.0.14-x`)? Keep it pinned during the PoC?
7. **Is the nested PVE (VM 9000) the L1 to use for Phase 1?** OK to move it to the host's kernel version and switch it to OVMF + Secure Boot for the signing test? (Changes only that VM, but it is still a change; I have not made it.)
8. **Is GPU-to-L2 (nested) a hard requirement?** If yes, are you OK with a possibly negative spike (Phase 2) and the GPU being unavailable to 9102 during it?
9. **Stability bar:** does the host need to stay up for other services during the PoC, or may it go down?
10. **Purpose check:** what is the target software/test? (This drives whether the userspace layer is already enough, and keeps the work within lab/dev use as the `qemu-ad-pve` README describes.)

---

## 16. Sources

Kernel (v7.0 tag, read directly):
- KVM x86 Makefile: https://github.com/torvalds/linux/blob/v7.0/arch/x86/kvm/Makefile
- `virt/kvm/kvm_main.c` (misc device, cpuhp, perf callbacks, enable_virt_at_load): https://github.com/torvalds/linux/blob/v7.0/virt/kvm/kvm_main.c
- `include/linux/kvm_types.h` (`EXPORT_SYMBOL_FOR_KVM_INTERNAL`): https://github.com/torvalds/linux/blob/v7.0/include/linux/kvm_types.h
- `include/linux/export.h` (`EXPORT_SYMBOL_FOR_MODULES`): https://github.com/torvalds/linux/blob/v7.0/include/linux/export.h
- `kernel/module/main.c` (duplicate exported symbol check): https://github.com/torvalds/linux/blob/v7.0/kernel/module/main.c
- `kernel/events/core.c` (perf_register_guest_info_callbacks): https://github.com/torvalds/linux/blob/v7.0/kernel/events/core.c
- `kernel/cpu.c` (cpuhp_store_callbacks -EBUSY): https://github.com/torvalds/linux/blob/v7.0/kernel/cpu.c
- `drivers/vfio/vfio_main.c` (symbol_get kvm): https://github.com/torvalds/linux/blob/v7.0/drivers/vfio/vfio_main.c
- `arch/x86/kvm/svm/svm.c` (SVME, HSAVE_PA, ASIDs): https://github.com/torvalds/linux/blob/v7.0/arch/x86/kvm/svm/svm.c
- `include/linux/miscdevice.h` (KVM_MINOR=232, MISC_DYNAMIC_MINOR): https://github.com/torvalds/linux/blob/v7.0/include/linux/miscdevice.h
- Caveat: PVE's kernel is Ubuntu-derived and patched; line-level facts should be re-checked against `pve-kernel.git`.
- Nested guests: https://docs.kernel.org/virt/kvm/x86/running-nested-guests.html
- VFIO: https://docs.kernel.org/driver-api/vfio.html
- KHO / kexec handover: https://www.kernel.org/doc/html/latest/core-api/kho/index.html
- Multikernel RFC: https://lwn.net/Articles/1042586/ , https://www.spinics.net/lists/kernel/msg5885956.html
- kexec(8): https://man7.org/linux/man-pages/man8/kexec.8.html

QEMU:
- Invocation docs (`-accel kvm,device=`): https://www.qemu.org/docs/master/system/invocation.html
- Commit adding `device`: https://github.com/qemu/qemu/commit/aef158b093b9d67381f88468d39ac8dd62ae9e8b
- Hyper-V enlightenments: https://www.qemu.org/docs/master/system/i386/hyperv.html
- VT-d / nested device assignment: https://wiki.qemu.org/Features/VT-d
- AMD vIOMMU DMA remap series: https://lists.nongnu.org/archive/html/qemu-devel/2025-04/msg01911.html , https://lists.libreplanet.org/archive/html/qemu-devel/2025-09/msg04038.html

Proxmox:
- Nested virtualization: https://pve.proxmox.com/wiki/Nested_Virtualization
- Host bootloader / kernel pin / DKMS+SB: https://pve.proxmox.com/wiki/Host_Bootloader
- Secure Boot setup: https://pve.proxmox.com/wiki/Secure_Boot_Setup
- pve-kernel git: https://git.proxmox.com/?p=pve-kernel.git
- Downloads page (kernel 7.0 `pveversion` sample): https://pve.proxmox.com/wiki/Downloads
- DKMS vs 7.0 example: https://forum.proxmox.com/threads/nvidia-dkms-driver-failure-on-proxmox-ve-9-2-4-with-kernel-7-0-x-quadro-p2000-%E2%80%94-seeking-guidance.185092/

Other stacks:
- Cloud Hypervisor VFIO: https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/vfio.md ; Windows: https://github.com/cloud-hypervisor/cloud-hypervisor/blob/main/docs/windows.md ; README: https://github.com/cloud-hypervisor/cloud-hypervisor/blob/master/README.md
- Firecracker GPU passthrough limitation (secondary source): https://docs.rs/crate/mvmctl/latest/source/specs/research/gpu-passthrough.md

Project context:
- qemu-ad-pve: https://github.com/branpurn/qemu-ad-pve
- Lab notes (host CPU/kernel/GPU/IOMMU, VM 9000 spec, VM 9101/9102 configs): private work-box notes, not re-verified on 2026-10-02.

Not verified (flagged in text): depmod `updates/` precedence; PVE `qemu-server`/`pve-qemu-kvm 11.0.x` AMD vIOMMU DMA-remap support; full-source-tree requirement for building KVM modules; any nested-AMD performance numbers.
