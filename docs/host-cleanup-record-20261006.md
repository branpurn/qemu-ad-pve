# Host cleanup record, 2026-10-06 (TEST-RIG leftovers before setup.sh testing)

Executed 2026-10-06, 08:14 to 08:29 EDT, by Grok Bot for Brandon (approval relayed by the 9-9-6 Developer bot).
Procedure: [HOST-CLEANUP.md](HOST-CLEANUP.md) at `main` a61b54b, plus the task's stricter rules (where the two
differ, the stricter rule was used; see "Conflicts with HOST-CLEANUP.md"). Every item's check-first commands ran
before its removal. No host reboot, no `apt install`/`upgrade`, no `apt autoremove`, `qemu-ad-breakglass.sh` not
run. No credentials or private addresses appear here.

## Summary

| # | Item | Result | Space freed |
|---|------|--------|-------------|
| 1 | Host `/opt/qemu-11.0.3` (extracted `pve-qemu-kvm 11.0.3-4`) | **removed** | 423,916 KiB (414 MiB) on `/` |
| 2 | Host `/opt/src` (QEMU 10.2.2 tarball, patched tree, `qemu-anti-detection` clone) | **removed** | 2,692,664 KiB (2.57 GiB) on `/` |
| 3 | Host Oct 1 build-only apt packages (83 packages) | **removed** (`apt-get remove`, exact list below) | 316,224 KiB measured on `/` (apt: "307 MB will be freed") |
| 4 | VM 9200 snapshots `pre-qm-native`, `pre-kvm-module`, `pre-gpu` + the qemu-img internal `pre-qm-native` on disk-2 | **removed**, after a verified `vzdump` | 886,788 KiB (866 MiB) on `/mnt/fast_storage` |
| 5 | Inside VM 9000: nested VM 9150 (config + 3 volumes), `/root/viommu-spike`, `vmbr150`, MASQUERADE rule, `ip_forward=1` | **removed / reverted** | 1,592,720 KiB (1.52 GiB) on 9000's `/` |
| 6 | Other spike throwaways on the host | **nothing removed** (kept, see list) | 0 |

### Disk free per filesystem (`df -k`)

