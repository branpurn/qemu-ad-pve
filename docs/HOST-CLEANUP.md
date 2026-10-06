# Host cleanup: leftovers from the lab phases (procedure + status)

> **Status 2026-10-06:** items 3, 4, 5, 7 and the VM 9150 / spike part of 8 were **removed** on 2026-10-06
> (08:14-08:29 EDT), following this procedure plus stricter rules; see the record [host-cleanup-record-20261006.md](host-cleanup-record-20261006.md)
> (exact commands, package list, backup archive + checksum, before/after verification). Items 1, 2 and 6 and the
> keep-items are **still in place** and still in use. The removed sections below are kept as reference and for
> their rollback commands; they are marked **REMOVED 2026-10-06**.
>
> Before 2026-10-06 nothing in this file had been executed. It lists what the earlier lab work (Oct 1-5, 2026) left
> on the PVE host, what still depends on each item, and the exact commands to remove it and to undo the removal.
> Sources: [qa-live-20261005.md](qa-live-20261005.md) (read-only host audit), the record above, and the phase docs
> linked per item. Facts can drift: **run the "check first" commands on the host before anything else**.
>
> Rules that apply to every item:
> * **Never run `apt autoremove` / `apt-get autoremove`** (not even after `apt-mark auto`): on this host it would
>   also remove `proxmox-kernel-6.14.11-4-pve-signed`. Remove packages only by an explicit list, simulated first
>   with `apt-get -s remove <list>`.
> * **A `vzdump` of the affected VM is required, not optional,** before deleting snapshots or disks, in this order:
>   **dump, verify, then delete**.
> * `./qemu-ad-pve.sh` commands run as root from the repo checkout on the host.
> * `./setup.sh` does not need any of these items, except that `l1.qemu_ad=copy` (and `auto`, when present) reads
>   the host's `/opt/qemu-ad`.

## Summary: who depends on what

