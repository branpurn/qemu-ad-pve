# GPU phase: VM 9200 started and stopped by plain `qm start` / `qm shutdown` (qm-native config)

Date: 2026-10-05, test window 16:34–16:51 EDT. Author: Grok Bot for Brandon (decisions deferred to the
9-9-6 Developer bot). Follows [gpu-phase-gen-launch-e2e.md](gpu-phase-gen-launch-e2e.md) (PR #21).
Everything below was **run** unless listed under "Not run". No credentials or keys appear here.

Goal: VM 9200 lives in the PVE GUI and is driven by plain `qm start 9200` / `qm shutdown 9200`,
with the working topology (Intel vIOMMU, `kernel-irqchip=split`, both RTX 4080 functions behind a
`pcie-pci-bridge`, `X-PciMmio64Mb=65536`), and the Windows L2 comes up by itself inside L1 and is shut
down cleanly when L1 gets the ACPI power button.

## Verdict

| Item | Verdict |
| --- | --- |
| Plain `qm start 9200` builds the working topology | **PASS** — no raw launch script. `machine: q35,viommu=intel` + `args:` with the bridge and both GPU functions, `hostpci0` removed. Live QEMU argv == `qm showcmd 9200`; same 92 tokens as the proven gen-launch script (only the two vfio device ids differ: `gpu-vga`/`gpu-audio` instead of `hostpci0.0/.1`) |
| No `group 13 used in multiple address spaces` | **PASS** — both functions sit behind the conventional-PCI bridge, so the vIOMMU gives them one address space (L1: `02:01.0`/`02:01.1`, one IOMMU group 11) |
| L1 autostarts the Windows L2 (systemd `w10-l2.service` -> `start-l2.sh`, patched-KVM check kept) | **PASS** ×3 boots (unit active ~10 s after L1 boot, L2 sshd up 10–20 s later) |
| L2 GPU | **PASS** every cycle — RTX 4080 + both audio functions `ConfigManagerErrorCode 0`, nvidia-smi 576.88, 16376 MiB, BAR1 16384 MiB |
| CuPy SGEMM 4096³ | **PASS** every cycle — 28.7–30.8 TFLOP/s (table below) |
| Plain `qm shutdown 9200` graceful end to end | **PASS** ×4 — PVE ACPI power button -> L1 logind "Power key pressed" -> unit ExecStop sends ACPI power-down to L2 -> Windows logs 1074 + 6006 (clean), no 41/6008 -> L2 QEMU exits in 9–14 s -> L1 powers off; `qm shutdown` rc 0 in 11–17 s |
| Repeat twice | **PASS** — two full verification cycles (1, 2), plus the install cycle (0) and a confirmation cycle (3) that also read cycle 2's shutdown evidence |
| Guard: `qm start 9102` while 9200 holds the GPU | **refused** by qemu-server: `PCI device '0000:02:00.0' already in use by VMID '9200'` (hookscript reservation); no GPU reset happened |
| L1 still patched-KVM default | **PASS** every boot — `kvm`/`kvm_amd` `6.12.111-kvmpatch1` from `updates/dkms`, `patch_tag=step1-benign` |
| Host | stock: kernel 7.0.12-1-pve, no reboot (up 46 days), no apt, `/usr/bin/kvm` wrapper and `/opt/qemu-ad` unchanged (mtimes 2026-10-01); dmesg fault-pattern count 53 -> 53, broad 235 -> 235 |
| 9102 afterwards | **PASS** — running, GPU + audio Code 0, nvidia-smi 576.88, 16376 MiB |
| Final 9200 state | **left in the new qm-native config by design** (verification passed twice; rollback below). Stopped. |

## 1. Host changes (all scoped to 9200) and rollback

Exactly two host artefacts changed. Nothing under `/usr`, no package, kernel, GRUB, modprobe or
module change, no `storage.cfg` change (the `iso_images` storage already had `snippets` content).

| # | Change | Host impact | Rollback |
| --- | --- | --- | --- |
| 0 | Backup `/root/gpu-phase-l1/9200.conf.pre-qm-native-20261005163444`; snapshot `qm snapshot 9200 pre-qm-native` (efidisk0 + scsi0) and `qemu-img snapshot -c pre-qm-native .../vm-9200-disk-2.qcow2` (Windows disk; it was not yet in the config, so `qm snapshot` could not cover it) | internal qcow2 snapshots on 9200's own volumes only | see "Full rollback" |
| 1 | `/etc/pve/qemu-server/9200.conf` active section (diff below) | VM 9200 only | "Config-only rollback" below |
| 2 | New hookscript `/zfs_pool/iso_images/snippets/9200-gpu-guard.pl` = volume `iso_images:snippets/9200-gpu-guard.pl` (0755, sha256 `22cbb9a6…7c61539`), referenced only by 9200 | runs only on 9200's start/stop; writes/removes 9200's entries in `/run/qemu-server/pci-id-reservations` via qemu-server's own functions | `qm set 9200 --delete hookscript && rm /zfs_pool/iso_images/snippets/9200-gpu-guard.pl` |

### Config diff (active section only; snapshot sections untouched)

```
-args: -machine kernel-irqchip=split -device amd-iommu,intremap=on,xtsup=on,dma-remap=on
+args: -device pcie-pci-bridge,id=gpubr,bus=ich9-pcie-port-1,addr=0x0 -device vfio-pci,host=0000:02:00.0,id=gpu-vga,bus=gpubr,addr=0x1.0,multifunction=on -device vfio-pci,host=0000:02:00.1,id=gpu-audio,bus=gpubr,addr=0x1.1 -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536
-hostpci0: 0000:02:00,pcie=1
+hookscript: iso_images:snippets/9200-gpu-guard.pl
-machine: q35
-memory: 6144
+machine: q35,viommu=intel
+memory: 12288
-parent: pre-gpu
+parent: pre-qm-native
+scsi1: fast_storage:9200/vm-9200-disk-2.qcow2,discard=on,size=80G
+startup: down=240
```

Applied with one command (as root on the host):

```
qm set 9200 --delete hostpci0 --machine q35,viommu=intel --memory 12288 \
  --scsi1 fast_storage:9200/vm-9200-disk-2.qcow2,discard=on --startup down=240 \
  --hookscript iso_images:snippets/9200-gpu-guard.pl \
  --args '-device pcie-pci-bridge,id=gpubr,bus=ich9-pcie-port-1,addr=0x0 -device vfio-pci,host=0000:02:00.0,id=gpu-vga,bus=gpubr,addr=0x1.0,multifunction=on -device vfio-pci,host=0000:02:00.1,id=gpu-audio,bus=gpubr,addr=0x1.1 -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536'
```

Full final active section: [`samples/qm-native-9200/9200.conf.active-final`](../samples/qm-native-9200/9200.conf.active-final).

Why each line:

* `machine: q35,viommu=intel` — qemu-server itself emits `-device intel-iommu,intremap=on,caching-mode=on`
  **before** all other devices and adds `kernel-irqchip=split` to `-machine` (QemuServer.pm, viommu
  branch). So no `-machine`/`intel-iommu` in `args:` is needed, and the vIOMMU is realized before the
  vfio devices that `args:` appends at the end of the command line.
* `args:` — the only thing qm cannot express: a `pcie-pci-bridge` on the existing root port
  `ich9-pcie-port-1` (defined by `/usr/share/qemu-server/pve-q35-4.0.cfg`, so it exists without any
  `hostpci`) with both GPU functions behind it, plus the 64 GiB OVMF MMIO window (`X-PciMmio64Mb`).
* `hostpci0` removed — with hostpci both functions land directly on the root port, i.e. two vIOMMU
  address spaces for one host IOMMU group -> `group 13 used in multiple address spaces`.
* `memory: 12288`, `scsi1` (Windows disk) — what the proven Intel runs used (L2 gets 6 GiB; the
  disk is passed by L1 to L2 via `resolve-windows-disk.sh`).
* `startup: down=240` — qemu-server's default `qm shutdown` wait is 60 s; this raises it for 9200
  (also used by host bulk shutdown). Observed shutdowns took 11–17 s.
* `hookscript:` — see next section.

### Why a hookscript, and what it does not do

A hookscript **cannot** rewrite the QEMU command line: `vm_start` loads the config, runs `pre-start`
on that in-memory copy, then calls `config_to_command` on the same copy. The args-only config was
sufficient for the topology, so the hook is not needed for that.

It is needed for safety: qemu-server only reserves PCI devices listed in `hostpci*`. With the GPU in
`args:`, nothing would stop `qm start 9102` (`hostpci0: 0000:02:00`) while 9200 runs, and 9102's
start path (`prepare_pci_device`) would re-bind and **FLR-reset the GPU under the running L1/L2**.
[`9200-gpu-guard.pl`](../scripts/qm-native-9200/9200-gpu-guard.pl) uses qemu-server's own
`PVE::QemuServer::PCI::reserve_pci_usage` / `remove_pci_reservation`:

* `pre-start`: refuse unless 02:00.0/.1 are on `vfio-pci`; time-reserve both ids for 9200 (dies —
  aborting `qm start 9200` — if 9102 holds them). Tested while 9102 ran:
  `PCI device '0000:02:00.0' already in use by VMID '9102'`, rc 25.
* `post-start`: re-reserve with the real QEMU pid (what qemu-server does for hostpci).
* `post-stop`: release. Observed in every `qm shutdown`: `9200-gpu-guard: released ...`.

Caveat: if `qm start 9200` fails after `pre-start`, the time reservation blocks 9102 for up to ~95 s.

### Full rollback (config + L1 disk + Windows disk to the pre-session state)

```
qm shutdown 9200            # if running
qm rollback 9200 pre-qm-native        # active config -> AMD config, disk-0/disk-1 -> snapshot
qemu-img snapshot -a pre-qm-native /mnt/fast_storage/images/9200/vm-9200-disk-2.qcow2
rm /zfs_pool/iso_images/snippets/9200-gpu-guard.pl
```

Note `qm rollback` leaves the active config equal to the snapshot (AMD) config, i.e. without `scsi1`.
Clean-up of the internal snapshots when no longer wanted: `qm delsnapshot 9200 pre-qm-native` **and**
`qemu-img snapshot -d pre-qm-native .../vm-9200-disk-2.qcow2` (PVE does not know about the disk-2
one because disk-2 was not in the snapshot's config).

### Config-only rollback (keep the L1 unit; restore the AMD active section; keep snapshots)

Do **not** use `qm set 9200 --delete scsi1` followed by `--delete unused0`: on dir storage the second
step destroys the Windows disk. Replace the active section instead (dry-run of this exact pipeline
produced an active section identical to the backup except `parent: pre-qm-native`):

```
B=/root/gpu-phase-l1/9200.conf.pre-qm-native-20261005163444; C=/etc/pve/qemu-server/9200.conf
cp -p $C /root/gpu-phase-l1/9200.conf.before-rollback-$(date +%Y%m%d%H%M%S)
{ sed -n '1,/^$/p' $B | sed 's/^parent: .*/parent: pre-qm-native/'; sed -n '/^\[/,$p' $C; } > /tmp/9200.conf.new
cp /tmp/9200.conf.new $C
rm /zfs_pool/iso_images/snippets/9200-gpu-guard.pl
```

With the AMD config the L1 sees the GPU at a different address, so `w10-l2.service` is skipped by its
`ConditionPathExists=/sys/bus/pci/devices/0000:02:01.0` (no failed unit).

## 2. L1 systemd unit (inside VM 9200, Debian 13)

Files (installed in cycle 0, kept on the L1 disk):

* `/etc/systemd/system/w10-l2.service` — [`scripts/qm-native-9200/w10-l2.service`](../scripts/qm-native-9200/w10-l2.service), `enabled` (multi-user.target)
* `/root/w10/l2-service.sh` — [`scripts/qm-native-9200/l2-service.sh`](../scripts/qm-native-9200/l2-service.sh) (pre / stop / post helper; logs to `/root/w10/l2-service.log` and the journal)
* unchanged: `/root/w10/start-l2.sh` (patched-KVM check: refuses with exit 80/81 unless `kvm` is
  `*kvmpatch*` from `updates/dkms`), `resolve-windows-disk.sh`, `l2net-up/down.sh`

```ini
[Unit]
Description=Windows L2 guest (qemu-ad-pve, RTX 4080 passthrough) via /root/w10/start-l2.sh
Documentation=https://github.com/branpurn/qemu-ad-pve/blob/main/docs/gpu-phase-qm-native-9200.md
After=network-online.target systemd-modules-load.service local-fs.target
Wants=network-online.target
ConditionPathExists=/root/w10/start-l2.sh
ConditionPathExists=/sys/bus/pci/devices/0000:02:01.0

[Service]
Type=forking
PIDFile=/root/w10/w10.pid
ExecStartPre=/root/w10/l2-service.sh pre
ExecStart=/root/w10/start-l2.sh
ExecStop=/root/w10/l2-service.sh stop
ExecStopPost=/root/w10/l2-service.sh post
TimeoutStartSec=180
TimeoutStopSec=180
Restart=no

[Install]
WantedBy=multi-user.target
```

* `pre` waits (≤ 60 s) until 02:01.0/.1 are on `vfio-pci`.
* `start-l2.sh` daemonizes the qemu-ad L2 QEMU; `Type=forking` + `PIDFile` track it.
* `stop` sends QMP `system_powerdown` (ACPI power button) to the L2 and waits up to 150 s for the
  QEMU to exit; only if Windows ignores it: QMP `quit`, then SIGKILL, both logged as **NOT graceful**
  (never needed in this run).
* `post` tears down `brl2`/`tapl2`.
* Chain on `qm shutdown 9200`: qemu-server QMP `system_powerdown` (agent is off) -> L1 logind
  `HandlePowerKey=poweroff` (default) -> `poweroff.target` stops `w10-l2.service` first
  (TimeoutStopSec 180 < `startup: down=240`) -> L1 powers off -> qmeventd cleans up -> `post-stop` hook.

## 3. Verify log (two required cycles + install and confirmation cycles)

All times EDT (L1 journal and Windows clock are UTC; converted).

| Cycle | `qm start` | L2 unit active | L2 Code 0 / nvidia-smi | CuPy SGEMM 4096³ (2 runs) | `qm shutdown` (plain, no options) | L2 graceful? |
| --- | --- | --- | --- | --- | --- | --- |
| 0 install | 16:36:11, rc 0 (2.4 s) | 16:41:54 (unit installed + `systemctl start` by hand) | 3× Code 0 / 576.88, 16376 MiB, BAR1 16384 | 29.7 / 30.8 TFLOP/s PASS | 16:43:10 -> rc 0 after 17 s | yes: Power key 16:43:10, `L2 exited cleanly after 14s`; Windows 1074 16:43:10 + 6006 16:43:16 |
| **1** | 16:43:46, rc 0 | 16:44:05 (autostart; L1 boot 16:43:55) | 3× Code 0 / 576.88 | 30.1 / 29.2 PASS | 16:45:25 -> rc 0 after 15 s | yes: `exited cleanly after 13s`; Windows 1074 16:45:24 + 6006 16:45:30 |
| **2** | 16:45:45, rc 0 | 16:46:05 (autostart) | 3× Code 0 / 576.88 | 30.1 / 30.3 PASS | 16:47:19 -> rc 0 after 11 s | yes: `exited cleanly after 9s`; Windows 1074 16:47:19 + 6006 16:47:25 (read at cycle 3 boot) |
| 3 confirm | 16:47:36, rc 0 | 16:47:55 (autostart) | 3× Code 0 / 576.88 | 30.2 / 28.7 PASS | 16:49:01 -> rc 0 after 14 s | serial console: `Stopped w10-l2.service` after ~10 s, then `poweroff.target` (Windows side not re-read: needs another boot) |

No Windows event 41 (Kernel-Power) or 6008 (unexpected shutdown) appeared in any boot's recent
System log. CuPy reference from PR #21: 30.0 / 29.9 TFLOP/s.

Excerpt (cycle 1 boot reading cycle 0's shutdown, `journalctl -b -1`, UTC):

```
20:43:10 systemd-logind: Power key pressed short.
20:43:11 systemd-logind: System is powering down.
20:43:11 systemd: Stopping w10-l2.service - Windows L2 guest ...
20:43:11 l2-service.sh: stop: ACPI system_powerdown -> L2 pid=1596
20:43:25 l2-service.sh: stop: L2 exited cleanly after 14s
20:43:25 l2-service.sh: post: L2 network torn down; qemu=0
20:43:25 systemd: Stopped w10-l2.service - Windows L2 guest ...
```

Autostart (cycle 1, UTC): `pre: GPU 02:01.0/.1 on vfio-pci (waited 1s); kvm=6.12.111-kvmpatch1` ->
`kvm ok: version=6.12.111-kvmpatch1 file=.../updates/dkms/kvm.ko.xz patch_tag=step1-benign` ->
`REFUSE /dev/sda: has mounted partition(s)` -> `RESOLVED Windows disk=/dev/sdb score=200 (serial=drive-scsi1 ...)`
-> `Started w10-l2.service`.

L1 topology (cycle 0): `DMAR-IR: Enabled IRQ remapping in x2apic mode`; `01:00.0 PCI bridge [1b36:000e]`;
`02:01.0` RTX 4080 / `02:01.1` audio, `vfio-pci`, group 11; BAR1 `1000000000 [size=16G]`.

Raw logs: [`samples/qm-native-9200/`](../samples/qm-native-9200/) (`cN-qmstart.log`, `cN-verify.log`,
`cN-shutdown.log`, `c0-install.log`, `qm-showcmd-pretty.txt`, `c0-live-argv.txt`). Host helpers used:
`qrun.sh` (copy + run a script as root in L1), `verify-l2.sh`, `shut.sh` (plain `qm shutdown 9200` with
serial-console capture). `verify-l2.sh` copies the L2 ssh key into L1 for the check and deletes it
afterwards; the host copy was deleted at the end.

### Host checks

| Check | Result |
| --- | --- |
| dmesg | 3112 -> 3158 lines; new lines only `vfio-pci 0000:02:00.x: resetting / reset done`, `kvm: ignored rdmsr/wrmsr`, `tap9200i0: entered promiscuous mode` |
| fault-pattern (`DMAR.*fault|IO_PAGE_FAULT|AER|Xid|BUG|oops`) | 53 -> 53 (all from 2026-10-02 AMD-vIOMMU runs) |
| broad (`fault|BUG|oops|error`) | 235 -> 235 |
| GPU after each shutdown | both functions `vfio-pci`; 9200 reservation removed |
| L1 dmesg | one `Call Trace` at 0.138 s in every boot = `unchecked MSR access error: RDMSR from 0x852` in `mce_amd_feature_init` (AMD MCE init vs. x2APIC; present in all earlier boots too). No DMAR fault / AER error / Oops |

### 9102 (restored at the end)

`qm shutdown 9102 --timeout 180` at 16:35:57 (clean, 8 s) before the first 9200 start.
`qm start 9102` at 16:49:23 (wrapper: `vmid=9102 exec /opt/qemu-ad/bin/qemu-system-x86_64`); at 16:50:59
EDT: RTX 4080, NVIDIA HDA and HDA controller `Status OK, Code 0`; `NVIDIA GeForce RTX 4080, 576.88, 16376 MiB`.

## 4. Operating notes

* Start/stop: `qm start 9200`, `qm shutdown 9200` (or the GUI Start / Shutdown buttons, which call the
  same API — not clicked in this run). Stop 9102 first; the guard refuses otherwise, with a clear message.
* `qm stop 9200` is PVE's **hard** stop (QMP `quit`): it pulls the plug on L1 and the Windows L2; the L1
  unit cannot intercept it. Use `qm shutdown`. (A `pre-stop` hook could make `qm stop` graceful too,
  but that changes PVE's stop semantics; not done.)
* The GPU is not shown under 9200 → Hardware in the GUI (it is in `args:`, which is CLI-only). Editing
  other 9200 options in the GUI is expected to keep `args:` (qemu-server rewrites the whole config), but
  that was not tested here; re-check `qm config 9200 | grep ^args` after GUI edits.
* `qm start` printed `generating cloud-init ISO` each time (config changed); harmless here.
* The prior raw/gen-launch paths still work but are no longer needed for 9200.

## Leftovers

* Host: `/root/gpu-phase-l1/qmnative/` (logs, showcmd, live argv, `qrun.sh`, `verify-l2.sh`, `shut.sh`,
  `c0-install.sh`, `l1dmesg.sh`, copies of the unit/helper), `9200.conf.pre-qm-native-20261005163444`,
  snapshot `pre-qm-native` (qm) + `pre-qm-native` internal snapshot on disk-2, the hookscript (in use).
* L1: `w10-l2.service` (enabled), `/root/w10/l2-service.sh`, `/root/w10/l2-service.log` (in use).
* `qrun.sh` in the samples is the fixed version (tries every neighbour entry for the L1 MAC); the run
  itself used an earlier version that picked a stale lease first, which cost ~5 min in cycle 0 and was
  resolved by re-running once the stale entry expired.

## Not run

* GUI Start/Shutdown buttons (same API path as `qm`).
* `qm stop 9200` (hard stop; deliberately not exercised with the Windows L2 running).
* Reading Windows' shutdown events for cycle 3 (would need a 5th boot).
* PyTorch in this session (CuPy only, as requested).
* Host reboot / apt / kernel / GRUB / module / modprobe changes; edits under `/usr` or `/opt/qemu-ad`;
  `storage.cfg`; breakglass; any VM other than 9102 (clean shutdown/start) and 9200.