| Filesystem | Before (used / avail KiB) | After (used / avail KiB) | Change |
|------------|---------------------------|--------------------------|--------|
| Host `/` (`pve-root`, holds `/opt`) | 24,278,220 / 69,170,012 (66G avail) | 20,845,388 / 72,602,844 (70G avail) | **-3,432,832 KiB used (3.27 GiB freed)** |
| Host `/mnt/fast_storage` | 691,069,596 used just before step 4 | 690,182,808 right after step 4 (690,149,412 at the end) | **-886,788 KiB (866 MiB)** by step 4 (other VMs' images on this fs also move slightly) |
| Host `/zfs_pool` (vzdump target `iso_images`) | 2,535,393,536 / 22,424,810,240 | 2,565,711,232 / 22,394,492,544 | +30.3 GB used (the new 9200 backup) |
| VM 9000 `/` | 43,486,456 / 46,405,784 | 41,893,736 / 47,998,504 | **-1,592,720 KiB (1.52 GiB freed)** |

Host total freed (excluding the new backup): about **4.1 GiB** (3.27 GiB on `/`, 0.85 GiB on `/mnt/fast_storage`).

## Baseline before any change (08:15-08:20 EDT)

* `qm list`: 9102 running, 9200 stopped, 9000 running; other VMs as in the final list below.
* 9102 healthy: RTX 4080 `Status OK`, `ConfigManagerErrorCode 0` (GPU + both audio functions), `nvidia-smi` 576.88, 16376 MiB.
* Host dmesg: `IO_PAGE_FAULT` count **53**, `AER|Xid` 0, broad `fault|BUG|oops|error` 233. GPU 02:00.0/.1 on `vfio-pci`.
* `/usr/bin/kvm` diverted to `/usr/bin/kvm.pve`; `/etc/qemu-ad/vms` = 9101, 9102.

## 1. `/opt/qemu-11.0.3`

* Size: `du` 414M (423,916 KiB).
* Check-first: `grep -rl qemu-11.0.3` over `/etc/pve/qemu-server/`, `/etc/pve/nodes/*/qemu-server/`, systemd unit dirs,
  `/etc/qemu-ad/`, the `/usr/bin/kvm` wrapper, the snippets dir and cron: **no hits**. `pgrep -af qemu-11.0.3`: none.
  No process maps a file from it (`/proc/*/maps`); running QEMU binaries were only `/usr/bin/qemu-system-x86_64`
  (vendor) and `/opt/qemu-ad/bin/qemu-system-x86_64` (9102). No symlink anywhere on `/` points into it. No VM
  config contains `/opt`. The wrapper references only `/usr/bin/kvm.pve` and `/opt/qemu-ad`.
* Why ours/unused: the hand-launch QEMU of the AMD vIOMMU retry ([gpu-phase-qemu-11.0.3.md](gpu-phase-qemu-11.0.3.md));
  no package owns it (`pve-qemu-kvm` installed is 11.0.0-4).
* Removed: `rm -rf --one-file-system /opt/qemu-11.0.3`.
* Rollback: `/root/gpu-phase-l1/debs/pve-qemu-kvm_11.0.3-4_amd64.deb` is still on the host
  (sha256 `5232d63a4f89ff206d13e23f07fcb17b8ef3ddb7c171bc196fe25c64fb0fe30f`): `dpkg-deb -x <deb> /opt/qemu-11.0.3`.

## 2. `/opt/src`

* Size: 2.6G total (2,692,664 KiB): `qemu-10.2.2/` 2.4G (with `.qemu-ad-patched` stamp), `qemu-10.2.2.tar.xz` 135M,
  `qemu-anti-detection/` 106M.
* Check-first (does `/opt/qemu-ad` depend on it?):
  * `ldd` of all 10 `/opt/qemu-ad` binaries/helpers: every library resolves to `/lib/x86_64-linux-gnu`, none in `/opt/src`.
  * `readelf -d`: no `RPATH`/`RUNPATH` in any `/opt/qemu-ad` executable.
  * `find /opt/qemu-ad -type l`: no symlinks at all. The only symlinks pointing into `/opt/src` live inside `/opt/src` itself (build dir).
  * The binaries do contain `/opt/src/...` strings, but they are source-file paths (`__FILE__`/DWARF; `file` reports
    "with debug_info, not stripped"): 197 source-file paths plus source directory names, no data files.
    `qemu-system-x86_64 -L help` shows the firmware dirs are `/opt/qemu-ad/share/qemu{,-firmware}`.
  * No process has a mapping or cwd under `/opt/src`.
  * `setup.sh`/`setup/` do not reference `/opt/src`; only `qemu-ad-pve.sh install` uses it (`SRC_ROOT`), and it re-downloads (pinned SHA-256) when absent.
* Removed: `rm -rf /opt/src/qemu-10.2.2 /opt/src/qemu-10.2.2.tar.xz /opt/src/qemu-anti-detection && rmdir /opt/src` (the doc's command).
* Right after: `/opt/qemu-ad/bin/qemu-system-x86_64 --version` = `QEMU emulator version 10.2.2`, `ldd` 0 "not found".
* Note: a future `./qemu-ad-pve.sh install` runs `fetch_sources` before the "already installed" check, so it will
  re-download and re-patch the sources (~135 MB download, ~2.6 GB on disk) even when it does not rebuild.

## 3. Oct 1 build-only apt packages

* Source of truth: `/var/log/apt/history.log.1.gz` has exactly three Oct 1 transactions (16:42:34, 17:57:24, 20:35:06 EDT),
  all from `qemu-ad-pve.sh install_deps` / the libusb rebuild. Their `Install:` lines list **86 newly installed
  packages**; `/var/log/dpkg.log.1` `install` lines for 2026-10-01 give the identical 86 (diff empty). No dpkg
  install/remove activity after Oct 1. The `Upgrade:` part of the first transaction (libc6, util-linux, glib runtime,
  python3.13, ...) was **not** touched.
* Runtime libraries `/opt/qemu-ad` needs (`ldd` of every binary in `bin/` and `libexec/`, mapped with `dpkg -S`):
  `libaio1t64 libatomic1 libblkid1 libc6 libcap2 libffi8 libgcrypt20 libglib2.0-0t64 libgpg-error0 libibverbs1
  libiscsi7 libmount1 libnl-3-200 libnl-route-3-200 libpcre2-8-0 libpixman-1-0 librdmacm1t64 libselinux1 libudev1
  liburing2 libusb-1.0-0 zlib1g`. **None** of them is in the Oct 1 install set, and all are already marked
  *manual* (`apt-mark showmanual`), so no `apt-mark` change was needed to protect them.
* Kept from the Oct 1 set: `git`, `git-man`, `liberror-perl` (HOST-CLEANUP.md: "never ... git"; see conflicts).
* Removal set (83 packages):
  `bison build-essential cpp cpp-14 cpp-14-x86-64-linux-gnu cpp-x86-64-linux-gnu dpkg-dev fakeroot flex g++ g++-14
  g++-14-x86-64-linux-gnu gcc gcc-14 gcc-14-x86-64-linux-gnu gcc-x86-64-linux-gnu girepository-tools
  g++-x86-64-linux-gnu libaio-dev libalgorithm-diff-perl libalgorithm-diff-xs-perl libalgorithm-merge-perl libasan8
  libblkid-dev libc6-dev libcc1-0 libc-dev-bin libcrypt-dev libfakeroot libffi-dev libfl2 libfl-dev libgcc-14-dev
  libgcrypt20-dev libgio-2.0-dev libgio-2.0-dev-bin libgirepository-2.0-0 libglib2.0-bin libglib2.0-data
  libglib2.0-dev libglib2.0-dev-bin libgomp1 libgpg-error-dev libhwasan0 libiscsi-dev libisl23 libitm1 liblsan0
  libmount-dev libmpc3 libpcre2-32-0 libpcre2-dev libpixman-1-dev libpkgconf3 libquadmath0 libselinux1-dev
  libsepol-dev libstdc++-14-dev libsysprof-capture-4-dev libtsan2 libubsan1 liburing-dev libusb-1.0-0-dev
  libusb-1.0-doc linux-libc-dev m4 make manpages-dev meson native-architecture ninja-build patch pkgconf pkgconf-bin
  pkg-config python3.13-venv python3-packaging python3-pip-whl python3-setuptools-whl python3-venv rpcsvc-proto
  uuid-dev zlib1g-dev` (dpkg installed-size total 299,331 KiB).
* Check-first: `apt-get -s remove <set>` run twice (initial and immediately before the real run): `0 upgraded,
  0 newly installed, 83 to remove`; the `Remv` list equals the set exactly (no extra package, so no installed
  package outside the set depends on any of them); nothing `pve-*`, `proxmox-*`, `qemu-server`, kernel, ZFS or
  `pve-qemu-kvm` related.
* Host-side `setup.sh` (`setup/qad_setup/*.py`) imports only the Python standard library; the L1 build tools come
  from `setup/l1/qad-l1.sh` inside L1, not from the host.
* Removed: `DEBIAN_FRONTEND=noninteractive apt-get remove -y <set>` (exit 0, 83 "Removing", "307 MB disk space will be freed").
* After: `dpkg --audit` clean, `apt-get check` clean; `git`, `pve-manager 9.2.3`, `proxmox-ve 9.2.0`,
  `qemu-server 9.1.17`, `pve-qemu-kvm 11.0.0-4` still installed; diversion intact; `/opt/qemu-ad` `--version` OK and
  `ldd` 0 "not found" for all 10 binaries. `apt-get -s autoremove` now lists only `proxmox-kernel-6.14.11-4-pve-signed`
  (pre-existing, unrelated, **not** removed).
* Rollback: `apt-get install <the same list>` or `./qemu-ad-pve.sh install` (re-runs `install_deps`).

## 4. VM 9200 snapshots (after a verified vzdump)

* Check-first: 9200 `stopped`, no lock. `qm listsnapshot 9200`: `pre-gpu` (2026-10-02 11:28) -> `pre-kvm-module`
  (2026-10-03 16:04) -> `pre-qm-native` (2026-10-05 16:34). qemu-img internal snapshots: disk-0 and disk-1 had all
  three; disk-2 had only `pre-qm-native` (ID 1).
* Why the backup had to wait for a 9102 shutdown: vzdump of a stopped VM starts it paused (`vm_start`, which runs
  the `pre-start` hookscript). 9200's GPU guard refuses while 9102 holds the GPU, so the backup ran inside the
  9102 maintenance window (9102 shut down cleanly at 08:19:54 EDT, `qm shutdown 9102 --timeout 180`, 8 s).
* **vzdump**: `vzdump 9200 --mode stop --storage iso_images --compress zstd` (storage `iso_images`, ZFS, about 21 TiB
  free, `prune-backups keep-all=1`, no older 9200 backups). Run 08:20:12-08:22:25 EDT, "Backup job finished successfully".
  * Archive: **`/zfs_pool/iso_images/dump/vzdump-qemu-9200-2026_10_06-08_20_12.vma.zst`** (volume
    `iso_images:backup/vzdump-qemu-9200-2026_10_06-08_20_12.vma.zst`), **31,053,207,185 bytes (28.92 GiB)**, log
    alongside (`.log`), notes "pre-host-cleanup 2026-10-06: before deleting snapshots ...".
  * Contents: `scsi0` disk-1 30G, `scsi1` disk-2 80G, `efidisk0` 528K, config; 110 GiB read, 63.21 GiB zero/sparse.
    vzdump logs "snapshots found (not included into backup)": it holds the **current** state only.
  * sha256: `32e7cdbaaa41213bf1b85e4e94ba902fe2ba75490b8f0fbaa73705c1451e9114`.
  * Integrity: `zstd -dc <archive> | vma verify -v -` read all 118,112,190,464 bytes, exit 0 (pipeline rc 0 0 0).
  * Host dmesg after the backup: `IO_PAGE_FAULT` 53, `AER|Xid` 0, GPU back on `vfio-pci`, only `vfio-pci reset` lines added.
* Removed (newest first, so no snapshot had to be re-parented):
  `qm delsnapshot 9200 pre-qm-native`, `qm delsnapshot 9200 pre-kvm-module`, `qm delsnapshot 9200 pre-gpu`
  (each OK; afterwards `qm listsnapshot` shows only `current`; disk-0/disk-1 have no internal snapshots).
* disk-2 internal snapshot: still listed after the `qm` deletions, 9200 still `stopped`, no process had the file
  open, so `qemu-img snapshot -d pre-qm-native /mnt/fast_storage/images/9200/vm-9200-disk-2.qcow2`. Afterwards
  `qemu-img snapshot -l` is empty, `qemu-img check` "No errors were found on the image", 80 GiB virtual, 36.3 GiB
  on disk. The qcow2 was not moved or deleted.
* 9200.conf: only the three `[snapshot]` sections and the `parent:` line went away; the current section is otherwise
  byte-identical (checked by diff).
* Per-file allocation change: disk-0 1,368 -> 840 KiB, disk-1 12,094,636 -> 11,374,648 KiB, disk-2 38,228,500 ->
  38,062,228 KiB (total -886,788 KiB = the `/mnt/fast_storage` change).
* Rollback: the old snapshot states are gone for good (no backup of them existed); the archive above restores
  9200's state as of 08:20 EDT today (`qmrestore`).

## 5. VM 9000 (`pvetest`) spike leftovers

Access: SSH to `pvetest` with the existing hop key (strict host key checking, key already known), as before. VM 9000
itself was not stopped, reverted or reconfigured; its snapshot `pre-qemu-ad` is untouched.

* **Nested VM 9150 `viommu-l1`**: it was **not absent**: `qm list` in 9000 showed 9150 stopped,
  `/etc/pve/qemu-server/9150.conf` existed, `pvesm list local` showed `local:9150/nvme-test.raw` (1 GiB),
  `vm-9150-cloudinit.qcow2`, `vm-9150-disk-0.qcow2` (10G); `/var/lib/vz/images/9150` 1.6G. No snapshots, no backup,
  replication or HA entries, nothing else references 9150 (9100 uses only `local:9100/...` and `vmbr0`).
  Config saved before removal (its content is the one in [viommu-nested-spike.md](viommu-nested-spike.md)).
  * `qm destroy 9150 --purge` (OK). `nvme-test.raw` was only referenced from `args:`, so destroy left it;
    `pvesm free local:9150/nvme-test.raw` removed it and the empty `images/9150` dir. Now: no 9150 config, no
    9150 volume on `local` or `qad-img`.
* **`/root/viommu-spike`** (4.3M: `net-up.sh`, `restart-l1.sh`, throwaway L1 key, trace log, `SHA512SUMS`): removed.
* **`vmbr150` + MASQUERADE + `ip_forward`**: `net-up.sh` (read before deleting) is what created all three:
  (`<spike-net>` = the private /24 of the spike, see viommu-nested-spike.md) `ip link add vmbr150 type bridge` + `<spike-net>.1/24`, `sysctl -qw net.ipv4.ip_forward=1`, and
  `iptables -t nat -A POSTROUTING -s <spike-net>/24 ! -d <spike-net>/24 -j MASQUERADE`. `/etc/network/interfaces` defines
  only `lo`, `ens18`, `vmbr0`; `interfaces.d/` is empty; no sysctl file sets `ip_forward`: all runtime-only. The nat
  table held only that one rule; `FORWARD` policy ACCEPT with no rules; PVE firewall disabled; 9100 is bridged on
  `vmbr0` (no routing/NAT needed). Actions: `ip link del vmbr150`, `iptables -t nat -D POSTROUTING -s <spike-net>/24
  ! -d <spike-net>/24 -j MASQUERADE`, `sysctl -w net.ipv4.ip_forward=0`.
  After: `vmbr0` up with its address, default route intact, LAN gateway pings, 9100 `running`.
* Kept in 9000: VM 9100 `w10-gpu` (running, untouched), 9001-9003, `pve-qemu-kvm` as installed (the 11.0.3 upgrade
  is not in this task's scope), 9000's own Oct 1 apt packages, everything else.

## 6. Other spike throwaways: kept (could not prove both "ours" and "unused", or they are rollback records)

* Stale `/var/run/qemu-server/9200.vnc`: **already absent** (nothing to do).
* `/root/gpu-phase-l1/` (2.5G): kept whole. Holds `l1key` (SSH to 9200's L1, used for this run's verification),
  `w10_ed25519` (used by `verify-l2.sh`), all `9200.conf.*` backups including the AMD backup and the newest
  (`9200.conf.pre-qm-native-20261005163444`), `debs/` (rollback for item 1), `qmnative/` helpers used below, the 2.4G
  torch wheel (`pytorch/`), and phase logs. HOST-CLEANUP.md says archive before deleting.
* `/root/qemu-system-x86_64.nolibusb` (84 MB, Oct 1 18:01): an earlier side-QEMU build, unreferenced by any script,
  config or process, but it is a previous build of `/opt/qemu-ad` (possible fallback), so kept.
* `/root/qemu-ad-pve/` (old `qemu-ad-pve.sh` copies), `/root/qemu-ad-install*.log`, `qad-rebuild.log`,
  `qad-install.log`, `qad-newflags.txt`, `side-*-9101.txt`, `vms.with9101`, `hide-hypervisor*`, `vm9102-step*.sh`,
  `step*-9102-apply.log`, `qemu-ad-pre-state/`, `qemu-ad-breakglass*`: small (< 2 MB total), install/rollback
  records of the qemu-ad / 9102 work: kept.

## Deliberately kept (task KEEP list)

Host `/opt/qemu-ad`; the `/usr/bin/kvm` diversion + wrapper; `/etc/qemu-ad/*`; 9200's disk-2 (80 GiB Windows qcow2) and
all 9200 disks; `/etc/pve/qemu-server/9200.conf` (only snapshot sections removed by `qm delsnapshot`);
`/etc/modprobe.d/vfio.conf`; `/zfs_pool/iso_images/snippets/9200-gpu-guard.pl`; VM 9000's 9100; every other VM; all
packages outside the 83 above (including `git`); kernel, GRUB, `storage.cfg`.

## Verification

| Check | Result |
|-------|--------|
| `/opt/qemu-ad/bin/qemu-system-x86_64 --version` | `QEMU emulator version 10.2.2` (after items 2 and 3, and at the end) |
| `ldd` of all `/opt/qemu-ad` binaries/helpers | 0 "not found" (10/10) |
| 9102 before | Code 0 (GPU + 2 audio), `nvidia-smi` 576.88, 16376 MiB |
| `qm shutdown 9102 --timeout 180` | clean, 8 s (08:19:54-08:20:03 EDT) |
| `qm start 9200` (08:25:46) | OK; guard reserved the GPU; L1 booted, `w10-l2.service` enabled/active ~10 s after boot, L2 SSH up |
| L1 KVM | `kvm`/`kvm_amd` `6.12.111-kvmpatch1` from `updates/dkms` (patched, default) |
| L2 (Windows) | RTX 4080 + 2 audio functions `OK`, **Code 0**; `nvidia-smi` 576.88, 16376 MiB, BAR1 16384 MiB; CuPy SGEMM 30.1 / 30.5 TFLOP/s, `RESULT: PASS` x2 |
| L1 dmesg | 1 fault-pattern line = the known boot-time `RDMSR 0x852` / `setup_APIC_eilvt` call trace, same count (1) as the 2026-10-05 cycles c1-c3 |
| `qm shutdown 9200 --timeout 240` (08:27:19) | clean, 15 s; no 9200 QEMU left; guard released; GPU on `vfio-pci` |
| `qm start 9102` (08:27:38) | OK; wrapper log `vmid=9102 exec /opt/qemu-ad/bin/qemu-system-x86_64`; process exe `/opt/qemu-ad/bin/qemu-system-x86_64` |
| 9102 after (08:28:35) | Code 0 (GPU + audio), `nvidia-smi` 576.88, 16376 MiB |
| Host dmesg | `IO_PAGE_FAULT` **53 -> 53**, `AER|Xid` 0 -> 0, broad 233 -> 233; new lines only vfio resets / bridge port state |

9102 was down 08:20-08:27 EDT (about 8 minutes, including the backup).

Final `qm list` (host, 08:28 EDT):

```
VMID NAME                 STATUS
 100 workstation          stopped
 105 windows-7            stopped
 110 pop-os               running
 115 waydroid             running
 120 ubuntu-server-temp   stopped
 125 steamos              stopped
 200 pfsense              running
 240 securityonion        stopped
 245 openvpn              running
 300 soman                stopped
 400 esxi                 stopped
 410 nutanix              stopped
 500 openclaw             stopped
9000 pve-test-qad         running
9101 w10-bm               stopped
9102 w10-bm2              running
9200 viommu-l1-gpu        stopped
```

VM 9000 `qm list`: 9001-9003 stopped, 9100 `w10-gpu` running (9150 gone).

## Conflicts with HOST-CLEANUP.md (stricter rule applied)

1. **Build deps (doc §5)**: the doc removes them with `apt-mark auto` + `apt-get autoremove`. The task forbids a broad
   autoremove, so the exact Oct 1 set went through `apt-get -s remove` and then `apt-get remove`. `apt-get -s autoremove`
   would also have taken an old kernel (`proxmox-kernel-6.14.11-4-pve-signed`), which shows why.
2. **git (doc §5)**: the doc says git was already installed ("PVE pulls in git") and must never be removed. The apt history
   shows `git` (manual), `git-man` and `liberror-perl` were in fact **newly installed** on Oct 1. The stricter rule
   (doc: never remove git) won: all three kept.
3. **Backup before snapshots (doc §7)**: the doc makes vzdump optional; the task requires it. Done and verified first.
4. **Snapshot order (doc §7)**: the doc lists `pre-gpu` first; they were deleted newest-first (leaf first), which gives the
   same end result without re-parenting.
5. **VM 9150 (doc §8)**: the task said 9150 was "reported absent"; inside VM 9000 it still existed (stopped, config and
   1.6 GB of volumes). Both the doc (`qm destroy 9150 --purge`) and the task's REMOVE list cover it, so it was
   destroyed; the args-only `nvme-test.raw`, which `qm destroy` leaves behind, was freed with `pvesm free`.
6. **9000's 11.0.3 package upgrade (doc §8 lists it as a leftover)**: not reverted (no apt changes in 9000; "keep
   everything else in 9000").

## Side effects outside the removed items

* `/root/gpu-phase-l1/qmnative/l1ip` was rewritten by `qrun.sh` (it caches L1's current DHCP address; it changed with this boot).
* `verify-l2.sh` and `l1dmesg.sh` were copied to L1's `/tmp` by `qrun.sh` (the L2 key copy is deleted by the script itself).
* Temporary files under the host's `/tmp` (apt list, checksum output, config copy for the diff) were deleted again.
