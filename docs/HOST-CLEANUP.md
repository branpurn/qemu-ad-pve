# Host cleanup: leftovers from the lab phases (documentation only)

> **Nothing in this file has been executed.** It lists what the earlier lab work (Oct 1-5, 2026) left on the
> PVE host, what still depends on each item, and the exact commands to remove it and to undo the removal.
> Sources: [qa-live-20261005.md](qa-live-20261005.md) (read-only host audit) and the phase docs linked per item.
> Facts can drift: **run the "check first" commands on the host before anything else**, and take a backup
> (`vzdump`, or a copy of the file/dir) before every step marked *irreversible*.
> `./qemu-ad-pve.sh` commands run as root from the repo checkout on the host.
> `./setup.sh` does not need any of these items, except that `l1.qemu_ad=copy` (and `auto`, when present) reads
> the host's `/opt/qemu-ad`.

## Summary: who depends on what

| # | Item | Size | Used by (as of 2026-10-05) | 9200 depends on it? | Removable now? |
|---|------|------|----------------------------|---------------------|----------------|
| 1 | `/usr/bin/kvm` diversion + qemu-ad wrapper | - | **VMs 9101, 9102** (listed in `/etc/qemu-ad/vms`); every other VM passes through it to stock `kvm.pve` | **No** (9200 is not listed: it runs stock PVE QEMU 11.0.0-4 via the fall-through) | Only once 9101/9102 may lose anti-detection |
| 2 | Host `/opt/qemu-ad` (QEMU 10.2.2 side build) | 464 MiB | **VMs 9101, 9102** (through #1); source for `setup.sh l1.qemu_ad=copy` | **No** at runtime: 9200's L2 uses the copy **inside L1** (`/opt/qemu-ad` in L1, copied Oct 3) | Only together with/after #1 |
| 3 | `/opt/qemu-11.0.3` | 414 MiB | nothing ("not installed, not used by any VM at rest") | No | Yes |
| 4 | `/opt/src` (QEMU sources) | ~2.6 GiB | nothing at runtime (build input for #2) | No | Yes |
| 5 | Oct 1 apt build dependencies | ~0.5-1 GiB | building #2; their *runtime* libs are needed by #2 | No | Yes, carefully (keep runtime libs while #2 exists) |
| 6 | 80 GiB Windows qcow2 `fast_storage:9200/vm-9200-disk-2.qcow2` | 80 GiB virtual, ~37 GiB allocated | **VM 9200** (`scsi1` = the Windows L2 disk) | **Yes** | **No** (only if 9200's L2 is retired) |
| 7 | 9200 snapshots `pre-gpu`, `pre-kvm-module`, `pre-qm-native` | qcow2-internal | rollback points only | No (not needed to run) | Yes, *irreversible* |
| 8 | VM 9000 spike leftovers (nested VM 9150, `/root/viommu-spike`, `vmbr150`, 11.0.3 upgrade inside 9000) | ~1.6 GiB inside 9000 | VM 9000 itself is the tier-2 test node (`docs/nested-test-node` PR #16) | No | Yes (inside 9000) |
| - | Keep: `/etc/modprobe.d/vfio.conf`, hookscript `iso_images:snippets/9200-gpu-guard.pl` | - | GPU vfio binding (9102, 9200); the 9200 guard | **Yes** (both) | **No** |
| - | Optional: `/root/gpu-phase-l1/` | 2.5 GiB | holds 9200 conf backups, `l1key` (SSH to 9200's L1), the torch wheel, phase logs | key + backups: yes | Archive first |

## 1. `/usr/bin/kvm` diversion and wrapper

* **What / why:** `./qemu-ad-pve.sh install` diverted the vendor binary (`dpkg-divert --local --no-rename`,
  `/usr/bin/kvm` → `/usr/bin/kvm.pve`) and put a wrapper at `/usr/bin/kvm` that execs `/opt/qemu-ad` for the VMIDs
  in `/etc/qemu-ad/vms` (currently `9101`, `9102`) and `kvm.pve` for everyone else. It is in the exec path of
  **every** VM on the host; the wrapper logs to `/var/log/qemu-ad-wrapper.log`.
* **Depends on it:** 9101 and 9102 (anti-detection QEMU). **Not 9200** (fall-through to stock QEMU).
* **Check first:**
  ```bash
  dpkg-divert --list /usr/bin/kvm
  cat /etc/qemu-ad/vms
  ./qemu-ad-pve.sh status
  qm list | awk '$1==9101||$1==9102'
  ```
* **Remove** (keeps `/opt/qemu-ad` and the VMID list; refuses while the dpkg lock is held):
  ```bash
  ./qemu-ad-pve.sh uninstall
  dpkg-divert --list /usr/bin/kvm          # expect no output
  ```
  Running VMs keep their current QEMU process; **9101/9102 start on stock QEMU from their next start**
  (anti-detection lost). Never `apt remove pve-qemu-kvm` while the diversion exists (README recovery:
  `apt install --reinstall pve-qemu-kvm`, then `./qemu-ad-pve.sh uninstall`).
* **Rollback:** `./qemu-ad-pve.sh install` (re-uses the existing `/opt/qemu-ad` build if its configure stamp
  matches; the VMID list is kept by plain `uninstall`).

## 2. Host `/opt/qemu-ad` (side QEMU 10.2.2)

* **What / why:** the patched QEMU built by `qemu-ad-pve.sh install` on Oct 1
  ([gpu-phase-patched-qemu.md](gpu-phase-patched-qemu.md)).
* **Depends on it:** 9101, 9102 (through #1). New L1 VMs from `./setup.sh` with `l1.qemu_ad=copy`/`auto`.
  **9200 does not**: its L1 has its own copy in L1's `/opt/qemu-ad`
  ([gpu-phase-patched-kvm-l1.md](gpu-phase-patched-kvm-l1.md)); removing the host copy does not touch it.
* **Check first:** as #1, plus `/opt/qemu-ad/bin/qemu-system-x86_64 --version`.
* **Remove** (also removes the diversion and `/etc/qemu-ad/vms`):
  ```bash
  ./qemu-ad-pve.sh uninstall --purge
  ```
* **Rollback:** `./qemu-ad-pve.sh install` (full rebuild from `/opt/src`, or re-downloads if #4 was removed;
  re-installs build deps), then `./qemu-ad-pve.sh add-vm 9101` and `./qemu-ad-pve.sh add-vm 9102`.
  For new setup.sh installs without it, use `l1.qemu_ad=build`.

## 3. `/opt/qemu-11.0.3`

* **What / why:** `pve-qemu-kvm 11.0.3-4` extracted from the `.deb` (no package installed) to launch 9200 by hand
  during the AMD vIOMMU retry ([gpu-phase-qemu-11.0.3.md](gpu-phase-qemu-11.0.3.md)). Superseded.
* **Depends on it:** nothing.
* **Check first:** `grep -rl qemu-11.0.3 /etc/pve/qemu-server/ /etc/systemd/system/ 2>/dev/null; pgrep -af qemu-11.0.3`
  (both expect no output).
* **Remove:** `rm -rf /opt/qemu-11.0.3`
* **Rollback:** `mkdir -p /opt/qemu-11.0.3 && dpkg-deb -x <pve-qemu-kvm_11.0.3-4_amd64.deb> /opt/qemu-11.0.3`
  (the `.deb` is probably under `/root/gpu-phase-l1/debs/`, verify with
  `ls /root/gpu-phase-l1/debs/`; otherwise `cd /tmp && apt-get download pve-qemu-kvm=11.0.3-4` if the repo still
  carries that version).

## 4. `/opt/src`

* **What / why:** build inputs for #2: `qemu-10.2.2.tar.xz`, the patched tree `qemu-10.2.2/`
  (`.qemu-ad-patched` stamp), and the `qemu-anti-detection` clone.
* **Depends on it:** nothing at runtime. A rebuild of #2 re-creates it.
* **Check first:** `du -sh /opt/src/*`
* **Remove:** `rm -rf /opt/src/qemu-10.2.2 /opt/src/qemu-10.2.2.tar.xz /opt/src/qemu-anti-detection && rmdir /opt/src`
  (`rmdir` fails harmlessly if something else lives there).
* **Rollback:** `./qemu-ad-pve.sh install` re-downloads (pinned SHA-256) and re-patches when the build is needed;
  an existing `/opt/qemu-ad` with a matching configure stamp is not rebuilt.

## 5. Oct 1 build dependencies

* **What / why:** `qemu-ad-pve.sh install_deps` ran `apt-get install -y git wget ca-certificates build-essential
  ninja-build pkg-config python3 python3-venv meson flex bison libglib2.0-dev libpixman-1-dev zlib1g-dev libaio-dev
  liburing-dev libiscsi-dev libgcrypt20-dev libusb-1.0-0-dev`. Several were already installed (PVE pulls in git,
  wget, python3, ca-certificates).
* **Depends on them:** only building #2. **But** `/opt/qemu-ad` needs the runtime libraries (`libglib2.0-0t64`,
  `libpixman-1-0`, `zlib1g`, `libaio1t64`, `liburing2`, `libiscsi7`, `libgcrypt20`, `libusb-1.0-0`) as long as #2
  exists.
* **Check first** (what that run actually added):
  ```bash
  zgrep -h -A4 'Start-Date: 2026-10-01' /var/log/apt/history.log*   # "Install:" lines = new packages
  ```
* **Remove** (only the packages the history shows as *newly installed*; never python3, git, wget,
  ca-certificates, or anything `apt-get autoremove --dry-run` would take from PVE):
  ```bash
  apt-mark manual libglib2.0-0t64 libpixman-1-0 zlib1g libaio1t64 liburing2 libiscsi7 libgcrypt20 libusb-1.0-0  # while #2 exists
  apt-mark auto build-essential ninja-build pkg-config meson flex bison python3-venv \
    libglib2.0-dev libpixman-1-dev zlib1g-dev libaio-dev liburing-dev libiscsi-dev libgcrypt20-dev libusb-1.0-0-dev
  apt-get autoremove --dry-run      # review the list: nothing pve-*, proxmox-*, qemu-server, libpve-*
  apt-get autoremove                # only if the dry run is clean
  ```
* **Rollback:** `apt-get install <the same package list>` (or `./qemu-ad-pve.sh install`, which re-runs
  `install_deps`).

## 6. 80 GiB Windows qcow2 in `fast_storage`

* **What / why:** `/mnt/fast_storage/images/9200/vm-9200-disk-2.qcow2` (`fast_storage:9200/vm-9200-disk-2.qcow2`,
  80 GiB virtual, ~37 GiB allocated) is the copy of 9101's 80 GB SATA LV made for the Windows L2
  ([gpu-phase-windows-l2.md](gpu-phase-windows-l2.md)). Since the qm-native change it is **9200's `scsi1`**,
  i.e. the L2 Windows disk (drivers, CUDA, PyTorch). It also carries the qemu-img internal snapshot
  `pre-qm-native` (see #7).
* **Depends on it:** **VM 9200. Do not remove while 9200's L2 is in use.**
* **Check first:** `grep -n disk-2 /etc/pve/qemu-server/9200.conf; qemu-img info -U /mnt/fast_storage/images/9200/vm-9200-disk-2.qcow2`
* **Remove** (only when retiring 9200's L2; *irreversible* without a backup):
  ```bash
  vzdump 9200 --mode stop --storage <backup-storage>        # backup first (or: qemu-img convert -O qcow2 ... to a backup path)
  qm shutdown 9200 --timeout 240
  qm set 9200 --delete scsi1                                # disk becomes unused0
  qm disk unlink 9200 --idlist unused0 --force              # or: pvesm free fast_storage:9200/vm-9200-disk-2.qcow2
  ```
* **Rollback:** restore from the backup (`qmrestore`, or copy the qcow2 back and `qm set 9200 --scsi1
  fast_storage:9200/vm-9200-disk-2.qcow2,serial=drive-scsi1,...` with the line from the 9200.conf backup in
  `/root/gpu-phase-l1/`). Re-copying 9101's LV (`qemu-img convert -f raw -O qcow2`) gives the *original* Windows
  state only and loses every L2 change.

## 7. Stale 9200 snapshots

* **What / why:** chain `pre-gpu` (before `hostpci0`, AMD vIOMMU phase) → `pre-kvm-module` (before the patched KVM in
  L1) → `pre-qm-native` (before the qm-native change; current parent). `pre-qm-native` exists twice: as a `qm`
  snapshot (efidisk0 + scsi0) and as a qemu-img internal snapshot on disk-2 (it was not in the config then).
* **Depends on them:** nothing at runtime. Deleting `pre-qm-native` removes the documented rollback of the
  qm-native change ([gpu-phase-qm-native-9200.md](gpu-phase-qm-native-9200.md), "Full rollback").
* **Check first:** `qm listsnapshot 9200; qemu-img snapshot -l -U /mnt/fast_storage/images/9200/vm-9200-disk-2.qcow2`
* **Remove** (9200 stopped; *irreversible*):
  ```bash
  qm shutdown 9200 --timeout 240
  qm delsnapshot 9200 pre-gpu
  qm delsnapshot 9200 pre-kvm-module
  qm delsnapshot 9200 pre-qm-native        # only once the qm-native rollback window is closed
  qemu-img snapshot -d pre-qm-native /mnt/fast_storage/images/9200/vm-9200-disk-2.qcow2
  ```
* **Rollback:** none (a deleted internal snapshot cannot be recreated). Take `vzdump 9200 --mode stop` first if
  the old states might matter; a new `qm snapshot 9200 <name>` only captures the *current* state.

## 8. VM 9000 spike leftovers

* **What / why:** VM 9000 `pve-test-qad` (`pvetest`, nested PVE 9.2.2) is the tier-2 test node (cold snapshot
  `pre-qemu-ad`). The vIOMMU spike ([viommu-nested-spike.md](viommu-nested-spike.md)) left, **inside 9000**:
  nested VM 9150 `viommu-l1` (stopped, ~1.6 GB under `/var/lib/vz/images/9150/`), `/root/viommu-spike/` (~4 MB),
  the runtime-only bridge `vmbr150` + MASQUERADE rule (gone after a 9000 reboot), and `pve-qemu-kvm` upgraded to
  11.0.3-4 inside 9000 on Oct 1. 9150 is *not* a host VM (the host has no 9150 config).
* **Depends on it:** 9000 itself is used by the tier-2 harness / NODE-SETUP (PR #16), **not by 9200**.
* **Remove the spike only** (run inside 9000):
  ```bash
  qm destroy 9150 --purge
  rm -rf /root/viommu-spike
  ip link show vmbr150 >/dev/null 2>&1 && ip link del vmbr150    # runtime only
  iptables -t nat -S POSTROUTING | grep 10.99.0                    # delete the matching MASQUERADE rule with -D if present
  ```
  Or reset 9000 to its cold snapshot from the host (9000 stopped; discards **everything** after `pre-qemu-ad`,
  including the 11.0.3 upgrade): `qm shutdown 9000 && qm rollback 9000 pre-qemu-ad`.
  Or retire 9000 entirely: `vzdump 9000 --mode stop` then `qm destroy 9000 --purge`.
* **Rollback:** 9150 has none after `destroy` (re-create from the config in viommu-nested-spike.md); 9000 from its
  vzdump. `vmbr150`/NAT: `/root/viommu-spike/net-up.sh` (only if the directory was kept).

## Keep (needed by 9200 / 9102)

* `/etc/modprobe.d/vfio.conf` (`options vfio-pci ids=10de:2704,10de:22bb`): binds the RTX 4080 to vfio-pci at boot
  for 9102 and 9200.
* `iso_images:snippets/9200-gpu-guard.pl` (`/zfs_pool/iso_images/snippets/`): 9200's hookscript (GPU guard).
* `/root/gpu-phase-l1/`: archive before deleting; it holds `l1key` (SSH to 9200's L1), the `9200.conf.*`
  backups used by the rollbacks above, `debs/` (see #3), and the 2.4 GiB torch wheel.