| # | Item | Size | Used by (as of 2026-10-05) | 9200 depends on it? | Removable now? | Status (2026-10-06) |
|---|------|------|----------------------------|---------------------|----------------|---|
| 1 | `/usr/bin/kvm` diversion + qemu-ad wrapper | - | **VMs 9101, 9102** (listed in `/etc/qemu-ad/vms`); every other VM passes through it to stock `kvm.pve` | **No** (9200 is not listed: it runs stock PVE QEMU 11.0.0-4 via the fall-through) | Only once 9101/9102 may lose anti-detection | in place |
| 2 | Host `/opt/qemu-ad` (QEMU 10.2.2 side build) | 464 MiB | **VMs 9101, 9102** (through #1); source for `setup.sh l1.qemu_ad=copy` | **No** at runtime: 9200's L2 uses the copy **inside L1** (`/opt/qemu-ad` in L1, copied Oct 3) | Only together with/after #1 | in place |
| 3 | `/opt/qemu-11.0.3` | 414 MiB | nothing ("not installed, not used by any VM at rest") | No | Yes | **REMOVED 2026-10-06** |
| 4 | `/opt/src` (QEMU sources) | ~2.6 GiB | nothing at runtime (build input for #2) | No | Yes | **REMOVED 2026-10-06** |
| 5 | Oct 1 apt build dependencies | ~300 MiB | building #2 only (the runtime libs #2 needs were not part of the Oct 1 set) | No | Yes, by explicit list (never autoremove; keep git) | **REMOVED 2026-10-06** (83 packages; `git`, `git-man`, `liberror-perl` kept) |
| 6 | 80 GiB Windows qcow2 `fast_storage:9200/vm-9200-disk-2.qcow2` | 80 GiB virtual, ~37 GiB allocated | **VM 9200** (`scsi1` = the Windows L2 disk) | **Yes** | **No** (only if 9200's L2 is retired) | in place |
| 7 | 9200 snapshots `pre-gpu`, `pre-kvm-module`, `pre-qm-native` | qcow2-internal | rollback points only | No (not needed to run) | Only after a verified vzdump; *irreversible* | **REMOVED 2026-10-06** (after a verified vzdump) |
| 8 | VM 9000 spike leftovers (nested VM 9150, `/root/viommu-spike`, `vmbr150`, 11.0.3 upgrade inside 9000) | ~1.6 GiB inside 9000 | VM 9000 itself is the tier-2 test node (`docs/nested-test-node` PR #16) | No | Yes (inside 9000) | **REMOVED 2026-10-06** (9150, `/root/viommu-spike`, `vmbr150`, NAT rule, `ip_forward`); 11.0.3 upgrade in 9000 kept |
| - | Keep: `/etc/modprobe.d/vfio.conf`, hookscript `iso_images:snippets/9200-gpu-guard.pl` | - | GPU vfio binding (9102, 9200); the 9200 guard | **Yes** (both) | **No** | in place (keep) |
| - | Optional: `/root/gpu-phase-l1/` | 2.5 GiB | holds 9200 conf backups, `l1key` (SSH to 9200's L1), the torch wheel, phase logs | key + backups: yes | Archive first | in place |

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

## 3. `/opt/qemu-11.0.3` (REMOVED 2026-10-06)

* **Status:** removed 2026-10-06 (`rm -rf --one-file-system /opt/qemu-11.0.3`, 414 MiB), see [host-cleanup-record-20261006.md](host-cleanup-record-20261006.md) §1.
* **What / why:** `pve-qemu-kvm 11.0.3-4` extracted from the `.deb` (no package installed) to launch 9200 by hand
  during the AMD vIOMMU retry ([gpu-phase-qemu-11.0.3.md](gpu-phase-qemu-11.0.3.md)). Superseded.
* **Depends on it:** nothing.
* **Check first:** `grep -rl qemu-11.0.3 /etc/pve/qemu-server/ /etc/systemd/system/ 2>/dev/null; pgrep -af qemu-11.0.3`
  (both expect no output).
* **Remove:** `rm -rf /opt/qemu-11.0.3`
* **Rollback:** `mkdir -p /opt/qemu-11.0.3 && dpkg-deb -x /root/gpu-phase-l1/debs/pve-qemu-kvm_11.0.3-4_amd64.deb /opt/qemu-11.0.3`
  (the `.deb` is still on the host, sha256 in the record; otherwise `cd /tmp && apt-get download pve-qemu-kvm=11.0.3-4`
  if the repo still carries that version).

## 4. `/opt/src` (REMOVED 2026-10-06)

* **Status:** removed 2026-10-06 with the command below (2.57 GiB); `/opt/qemu-ad` verified unaffected (`ldd`,
  `--version`), see [host-cleanup-record-20261006.md](host-cleanup-record-20261006.md) §2.
* **What / why:** build inputs for #2: `qemu-10.2.2.tar.xz`, the patched tree `qemu-10.2.2/`
  (`.qemu-ad-patched` stamp), and the `qemu-anti-detection` clone.
* **Depends on it:** nothing at runtime. A rebuild of #2 re-creates it.
* **Check first:** `du -sh /opt/src/*`
* **Remove:** `rm -rf /opt/src/qemu-10.2.2 /opt/src/qemu-10.2.2.tar.xz /opt/src/qemu-anti-detection && rmdir /opt/src`
  (`rmdir` fails harmlessly if something else lives there).
* **Rollback:** `./qemu-ad-pve.sh install` re-downloads (pinned SHA-256) and re-patches. Note: it runs
  `fetch_sources` *before* its "already installed" check, so it re-creates `/opt/src` (~135 MB download, ~2.6 GB on
  disk) even when an existing `/opt/qemu-ad` with a matching configure stamp is not rebuilt.

## 5. Oct 1 build dependencies (REMOVED 2026-10-06)

* **Status:** removed 2026-10-06: 83 packages by explicit list with `apt-get remove`, after two clean
  `apt-get -s remove` simulations; `git`, `git-man` and `liberror-perl` kept. Exact list, history excerpt and
  verification in [host-cleanup-record-20261006.md](host-cleanup-record-20261006.md) §3.
* **What / why:** `qemu-ad-pve.sh install_deps` ran `apt-get install -y git wget ca-certificates build-essential
  ninja-build pkg-config python3 python3-venv meson flex bison libglib2.0-dev libpixman-1-dev zlib1g-dev libaio-dev
  liburing-dev libiscsi-dev libgcrypt20-dev libusb-1.0-0-dev` (three Oct 1 transactions, 86 newly installed packages
  including dependencies such as gcc-14, make, m4, libc6-dev).
* **git is not shipped with PVE.** `git` (marked manual), `git-man` and `liberror-perl` were *newly installed* on
  Oct 1 by `install_deps`. They are **kept deliberately** (the repo checkout on the host and `qemu-ad-pve.sh install`
  use git). Do not include them in any removal list. (An earlier version of this doc wrongly said PVE pulls in git.)
* **Depends on them:** only building #2. The runtime libraries `/opt/qemu-ad` needs (`libglib2.0-0t64`,
  `libpixman-1-0`, `zlib1g`, `libaio1t64`, `liburing2`, `libiscsi7`, `libgcrypt20`, `libusb-1.0-0`, ...; full `ldd`
  list in the record) were **not** in the Oct 1 install set and are marked manual, so removing the build set does
  not touch them. Re-check with `apt-mark showmanual` before a removal.
* **Never use `apt autoremove` / `apt-get autoremove` here** (also not after `apt-mark auto`): on this host
  `apt-get -s autoremove` lists `proxmox-kernel-6.14.11-4-pve-signed`, an unrelated kernel that must stay.
* **Check first** (derive the exact set; never type it from memory):
  ```bash
  zgrep -h -A4 'Start-Date: 2026-10-01' /var/log/apt/history.log*     # "Install:" lines = newly installed packages
  zgrep -h ' install ' /var/log/dpkg.log* | grep '^2026-10-01'          # cross-check: same package set
  # build the list from those Install: lines, then drop git, git-man, liberror-perl
  ```
* **Remove** (explicit list only, simulate first):
  ```bash
  PKGS="<exact list from the check, without git git-man liberror-perl>"
  apt-get -s remove $PKGS          # must show "0 newly installed" and a Remv list EQUAL to $PKGS:
                                   # no extra package, nothing pve-*, proxmox-*, qemu-server, kernel, zfs, pve-qemu-kvm
  apt-get -s remove $PKGS          # repeat immediately before the real run
  DEBIAN_FRONTEND=noninteractive apt-get remove -y $PKGS
  dpkg --audit && apt-get check    # both clean
  /opt/qemu-ad/bin/qemu-system-x86_64 --version   # side QEMU still runs (ldd: no "not found")
  ```
* **Rollback:** `apt-get install $PKGS` (same list) or `./qemu-ad-pve.sh install`, which re-runs `install_deps`.

## 6. 80 GiB Windows qcow2 in `fast_storage`

* **What / why:** `/mnt/fast_storage/images/9200/vm-9200-disk-2.qcow2` (`fast_storage:9200/vm-9200-disk-2.qcow2`,
  80 GiB virtual, ~37 GiB allocated) is the copy of 9101's 80 GB SATA LV made for the Windows L2
  ([gpu-phase-windows-l2.md](gpu-phase-windows-l2.md)). Since the qm-native change it is **9200's `scsi1`**,
  i.e. the L2 Windows disk (drivers, CUDA, PyTorch). It also carries the qemu-img internal snapshot
  `pre-qm-native` (see #7).
* **Depends on it:** **VM 9200. Do not remove while 9200's L2 is in use.**
* **Check first:** `grep -n disk-2 /etc/pve/qemu-server/9200.conf; qemu-img info -U /mnt/fast_storage/images/9200/vm-9200-disk-2.qcow2`
* **Remove** (only when retiring 9200's L2; a verified vzdump is **required** first):
  ```bash
  # 1. dump (REQUIRED; see §7 for why 9102 must release the GPU first)
  vzdump 9200 --mode stop --storage <backup-storage> --compress zstd
  # 2. verify the archive before deleting anything
  zstd -dc /path/to/vzdump-qemu-9200-<date>.vma.zst | vma verify -v -
  sha256sum /path/to/vzdump-qemu-9200-<date>.vma.zst
  # 3. delete
  qm shutdown 9200 --timeout 240
  qm set 9200 --delete scsi1                                # disk becomes unused0
  qm disk unlink 9200 --idlist unused0 --force              # or: pvesm free fast_storage:9200/vm-9200-disk-2.qcow2
  ```
* **Rollback:** restore from the backup (`qmrestore`, or copy the qcow2 back and `qm set 9200 --scsi1
  fast_storage:9200/vm-9200-disk-2.qcow2,serial=drive-scsi1,...` with the line from the 9200.conf backup in
  `/root/gpu-phase-l1/`). Re-copying 9101's LV (`qemu-img convert -f raw -O qcow2`) gives the *original* Windows
  state only and loses every L2 change.

## 7. Stale 9200 snapshots (REMOVED 2026-10-06)

* **Status:** removed 2026-10-06 after a verified vzdump
  (`iso_images:backup/vzdump-qemu-9200-2026_10_06-08_20_12.vma.zst`, 28.92 GiB, sha256 and `vma verify` in the record),
  see [host-cleanup-record-20261006.md](host-cleanup-record-20261006.md) §4. 9200 was then booted and passed the full GPU check.
* **What / why:** chain `pre-gpu` (before `hostpci0`, AMD vIOMMU phase) → `pre-kvm-module` (before the patched KVM in
  L1) → `pre-qm-native` (before the qm-native change). `pre-qm-native` existed twice: as a `qm` snapshot (efidisk0 +
  scsi0) and as a qemu-img internal snapshot on disk-2 (it was not in the config then).
* **Depends on them:** nothing at runtime. Deleting `pre-qm-native` removes the documented rollback of the
  qm-native change ([gpu-phase-qm-native-9200.md](gpu-phase-qm-native-9200.md), "Full rollback").
* **A vzdump of the VM is REQUIRED before deleting any snapshot, not optional.** Order: **dump → verify → delete**.
  vzdump stores only the *current* state ("snapshots found (not included into backup)"), so the snapshot states
  themselves are gone after deletion either way; the dump guarantees the current state survives a mistake.
* **GPU note:** vzdump of a stopped VM starts it paused (`vm_start`, running the `pre-start` hookscript). 9200's GPU
  guard refuses while 9102 holds the RTX 4080, so shut 9102 down for the backup window and start it again after.
* **Check first:**
  ```bash
  qm status 9200; qm config 9200 | grep -E '^(lock|parent):'      # stopped, no lock
  qm listsnapshot 9200
  qemu-img snapshot -l -U /mnt/fast_storage/images/9200/vm-9200-disk-2.qcow2
  pvesm status | grep <backup-storage>                             # enough free space (the 2026-10-06 dump: ~29 GiB)
  ```
* **Remove** (in this order):
  ```bash
  # 1. dump (REQUIRED)
  qm shutdown 9102 --timeout 180                                  # only if 9102 holds the GPU
  vzdump 9200 --mode stop --storage <backup-storage> --compress zstd --notes-template 'before deleting snapshots'
  # 2. verify (all must succeed before step 3)
  grep -q 'Backup job finished successfully' /path/to/vzdump-qemu-9200-<date>.log
  zstd -dc /path/to/vzdump-qemu-9200-<date>.vma.zst | vma verify -v -
  sha256sum /path/to/vzdump-qemu-9200-<date>.vma.zst                # record it
  qm start 9102                                                    # if it was shut down above
  # 3. delete snapshots, newest (leaf) first so nothing has to be re-parented; 9200 stays stopped
  qm delsnapshot 9200 pre-qm-native
  qm delsnapshot 9200 pre-kvm-module
  qm delsnapshot 9200 pre-gpu
  qemu-img snapshot -d pre-qm-native /mnt/fast_storage/images/9200/vm-9200-disk-2.qcow2   # PVE does not track this one
  qm listsnapshot 9200; qemu-img check /mnt/fast_storage/images/9200/vm-9200-disk-2.qcow2
  ```
* **Rollback:** the deleted snapshot states cannot be recreated. `qmrestore <archive> 9200 --force` restores the
  state at dump time (for 2026-10-06: 08:20 EDT).

## 8. VM 9000 spike leftovers (spike part REMOVED 2026-10-06)

* **Status:** removed 2026-10-06 inside 9000: VM 9150 (`qm destroy 9150 --purge`, plus `pvesm free
  local:9150/nvme-test.raw`, which destroy leaves behind because it is only referenced from `args:`),
  `/root/viommu-spike`, `vmbr150`, the MASQUERADE rule, and `net.ipv4.ip_forward` reset to 0. 9000 itself, its
  snapshot `pre-qemu-ad`, VM 9100 and the 11.0.3 package upgrade were kept. See [host-cleanup-record-20261006.md](host-cleanup-record-20261006.md) §5.
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
  pvesm list local | grep 9150                                     # args-only volumes survive destroy: pvesm free them
  iptables -t nat -S POSTROUTING | grep 10.99.0                    # delete the matching MASQUERADE rule with -D if present
  sysctl -w net.ipv4.ip_forward=0                                  # net-up.sh set it at runtime only
  ```
  Or reset 9000 to its cold snapshot from the host (9000 stopped; discards **everything** after `pre-qemu-ad`,
  including the 11.0.3 upgrade): `qm shutdown 9000 && qm rollback 9000 pre-qemu-ad`.
  Or retire 9000 entirely: dump, verify, then delete (`vzdump 9000 --mode stop`, `vma verify` as in §7, then
  `qm destroy 9000 --purge`).
* **Rollback:** 9150 has none after `destroy` (re-create from the config in viommu-nested-spike.md); 9000 from its
  vzdump. `vmbr150`/NAT: `/root/viommu-spike/net-up.sh` (only if the directory was kept).

## Keep (needed by 9200 / 9102)

* `/etc/modprobe.d/vfio.conf` (`options vfio-pci ids=10de:2704,10de:22bb`): binds the RTX 4080 to vfio-pci at boot
  for 9102 and 9200.
* `iso_images:snippets/9200-gpu-guard.pl` (`/zfs_pool/iso_images/snippets/`): 9200's hookscript (GPU guard).
* `/root/gpu-phase-l1/`: archive before deleting; it holds `l1key` (SSH to 9200's L1), the `9200.conf.*`
  backups used by the rollbacks above, `debs/` (see #3), and the 2.4 GiB torch wheel.
