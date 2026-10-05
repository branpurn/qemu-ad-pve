# GPU phase: a patched `kvm` / `kvm-amd` module inside the nested L1 (VM 9200), Windows 10 L2 with the RTX 4080 under it

Date: 2026-10-03 (test window about 16:05-16:36 EDT). Author: Grok Bot for Brandon (decisions deferred to the 9-9-6 Developer bot, who approved this phase). Follows [gpu-phase-intel-viommu.md](gpu-phase-intel-viommu.md) (PR #4), [gpu-phase-windows-l2.md](gpu-phase-windows-l2.md) (PR #5) and [gpu-phase-patched-qemu.md](gpu-phase-patched-qemu.md) (PR #6). Everything below was **run**; what was not run is listed at the end. No credentials, keys, MAC addresses or LAN addresses appear here.

Project intent that shaped every step: live **alongside** the existing PVE environment with a minimal footprint. The patched KVM exists only in the nested L1; the host kernel and modules stay stock; it must be easy to remove.

## Verdict

| Step | Verdict |
| --- | --- |
| Snapshot of 9200 before anything | **Done** (`pre-kvm-module`, `qm snapshot` worked with `hostpci0` present because the VM was stopped) |
| Step 1: benign patched `kvm.ko` + `kvm-amd.ko` in L1 (build, DKMS install, unload stock, load patched, unload, restore stock, reinstall) | **PASS**: version string / description / module parameter / dmesg line prove the patched modules are the ones running; full cycle repeated twice; survives an L1 reboot |
| Step 2: Windows 10 L2 + RTX 4080 with the **patched `qemu-ad-pve` binary running inside L1** under the patched KVM | **PASS**: `ConfigManagerErrorCode 0`, `nvidia-smi` 576.88, OpenCL and CUDA (CuPy) PASS, VRAM/BAR check, 270 s sustained load clean, warm L1 reboot + L2 relaunch clean |
| `qemu-ad-pve` can run in L1 | **Yes**, a verbatim copy of `/opt/qemu-ad` (464 MB) runs in L1's Debian 13 userland (all shared libs resolve, QEMU 10.2.2). **No fallback to Debian QEMU 10.0.13 was needed.** One feature is missing from that build: the `user` (slirp) network backend, so the L2 uses a `tap` on an isolated bridge inside L1 instead |
| Performance cost vs baseline | **None measurable**: patched KVM is within run-to-run noise of the PR #5/#6 numbers and of a same-session stock-KVM control (table below) |
| Host impact | Nothing changed on the host except: one qcow2 snapshot of 9200, helper files under `/root/gpu-phase-l1/`, 9102 stopped for about 30 minutes and restarted. No host kernel / module / package / GRUB / modprobe / QEMU change |

The patched modules are a **no-op patch** (a version tag, a read-only module parameter and one `pr_info`). The test proves the build-install-load-run toolchain and that a Windows GPU L2 runs normally on an out-of-tree rebuilt KVM; it does not exercise any behavioural KVM change.

## Safety notes up front

1. **Device names inside L1 are not stable.** In the PR #5 launcher the Windows disk was `/dev/sda`. In this phase's boot it was `/dev/sdb` (L1's root disk was `/dev/sda`), and after the warm reboot they swapped back (Windows disk `/dev/sda`, root `/dev/sdb`). On the first relaunch after the warm reboot my run script still had `/dev/sdb` hard-coded, so for **about 3-4 seconds** the L2 QEMU had **L1's mounted root disk** as its raw IDE disk. I noticed from `lsblk` straight after the launch and stopped it with the QEMU monitor `quit`. Evidence that no damage resulted (not proof of zero writes): the guest never got beyond firmware in that time, L1's root stayed `rw` with no ext4/I-O errors in dmesg, `dumpe2fs` reported the filesystem `clean`, and after L1's clean shutdown `qemu-img check` of 9200's root and EFI volumes reported "No errors were found". The script now detects the disk at run time (whole disk with an NTFS partition) and refuses a disk with a mounted partition or an ext4 partition. `/root/w10/VARS.fd` had changed, so it was restored from the pre-run copy. If you reuse the L2 launcher, use a disk selection like this, not `/dev/sdX` by hand.
2. Because the 9200 snapshot was requested, `/etc/pve/qemu-server/9200.conf` is **not** byte-identical to the AMD backup any more: it has a new `[pre-kvm-module]` snapshot section and `parent: pre-kvm-module`. The active (top) section is identical to the AMD backup apart from that `parent:` line. This is the intended consequence of the snapshot and is removed by `qm delsnapshot 9200 pre-kvm-module`.
3. Host RAM: with 9102 (64 GiB) running only about 5 GiB was available, so L1 (12 GiB) could not be started alongside it. I therefore stopped 9102 before booting L1 for the whole test, including the non-GPU module proof (the GPU would have forced that anyway).

## What was run, per step: what it changes in L1, on the host, and how to roll back

| # | Step | Changes in L1 | Changes on the host | Rollback |
| --- | --- | --- | --- | --- |
| 0 | `qm snapshot 9200 pre-kvm-module` (VM stopped; also copied the config to `/root/gpu-phase-l1/9200.conf.pre-kvm-module-20261003`) | none | internal qcow2 snapshot of 9200's root and EFI volumes (0.5 s, metadata only); new `[pre-kvm-module]` section + `parent:` line in 9200's own config; one config copy file | `qm rollback 9200 pre-kvm-module` (restores L1 disk + EFI) and/or `qm delsnapshot 9200 pre-kvm-module`; `rm` the copy |
| 1 | `qm shutdown 9102 --timeout 180` (8 s, clean) | none | 9102 stopped for the duration; GPU returned to `vfio-pci` (reset done on both functions, no faults) | `qm start 9102` (done at the end, verified) |
| 2 | Boot L1 with the **raw launch script** (copy of `win/launch-win-bridge-stock.sh`: stock `kvm.pve`, `intel-iommu,intremap=on,caching-mode=on`, both GPU functions behind a `pcie-pci-bridge`, 12 GiB, virtio disks/NIC; `qm start` does not work for this topology, see PR #4) | none | one new QEMU process (pid file `/var/run/qemu-server/9200.pid`), tap interface on the L1 bridge, new file `/root/gpu-phase-l1/launch-l1-kvmmod.sh`. 9200's config is **not** edited (still the AMD-args config) | `qm shutdown 9200 --timeout 120` (took 2.4 s); delete the script |
| 3 | Inspect L1 (kernel, Secure Boot, modules, headers, dkms) | none | none | n/a |
| 4 | `apt-get update`; `apt-get download linux-source-6.12=6.12.111-1`; extract only `arch/x86/kvm` and `virt/kvm` (3.1 MB) from its tarball | about 300 MB under `/usr/src/kvm-src-dl/` (the `.deb`, its extraction, the 3 MB tree, a pristine copy for diffing) | none | `rm -rf /usr/src/kvm-src-dl` |
| 5 | Create `/usr/src/kvm-patched-1.0/` (copy of the two source dirs + 2 Makefile edits + benign patch + `dkms.conf`), `dkms add`, `dkms build` (26 s on 8 vCPUs; modules auto-signed with the DKMS key) | `/usr/src/kvm-patched-1.0/` (3.1 MB), `/var/lib/dkms/kvm-patched/` (0.5 MB) | none | `dkms remove -m kvm-patched -v 1.0 --all; rm -rf /usr/src/kvm-patched-1.0` |
| 6 | `dkms install` (copies `kvm.ko.xz`, `kvm-amd.ko.xz` to `/lib/modules/6.12.111+deb13-amd64/updates/dkms/`, archives the stock ones, `depmod`), `modprobe -r kvm_amd kvm`, `modprobe kvm_amd` | patched modules loaded; stock `.ko.xz` files left in place under `kernel/arch/x86/kvm/` (and archived by DKMS) | none (L1's own kernel only; host kernel/modules untouched) | `modprobe -r kvm_amd kvm; dkms uninstall -m kvm-patched -v 1.0; modprobe kvm_amd` (tested twice) |
| 7 | Rollback cycle test: `dkms uninstall`, reload (stock back), `dkms install`, reload (patched) | module files swapped and back | none | as above |
| 8 | Copy `/opt/qemu-ad` from the host into L1 (`tar` over ssh; **read-only** on the host; checked: 146 files in both trees with identical sha256 content, same QEMU 10.2.2 `--version`) | `/opt/qemu-ad/` (464 MB) | none (the host copy is only read) | `rm -rf /opt/qemu-ad` in L1 |
| 9 | `apt-get install dnsmasq-base` (installs the binary only, no service; deps `libnftables1`, `dns-root-data`); `l2net-up.sh` creates bridge `brl2` + tap `tapl2` (a private /24, no routing/NAT, so the L2 is not on the LAN) and a private dnsmasq for DHCP | those packages; bridge/tap/dnsmasq are runtime only (gone after reboot or `l2net-down.sh`) | none | `/root/w10/l2net-down.sh`; `apt-get remove dnsmasq-base` |
| 10 | `/root/w10/run-w10-ad.sh` (PR #5 L2 launcher with `/opt/qemu-ad/bin/qemu-system-x86_64`, `tap` + `e1000e`, `-rtc base=localtime`, run-time Windows-disk detection) | new script; `/root/w10/VARS.before-kvmpatch-run.fd` backup copy | none | delete the script |
| 11 | Windows 10 L2 runs: checks, compute, AI-style workload, sustained load | writes to the Windows disk copy (9200's own `scsi1` volume, the 80 GB copy of 9101) and `/root/w10/VARS.fd` | GPU in use by L1's QEMU (as in PR #4-#6); host sees only `vfio-pci reset` lines | shut Windows down (`shutdown /s`), QEMU exits |
| 12 | Warm L1 reboot from inside (`systemctl reboot`), relaunch L2, re-verify | L1 reboot | L0 QEMU for L1 keeps running (normal guest reset); `vfio-pci` reset lines only | n/a |
| 13 | Same-session **A/B control**: `dkms uninstall` + reload (stock KVM), relaunch L2, same test suite | stock modules loaded | none | n/a |
| 14 | Cleanup: Windows `shutdown /s`, `l2net-down.sh`, `qm shutdown 9200`, `qemu-img check` of 9200's volumes, config compare, `qm start 9102`, verify | L1 left with **stock** KVM loaded by default | 9102 restarted and verified | see "Final state" |

## L1 build environment and requirements

| Item | Value |
| --- | --- |
| L1 | Debian 13 (trixie) VM, kernel `6.12.111+deb13-amd64` (`6.12.111-1`), 8 vCPU, 12 GiB, CPU `AMD Ryzen 9 7950X` (vCPU `AMD-V`, `cpu: host`), so the modules are **`kvm` + `kvm-amd`** (`kvm_amd nested=1 npt=Y avic=N sev=N`). L1's kernel cmdline has `iommu=pt` |
| Needed packages (all already in L1 except the source) | `linux-headers-6.12.111+deb13-amd64` (+ `-common`, and `linux-kbuild-6.12.111+deb13`), `build-essential` / `gcc-14`, `dkms 3.2.2`, `linux-source-6.12=6.12.111-1` (only downloaded, not installed: `apt-get download`, 153 MB) |
| Source/kernel match | The source package version must equal the running kernel's (`6.12.111-1` here). The `kvm` module is tied to the kernel by `modversions` CRCs and `vermagic`; a different source revision is not safe. After an L1 kernel update the `kvm-patched` tree must be **re-based on the matching `linux-source-6.12`** (DKMS `AUTOINSTALL="yes"` would otherwise try to build the old tree against the new headers) |
| Why not just `make` the in-tree Makefile | `arch/x86/kvm/Makefile` expects a full source tree (`$(srctree)/virt/kvm/...`, `-I $(srctree)/arch/x86/kvm`) and `TRACE_INCLUDE_PATH ../../arch/x86/kvm`. With only the headers package, the Makefile needs two edits (below) plus an empty `include/trace/` directory next to `arch/` and `virt/` so the tracepoint include path (`-I .../include/trace` followed by `../../arch/x86/kvm/trace.h`) resolves. A missing directory gave `fatal error: ../../arch/x86/kvm/trace.h` at first build |
| What is built | `kvm.ko` and `kvm-amd.ko` only (`CONFIG_KVM_INTEL=n` on the make line skips `kvm-intel.ko`). The stock `kvm-intel.ko` stays untouched and would not be ABI-compatible with a *functionally* patched `kvm.ko`, which does not matter on this AMD CPU |
| Build time | 26 s on 8 vCPUs; output: `kvm.ko.xz` 430 KB, `kvm-amd.ko.xz` 102 KB |
| DKMS vs manual build | DKMS chosen: `updates/dkms/` outranks `kernel/` in modprobe's `depmod` search order, so the patched modules shadow the stock ones **without deleting them**; `dkms uninstall` restores the archived originals and re-runs `depmod`. A manual `make` + `insmod` works for a quick test but does not survive a reboot or module autoload by `modprobe kvm_amd` (used by libvirt/QEMU startup) |

### Secure Boot / signing

| Item | State |
| --- | --- |
| L1 Secure Boot | `mokutil --sb-state`: **SecureBoot disabled**, "Platform is in Setup Mode". L1's firmware is the PVE `OVMF_CODE_4M.secboot.fd` with an EFI-vars volume created with `pre-enrolled-keys=0`, so no keys are enrolled: Secure Boot-capable firmware, but Setup Mode / off |
| Module signing | DKMS signed both modules with its auto-generated key (`/var/lib/dkms/mok.key`, `CN=DKMS module signing key`, created 2026-10-02 when `nvidia-kernel-dkms` was installed; `modinfo` shows `signer: DKMS module signing key`). That key is **not enrolled** in L1's keyrings, so each boot logs `kvm: module verification failed: signature and/or required key missing - tainting kernel` and the modules load anyway because L1 does not enforce signatures (Secure Boot off, no `module.sig_enforce`). L1's taint value stayed `12289` (P + O + E) before and after: it was already set at boot by the out-of-tree `nvidia` DKMS module |
| If Secure Boot were turned on in L1 | enrol the DKMS key (`mokutil --import /var/lib/dkms/mok.pub`, reboot, confirm in MokManager) or the patched modules would be refused (kernel lockdown). Not tested |
| L2 Windows OVMF Secure Boot | The L2 uses Debian `OVMF_CODE.fd` (3.5 MB, the `4M` layout) with the VARS copied from 9101. Windows: `Confirm-SecureBootUEFI` => "Variable is currently undefined" (i.e. Secure Boot not active / SecureBoot variable absent). Not changed by this phase |

### The patch (step 1, benign)

`patched/` is the Debian `linux-source-6.12` 6.12.111 tree restricted to `arch/x86/kvm` and `virt/kvm`; the diff against the pristine extraction (the diff header lines were normalised):

```diff
--- pristine/arch/x86/kvm/Makefile
+++ patched/arch/x86/kvm/Makefile
@@ -1,9 +1,9 @@
 # SPDX-License-Identifier: GPL-2.0
 
-ccflags-y += -I $(srctree)/arch/x86/kvm
+ccflags-y += -I $(src) -I $(src)/../../../include/trace
 ccflags-$(CONFIG_KVM_WERROR) += -Werror
 
-include $(srctree)/virt/kvm/Makefile.kvm
+include $(src)/../../../virt/kvm/Makefile.kvm
--- pristine/arch/x86/kvm/svm/svm.c
+++ patched/arch/x86/kvm/svm/svm.c
@@ -54,7 +54,12 @@
 MODULE_AUTHOR("Qumranet");
-MODULE_DESCRIPTION("KVM support for SVM (AMD-V) extensions");
+MODULE_DESCRIPTION("KVM support for SVM (AMD-V) extensions [kvm-patched step1: benign tag]");
+MODULE_VERSION("6.12.111-kvmpatch1");
+
+static char *patch_tag = "step1-benign";
+module_param(patch_tag, charp, 0444);
+MODULE_PARM_DESC(patch_tag, "Free-form tag of the out-of-tree patched build (read-only, no functional effect)");
 MODULE_LICENSE("GPL");
@@ -5621,6 +5626,8 @@ static int __init svm_init(void)
 	__unused_size_checks();
 
+	pr_info("kvm_amd: out-of-tree patched build loaded (tag=%s, version 6.12.111-kvmpatch1)\n", patch_tag);
+
 	if (!kvm_is_svm_supported())
 		return -EOPNOTSUPP;
--- pristine/virt/kvm/kvm_main.c
+++ patched/virt/kvm/kvm_main.c
@@ -71,7 +71,8 @@
 MODULE_AUTHOR("Qumranet");
-MODULE_DESCRIPTION("Kernel-based Virtual Machine (KVM) Hypervisor");
+MODULE_DESCRIPTION("Kernel-based Virtual Machine (KVM) Hypervisor [kvm-patched step1: benign tag]");
+MODULE_VERSION("6.12.111-kvmpatch1");
 MODULE_LICENSE("GPL");
```
(plus `include/trace/.keep`, an empty directory marker, and `dkms.conf`.) The `pr_info` had to go after `__unused_size_checks();` because the kernel build uses `-Werror=declaration-after-statement`.

`dkms.conf`:

```
PACKAGE_NAME="kvm-patched"
PACKAGE_VERSION="1.0"
MAKE[0]="'make' -C /lib/modules/${kernelver}/build M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build/arch/x86/kvm CONFIG_KVM_INTEL=n modules"
CLEAN="'make' -C /lib/modules/${kernelver}/build M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build/arch/x86/kvm clean"
BUILT_MODULE_NAME[0]="kvm"
BUILT_MODULE_LOCATION[0]="arch/x86/kvm"
DEST_MODULE_LOCATION[0]="/updates/dkms"
BUILT_MODULE_NAME[1]="kvm-amd"
BUILT_MODULE_LOCATION[1]="arch/x86/kvm"
DEST_MODULE_LOCATION[1]="/updates/dkms"
AUTOINSTALL="yes"
```

## Step 1 evidence (module proof)

Stock before: `modinfo -F filename kvm` = `.../kernel/arch/x86/kvm/kvm.ko.xz`, no `version` field, description "KVM support for SVM (AMD-V) extensions", `/sys/module/kvm_amd/parameters` had no `patch_tag`, `nested=1 npt=Y avic=N sev=N`, `intree: Y`, signed by the Debian build-time key.

After `dkms install` + `modprobe -r kvm_amd kvm; modprobe kvm_amd`:

```
filename:   /lib/modules/6.12.111+deb13-amd64/updates/dkms/kvm-amd.ko.xz
version:    6.12.111-kvmpatch1
description:KVM support for SVM (AMD-V) extensions [kvm-patched step1: benign tag]
srcversion: E3031DA15010DFCF5E50460          (kvm.ko: 2FCF3A49A37E58C8D6021FD)
depends:    kvm,ccp         vermagic: 6.12.111+deb13-amd64 SMP preempt mod_unload modversions
signer:     DKMS module signing key          (kvm.ko description: "... Hypervisor [kvm-patched step1: benign tag]")
/sys/module/kvm/version = /sys/module/kvm_amd/version = 6.12.111-kvmpatch1
/sys/module/kvm_amd/parameters/patch_tag = step1-benign        nested = 1
dmesg: kvm_amd: out-of-tree patched build loaded (tag=step1-benign, version 6.12.111-kvmpatch1)
       kvm_amd: TSC scaling supported / Nested Virtualization enabled / Nested Paging enabled / LBR virtualization supported / Virtual GIF supported / Virtual NMI enabled
lsmod: kvm_amd 221184  0 ; kvm 1400832  1 kvm_amd      (stock sizes: 221184 / 1396736)
```

Rollback cycle: `dkms uninstall` printed "Restoring archived original module ..." for both; after reload `modinfo` pointed at `kernel/arch/x86/kvm/*.ko.xz` again, `/sys/module/kvm/version` did not exist, `patch_tag` did not exist; `dkms install` and reload brought the patched pair back. During the later Windows run `lsmod` showed `kvm_amd 7 / kvm 7 kvm_amd` (in use by the L2 QEMU), `/proc/<qemu pid>/exe -> /opt/qemu-ad/bin/qemu-system-x86_64`. After the warm reboot the patched modules were loaded by the normal module autoload (boot log shows `kvm: module verification failed ...` followed by the `kvm_amd: out-of-tree patched build loaded` line).

## Step 2: Windows 10 L2 + RTX 4080 under the patched KVM, with `qemu-ad-pve` inside L1

### Does `qemu-ad-pve` run in L1?

Yes. `/opt/qemu-ad` was copied verbatim from the host into L1 (the host copy was only read; `/usr/bin/kvm`, `/opt/qemu-ad`, `/etc/qemu-ad/vms` untouched). `ldd` reports no missing libraries on Debian 13, `--version` = `QEMU emulator version 10.2.2`, and it drives `accel=kvm` with L1's patched KVM. The only difference from the PR #5 L2 launch is that this build has **no `user` network backend** (`network backend 'user' is not compiled into this binary`), so the L2 uses `-netdev tap` + `e1000e` on a private bridge in L1 (isolated, DHCP only). The patch's visible effect inside the guest: Win32_ComputerSystem `ASUS / M4A88TD-M`, BIOS `Debian distribution of EDK II`, `HypervisorPresent True` (as in PR #6 these are the QEMU patch's effects, not the KVM module's).

L2 command line (PR #5 launcher; only the binary, network, `-rtc` and disk selection changed):

```
/opt/qemu-ad/bin/qemu-system-x86_64 -name w10-l2-ad -machine q35,accel=kvm -cpu host -smp 4 -m 6144 -rtc base=localtime \
  -drive if=pflash,format=raw,readonly=on,file=/root/l2/OVMF_CODE.fd -drive if=pflash,format=raw,file=/root/w10/VARS.fd \
  -drive file=<detected NTFS disk>,format=raw,if=none,id=wdisk,cache=none,aio=native,discard=unmap -device ide-hd,drive=wdisk,bus=ide.1,rotation_rate=1 \
  -netdev tap,id=n0,ifname=tapl2,script=no,downscript=no -device e1000e,netdev=n0,mac=<fixed> \
  -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536 -monitor unix:... -qmp unix:... -debugcon file:... -global isa-debugcon.iobase=0x402 \
  -vga std -display none -usb -device usb-tablet -serial none \
  -device pcie-root-port,id=rpg,chassis=11,slot=1 \
  -device vfio-pci,host=0000:02:01.0,bus=rpg,addr=0x0.0x0,multifunction=on -device vfio-pci,host=0000:02:01.1,bus=rpg,addr=0x0.0x1 \
  -pidfile ... -daemonize
```

L1 itself: stock `kvm.pve` (QEMU 11.0.0-4), virtio, `intel-iommu` caching mode, as in PR #4/#5 (the patched QEMU is only used for the L2). The GPU's IOMMU group in L1 was type `DMA` (translated) in all runs.

### Results (all with the patched KVM unless stated)

| Check | Result |
| --- | --- |
| Device state (`w10-code43-check.ps1`), first boot | `ok`/exit 0; RTX 4080 `VEN_10DE&DEV_2704`, PnP `OK`, **`ConfigManagerErrorCode 0`**, driver 32.0.15.7688, `other_code43` empty |
| `nvidia-smi` | 576.88, CUDA 12.9, RTX 4080 WDDM, `00000000:01:00.0`, 16376 MiB, P8 11 W idle |
| After warm L1 reboot | same: `ok`/0, PnP `OK`, **Code 0**, `nvidia-smi` 576.88 |
| Stock-KVM control (same session) | same: `ok`/0, Code 0, `nvidia-smi` 576.88 |
| OpenCL (`pyopencl`, 76 CUs, 16375 MiB), 768 MiB transfer + FMA kernel | PASS in every run (cold, warm, control); see performance table |
| CUDA (CuPy 12.9) 4096^2 fp32 matmul, reduction check | PASS in every run, reduction relative error 5.96e-08 |
| VRAM / BAR | `nvidia-smi -q -d MEMORY`: FB total 16376 MiB; **BAR1 total 16384 MiB** (full resizable BAR visible in the L2, also `lspci` in L1 shows the 16 GiB BAR1 at the L1 level); CUDA free at start 15048 MiB; a pattern-filled allocation of **13.0-13.25 GiB** in 256 MiB chunks succeeded and verified (the remainder fails with CUDA OOM at about 88-90 % of free; this looks like the Windows (WDDM) per-process budget, not a passthrough effect, but I did not compare against 9102 so it is **not** attributed) |
| AI-style workload (CuPy; **PyTorch was not used**, see "Not run") | 3-layer MLP (1024-4096-4096-16, batch 4096, manual backprop, synthetic teacher task) 400 SGD steps: loss 3.10 -> 1.45 (fixed seed), 44.8 / 53.0 / 56.6 steps/s in the first three patched runs, last-batch accuracy 0.51 (chance is 6 %); the later (warm, control) runs' `MLP train` lines were filtered out of my saved output, but their `RESULT: PASS` includes the same loss-halved check; fp16 8192^3 matmul 94-101 TFLOP/s; pageable host<->device 1.4-2.8 GiB/s |
| Sustained load | `sustain.py`: back-to-back fp32 and fp16 4096^2 matmuls (25+25 per batch) with a result check on every batch, `nvidia-smi` sampled every 15 s. **Cold run, patched KVM: 270 s, 1997 batches, mean 50.8 TFLOP/s (first window 51.0, last 50.6), 0 result mismatches**; power 318-320 W (cap 320 W), 65 -> 72 C, SM clock 2520-2595 MHz, GPU util 92-100 %, no throttling visible in the samples. Warm run (after reboot), patched: 120 s, mean 51.0, 0 mismatches. Control, stock KVM: 120 s, mean 50.9, 0 mismatches |
| Host health | Host `IO_PAGE_FAULT`/AER/Xid-type dmesg match count stayed at the baseline **53** throughout (checked before, during the sustained load, after the warm reboot, after the control and at the end). Host dmesg only added `vfio-pci ... resetting / reset done` pairs and the usual `kvm: ignored rdmsr` lines from L1's own vCPUs (not new). L1 dmesg showed no DMAR / IO_PAGE / fault / BUG / oops lines in any run |

### Performance vs baseline

One-shot numbers; the GPU is the same, the guest driver is the same. Sources: PR #5 (stock QEMU 11.0.0 L0, stock Debian QEMU in L1 as L2 binary), PR #6 (patched QEMU as L0 for L1, same L2), and this phase.

| Metric | PR #5 runs A / B | PR #6 | This phase, patched KVM, cold (3 runs) | patched KVM, after warm reboot (3 runs) | **Control: stock KVM, same session (3 runs)** |
| --- | --- | --- | --- | --- | --- |
| OpenCL FMA fp32 (TFLOP/s) | 46.9 / 50.9 | 46.9 | 49.2, 46.9, 47.5 | 47.5, 46.8, 49.7 | 46.9, 46.9, 46.9 |
| CuPy 4096^2 fp32 matmul (TFLOP/s) | 30.6 / 31.0 | 30.5 | 30.8, 30.5, 29.8 | 30.2, 29.5, 30.2 | 30.5, 30.7, 30.5 |
| CuPy fp32 4096^2 / fp16 8192^2 (20 iterations; `ai-test.py`) | n/a | n/a | 32.3 / 101.3, 32.3 / 93.7, 32.2 / 94.6 | 32.4 / 101.2 | 32.3 / 101.0 |
| Sustained mixed matmul (TFLOP/s) | n/a | n/a | 50.8 (270 s) | 51.0 (120 s) | 50.9 (120 s) |

Read: patched-KVM CuPy mean 30.2 vs control mean 30.6 (about -1.3 %, inside the 29.5-30.8 spread of the six patched runs); OpenCL mean 47.9 vs 46.9 (higher, but OpenCL values are quantised by a 2.9 ms timer); sustained 50.8-51.0 vs 50.9 identical; the fp16 8192^2 values in the cold patched session were 101.3, 93.7, 94.6 (so the first run already equalled the control's 101.0), and 101.2 after the reboot: run-to-run variance rather than a stable cost (not investigated further). Conclusion: **no measurable performance cost** from the out-of-tree rebuilt KVM; a rebuild with a no-op patch cannot be expected to change anything, so this mostly shows the toolchain does not degrade it (same Debian config and flags). It says nothing about a future functional patch.

### Warm L1 reboot

Windows shut down with `shutdown /s` (L2 QEMU gone in under 10 s), then `systemctl reboot` in L1 (new boot id, uptime restarted; the L0 QEMU for L1 kept running, as a normal guest reset). After the reboot: patched modules loaded by autoload, both GPU functions back on `vfio-pci` in L1 (group type `DMA`), L2 relaunched (second attempt, see safety note 1), Windows up and reachable within about a minute, GPU **Code 0**, `nvidia-smi` 576.88, OpenCL/CUDA/AI/sustained all PASS, host dmesg count still 53. Whether the physical GPU survives a *cold* L1 boot repeatedly was not tested here beyond the earlier PRs.

## Final state (what was left)

* **L1 default KVM: stock.** The A/B control ended with the DKMS modules uninstalled, so L1 now loads the Debian stock `kvm` / `kvm-amd` at boot. The patched build is still **built** in DKMS (`dkms status`: `kvm-patched/1.0 ... built`); `dkms install -m kvm-patched -v 1.0 -k $(uname -r)` re-enables it. Because `AUTOINSTALL="yes"` a future L1 kernel update would try to build and install it; run `dkms remove -m kvm-patched -v 1.0 --all` to prevent that.
* L1 also keeps: `/usr/src/kvm-patched-1.0`, `/usr/src/kvm-patched-step1.diff`, `/usr/src/kvm-src-dl` (about 300 MB, can be deleted), `/opt/qemu-ad` (464 MB copy), `/root/w10/run-w10-ad.sh`, `l2net-up.sh` / `l2net-down.sh`, `VARS.before-kvmpatch-run.fd`, package `dnsmasq-base` (+2 deps). The Windows disk copy (9200's own `scsi1` volume) has been booted three more times.
* VM 9200 and the L2: stopped cleanly (`qm shutdown 9200`, 2.4 s); no QEMU process for 9200, `w10-l2-ad` or `l2-gpu` left; bridge/tap/dnsmasq in L1 torn down before the shutdown.
* 9200 config: active section equal to the AMD backup except `parent: pre-kvm-module`; new snapshot `pre-kvm-module` kept (the older `pre-gpu` snapshot is untouched).
* Host: GPU on `vfio-pci` (both functions), `IO_PAGE_FAULT`-class dmesg count 53 (baseline), 9102 restarted and verified (`ok`, PnP `OK`, `ConfigManagerErrorCode 0`, `nvidia-smi` 576.88). A stale `/var/run/qemu-server/9200.vnc` socket remains from the raw launches (as in PR #6). New host files only under `/root/gpu-phase-l1/` (`launch-l1-kvmmod.sh`, `kvm/`, `kvmmod-qemu.log`, the config copy and `dmesg-lines-before-kvm`). 9102 was down from about 16:05 to about 16:35 EDT. `qm list` also prints harmless Perl "uninitialized value" warnings for a raw-launched (non-cgroup) 9200 while it runs.

## Rollback (cheapest first)

1. Stock KVM in L1 right now: `modprobe -r kvm_amd kvm; dkms uninstall -m kvm-patched -v 1.0; modprobe kvm_amd` (restores the archived stock files, runs `depmod`; tested twice). Check `modinfo -F filename kvm` shows `.../kernel/arch/x86/kvm/kvm.ko.xz`.
2. Remove the patch from L1 entirely: `dkms remove -m kvm-patched -v 1.0 --all; rm -rf /usr/src/kvm-patched-1.0 /usr/src/kvm-patched-step1.diff /usr/src/kvm-src-dl /opt/qemu-ad`; `apt-get remove dnsmasq-base`.
3. If the stock files themselves are damaged: `apt-get install --reinstall linux-image-6.12.111+deb13-amd64` in L1.
4. Whole L1 back to before this phase (stopped VM): `qm rollback 9200 pre-kvm-module` (**not run**; discards every L1 change above, including the qemu-ad copy), or `qm rollback 9200 pre-gpu` for the older state; then `qm delsnapshot 9200 pre-kvm-module` if the snapshot is no longer wanted.
5. Host: nothing to roll back for the kernel/modules; `rm -rf /root/gpu-phase-l1/kvm /root/gpu-phase-l1/launch-l1-kvmmod.sh /root/gpu-phase-l1/kvmmod-qemu.log` removes the helpers. The Windows disk copy stays as described in PR #5. The break-glass script is not involved and was not run.

## Not run

* **PyTorch**: not used. The L2 has no route out (isolated bridge, no NAT) and a CUDA PyTorch wheel is multi-GB; a CuPy MLP training loop was used instead. No real framework training run, no model download, no cuDNN/tensor-core library benchmark beyond CuPy fp16 matmul.
* No functional (behavioural) KVM patch. No `kvm-intel` build. No test with Secure Boot enabled in L1 or MOK enrolment. No rebase onto a newer L1 kernel (the DKMS tree is pinned to 6.12.111-1).
* No rollback by `qm rollback` (snapshot restore) was exercised; the module-level rollback was.
* No cold-boot repetition, no host-side comparison of the exact 9102 VRAM budget, no 3D/game workload, no display output, no `hypervisor=off`/`kvm=off` variant of the L2 `-cpu`, no run of the 9102-style SMBIOS/`-cpu` argument set, and no timing outside the one-shot and sustained numbers above.
* The aborted ~3-4 s launch against L1's root disk (safety note 1) is the one thing I would flag for review: no filesystem damage was seen, but a write cannot be strictly excluded.
