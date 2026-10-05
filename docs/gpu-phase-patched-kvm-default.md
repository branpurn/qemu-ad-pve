# GPU phase: patched KVM as the permanent L1 default (autoload on every 9200 boot)

Date: 2026-10-05 (test window about 10:04–10:18 EDT). Author: Grok Bot for Brandon (decisions deferred to the 9-9-6 Developer bot: **DEFAULT to patched KVM on VM 9200 always — not opt-in**). Follows [gpu-phase-patched-kvm-l1.md](gpu-phase-patched-kvm-l1.md) (PR #8). Everything below was **run**; what was not run is listed at the end. No credentials, keys, MAC addresses or LAN addresses appear here.

Project intent: keep living **alongside** stock PVE. Patched `kvm` / `kvm-amd` exist only inside nested L1 (9200). Host kernel, modules, packages, GRUB, and QEMU stay stock. Temporary stock fallback on L1 must be documented and reversible; the **default after every reboot of 9200 must be the kvmpatch build with no manual step**.

## Timeline (this run)

| When (EDT) | Event |
| --- | --- |
| 10:04 | Restart began (steering: do default-patched FIRST). 9102 clean shutdown; host dmesg fault pattern count 0 (session baseline). |
| 10:07 | L1 up (raw Intel vIOMMU + GPU launch). Stock KVM was live; DKMS `kvm-patched/1.0` was **built** but not installed (PR #8 left stock). |
| 10:07:43–10:07:53 | `dkms install` + live load of patched modules; `/etc/modules-load.d/kvm-patched.conf` added (`kvm_amd`). |
| 10:08:00 | Warm reboot of L1 issued (**no** `dkms install` / reinstall). |
| **10:09:07** | **DEFAULT_PATCHED_CONFIRMED** after reboot: `/sys/module/kvm{,_amd}/version=6.12.111-kvmpatch1`, modules from `updates/dkms/`, `systemd-modules-load` inserted `kvm_amd`, dmesg `out-of-tree patched build loaded (tag=step1-benign, …)`. |
| 10:09–10:16 | Disk-resolve hardening, one-command start, OpenCL/CuPy/AI/sustain, second warm reboot + L2 relaunch — all under patched default. |
| 10:16–10:18 | Left L1 on patched default; clean L2/L1 shutdown; restored 9200 active AMD config; `qm start 9102`; 4080 Code 0 / nvidia-smi 576.88. |

## Verdict

| Item | Verdict |
| --- | --- |
| Patched KVM permanent default on L1 | **PASS** — `dkms install` to `updates/dkms` + `modules-load.d` + `AUTOINSTALL=yes`; proven by warm reboot without reinstall (twice) |
| Stock temporary fallback documented | **PASS** — steps below; host stays nothing |
| Hardened disk resolve (serial/UUID/label; refuse mounted/ext4) | **PASS** — after warm reboot device names swapped; resolver refused L1 root and picked `ID_SERIAL_SHORT=drive-scsi1` |
| One-command L2 start (`/root/w10/start-l2.sh`) | **PASS** — requires kvmpatch (unless `ALLOW_STOCK_KVM=1`), resolves disk, brings up isolated tap bridge, launches qemu-ad-pve |
| GPU + AI under patched default | **PASS** — Code 0, OpenCL ~47 TFLOP/s, CuPy SGEMM ~30 TFLOP/s, upgraded CuPy MLP+VRAM+BAR PASS, sustained ~51 TFLOP/s |
| Perf vs PR #5/#8 baselines | **No measurable cost** (within noise) |
| Leave L1 default = patched (unlike PR #8) | **Done** |
| Host PVE stock; 9102 restored | **Done** |

## How the permanent default works (L1 only)

1. **DKMS install** places `kvm.ko.xz` and `kvm-amd.ko.xz` in `/lib/modules/$(uname -r)/updates/dkms/`. `depmod` prefers that path over stock `kernel/arch/x86/kvm/`.
2. **`AUTOINSTALL="yes"`** in `/usr/src/kvm-patched-1.0/dkms.conf` (already set in PR #8) rebuilds/installs on L1 kernel package updates via `/etc/kernel/postinst.d/dkms`. After a kernel upgrade you still must rebase the source tree on the matching `linux-source-6.12` (same caveat as PR #8).
3. **`/etc/modules-load.d/kvm-patched.conf`** contains `kvm_amd` so `systemd-modules-load` loads the patched stack at every boot (pulls `kvm`). Evidence from the proof reboot: `systemd-modules-load[…]: Inserted module 'kvm_amd'` and dmesg at ~3.8 s shows the kvmpatch `pr_info`.
4. **Secure Boot** remains off in L1 (Setup Mode); modules are DKMS-signed but the key is not enrolled — same as PR #8.

Proof commands after any L1 reboot (no reinstall):

```bash
cat /sys/module/kvm/version /sys/module/kvm_amd/version   # expect 6.12.111-kvmpatch1
modinfo -F filename kvm kvm_amd                           # expect .../updates/dkms/...
cat /sys/module/kvm_amd/parameters/patch_tag               # step1-benign
dmesg | grep 'out-of-tree patched'
```

## Temporary stock fallback (then re-enable patched default)

| Step | What changes in L1 | Host | Rollback / notes |
| --- | --- | --- | --- |
| A. Stop all L2 QEMU using KVM | none (process exit) | none | required before `modprobe -r` |
| B. Soft unload patched: `modprobe -r kvm_amd kvm` | modules unloaded | none | cannot unload while QEMU holds `/dev/kvm` |
| C. `dkms uninstall -m kvm-patched -v 1.0 -k $(uname -r)` | removes `updates/dkms/kvm*.ko.xz`, restores archived stock into the module search path, `depmod` | none | stock `.ko.xz` under `kernel/arch/x86/kvm/` were never deleted |
| D. Optional: `mv /etc/modules-load.d/kvm-patched.conf{,.disabled}` | boot will not force-load kvm | none | leave in place if you still want kvm autoload (stock files will load) |
| E. `modprobe kvm_amd` **or reboot** | stock modules live (`/sys/module/kvm/version` absent / empty; no `patch_tag`) | none | verify `modinfo -F filename` points at `kernel/arch/x86/kvm/` |
| F. Re-enable default: restore `kvm-patched.conf` if moved; `dkms install -m kvm-patched -v 1.0 -k $(uname -r)`; `modprobe -r kvm_amd kvm`; `modprobe kvm_amd` **or reboot** | patched again in `updates/dkms`, version `…-kvmpatch1` | none | this is the permanent path |

Do **not** change anything on the host for fallback. Host PVE KVM remains stock throughout.

## Hardened disk resolve + one-command start

Device names inside L1 are **not** stable across warm reboots (PR #8 safety incident: L2 briefly had L1 root as raw disk). Scripts installed on L1 (also in this repo under `scripts/l1-w10/`):

| Script | Role |
| --- | --- |
| `/root/w10/resolve-windows-disk.sh` | Score candidates by `ID_SERIAL_SHORT=drive-scsi1`, NTFS UUID/label `Windows`, size~80G+ntfs. **Refuse** any disk with a mountpoint, any ext4 partition, or that hosts `/`. Fail closed on zero/ambiguous matches. Prints the chosen `/dev/sdX` on stdout. |
| `/root/w10/start-l2.sh` | One-command start: require kvmpatch (override `ALLOW_STOCK_KVM=1`), resolve disk, `l2net-up.sh`, launch `/opt/qemu-ad/bin/qemu-system-x86_64` (fallback to Debian QEMU only if qemu-ad missing), tap+e1000e on isolated `brl2`, `-rtc base=localtime`, both GPU functions on a pcie-root-port. |
| `/root/w10/run-w10-ad.sh` | Compat wrapper → `start-l2.sh`. |

Evidence this run:

- First launch: refused `/dev/sda` (L1 root mounted/ext4); resolved `/dev/sdb` score=200 (`serial=drive-scsi1 uuid=… label=Windows ntfs+size=…`).
- After warm reboot names **swapped**; relaunch refused `/dev/sdb` (now root) and resolved `/dev/sda` still via `drive-scsi1`. L2 came up Code 0.

## GPU / AI results under patched default

| Check | Result | vs PR #5/#8 baseline |
| --- | --- | --- |
| PnP / nvidia-smi | Code 0, driver 576.88, Display OK | same |
| OpenCL FMA (×3) | ~46.9–47.2 TFLOP/s | baseline ~47–51; within noise / slight low end |
| CuPy SGEMM 4096³ (×3) | ~30.1–30.5 TFLOP/s | baseline ~31 |
| Upgraded CuPy AI (matmul + VRAM 13.25 GiB + BAR1 16 GiB + MLP 400 steps) | PASS (fp32 32.4 TFLOP/s, fp16 101.3, loss 3.10→1.45) | same ballpark as PR #8 |
| Sustained 150 s fp32+fp16 mix | mean **50.9** TFLOP/s, 0 mismatches | baseline ~51 |
| Warm L1 reboot + one-command L2 relaunch | patched still default; OpenCL ~46.9, SGEMM 30.1, Code 0 | same |

### Why not PyTorch offline

L2 has Python 3.12 + CuPy 14.2 + PyOpenCL; **no `torch` and no local `.whl`**. Upstream Windows+CUDA wheels are ~2.4–2.5 GiB each; matching `cp312` wheels were not already staged on the host/L1/L2. Copying multi-GB wheels through the nested path for this session was deferred. Documented alternative used: upgraded CuPy path (matmul, VRAM/BAR, short MLP training loop) plus OpenCL and sustained load — all PASS.

## What was run (step table)

| # | Step | L1 changes | Host changes | Rollback |
| --- | --- | --- | --- | --- |
| 1 | `qm shutdown 9102` | none | 9102 stopped; GPU on vfio-pci | `qm start 9102` (done) |
| 2 | Raw launch L1 (`launch-l1-kvmmod.sh`: intel-iommu, GPU behind pcie-pci-bridge, 12 GiB) | none | one QEMU process for 9200; config **not** used for launch (`qm start` still wrong topology) | clean poweroff of L1 QEMU (done) |
| 3 | `dkms install -m kvm-patched -v 1.0`; load patched; add `modules-load.d/kvm-patched.conf` | modules in `updates/dkms`; autoload conf | **none** | see stock fallback table |
| 4 | Warm reboot L1; verify kvmpatch without reinstall | none new | L0 QEMU stayed up | n/a |
| 5 | Install resolve + `start-l2.sh`; launch L2; GPU/AI/sustain | scripts under `/root/w10/`; Windows disk writes; VARS | GPU via vfio in L1 | L2 shutdown |
| 6 | Second warm reboot; one-command relaunch; re-verify | proves swap-safe resolve + default-patched | none beyond guest reset | n/a |
| 7 | Leave patched installed; poweroff L1; restore 9200 **active** AMD args from backup; start 9102 | L1 disk retains DKMS install + modules-load + scripts | active conf restored (diff vs AMD backup active: empty); 9102 up | n/a |

## Final state

| Item | State |
| --- | --- |
| L1 (9200) | **Stopped**. Next boot (via raw launch script) will autoload **patched** kvm/kvm-amd (`6.12.111-kvmpatch1`) from `updates/dkms` via `modules-load.d`. DKMS status: `kvm-patched/1.0 … installed`. Scripts: `/root/w10/start-l2.sh`, `resolve-windows-disk.sh`. |
| Host | Stock PVE KVM/QEMU/kernel. No apt. No module/GRUB changes. 9200 active config = AMD backup (empty active diff). Snapshot sections may remain (`pre-gpu` / `pre-kvm-module`). |
| 9102 | **Running**; RTX 4080 Code 0, nvidia-smi 576.88, Display OK. GPU driver on host: `vfio-pci`. |
| Host dmesg | Session start fault-pattern count 0; end 0. dmesg lines ~3048 → ~3075. |
| Leftovers | Host helpers under `/root/gpu-phase-l1/` (unchanged role). Possible stale `/var/run/qemu-server/9200.vnc` socket file (no process). L1 still holds `/usr/src/kvm-src-dl`, `/usr/src/kvm-patched-1.0`, `/opt/qemu-ad`, nvidia DKMS (from earlier phases). |

## What was not run

- Cold power cycle of the bare-metal host (forbidden).
- Host apt / kernel / GRUB / modprobe changes (forbidden).
- Enrolling DKMS MOK / enabling L1 Secure Boot.
- Downloading/installing a multi-GB PyTorch wheel into L2.
- `qm start 9200` for the GPU topology (still requires the raw launch script; Intel vIOMMU path).
- Functional (non-benign) KVM behavioural patches.
- Touching VMs 100/110/115/200/245/500/9000/9101 or the T400; `/root/qemu-ad-breakglass.sh` not run.

## Related

- [gpu-phase-patched-kvm-l1.md](gpu-phase-patched-kvm-l1.md) — build of the benign kvmpatch DKMS package
- [gpu-phase-windows-l2.md](gpu-phase-windows-l2.md) — Windows L2 + 4080 baselines
- [gpu-phase-intel-viommu.md](gpu-phase-intel-viommu.md) — why raw launch + pcie-pci-bridge
- Repo scripts: `scripts/l1-w10/resolve-windows-disk.sh`, `scripts/l1-w10/start-l2.sh`, `scripts/l1-w10/ai-test-upgraded.py`
