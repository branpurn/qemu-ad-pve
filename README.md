# qemu-ad-pve

A development-environment compatibility tool. It builds a second QEMU next to stock Proxmox VE and sends only selected guests to that binary, so those guests see ordinary hardware identifiers instead of QEMU's virtual-device strings.

This is for a lab or development host, where a guest operating system or a program you are testing refuses to run because it has detected virtual hardware. Typical cases are a driver that faults when the hypervisor CPUID leaf is present, firmware or application test suites that branch on SMBIOS and device-name strings, and PCI passthrough of a device whose driver will not bind on a guest that advertises itself as a VM. It is not a production hypervisor, and it is not a supported Proxmox configuration.

## What it is not

- It does not replace `pve-qemu-kvm` or `qemu-server`. Those packages keep updating on the normal schedule.
- It does not patch Proxmox's QEMU tree. The compatibility patch is applied to a vanilla QEMU tarball, installed under `/opt/qemu-ad`.
- It is not a second Proxmox node. Guests stay managed by the existing `qm` and the web UI.
- Live backup and live migration of a guest on the side binary will fail. Proxmox sends QMP commands that vanilla QEMU does not implement. Start and stop still work.
- It does not hide timing. RDTSC and similar checks are unchanged.

Use it on a machine you control, for software you are developing or testing. Do not point it at a guest you do not own.

## How it is put together

`qm` always execs `/usr/bin/kvm`. This repo diverts that path:

- `/usr/bin/kvm.pve` is the vendor binary from `pve-qemu-kvm`. A package upgrade writes here, not over the wrapper.
- `/usr/bin/kvm` is a wrapper. It reads the VMID from the pidfile or QMP socket path on the command line. VMIDs listed in `/etc/qemu-ad/vms` exec `/opt/qemu-ad/bin/qemu-system-x86_64`. Every other guest execs the vendor binary with the original arguments.
- The side binary is vanilla QEMU 10.2.2 plus the device-identity patch from [zhaodice/qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection), cloned at install time. The patch rewrites emulator-reported names (keyboard, disk vendor strings, SMBIOS VM bit, BGRT). It is not applied to the host's `pve-qemu-kvm`.

A `+pveN` machine-type suffix is stripped only on the side-binary path. Vanilla QEMU rejects it. Pin the guest to a type that tree knows anyway, such as `pc-q35-10.1`.

## Guest device compatibility

**Listed guests cannot use virtio devices unless the guest has drivers that match the rewritten IDs.** The device-identity patch rewrites PCI vendor and device IDs on the side binary. Everything that was `1af4:*` (the virtio vendor) is reported as `8086:*`, and the Windows virtio drivers bind by the `1af4` IDs, so they do not load. In a Windows 10 test guest (side QEMU 10.2.2 with the patch, real host) that meant:

- With a **virtio-scsi** disk, OVMF reported `No bootable option` on `scsi0`, and Windows Setup also failed on the disk.
- The **virtio-serial** channel behind the guest agent (qemu-ga) was lost.
- A **virtio-net** NIC would show as `8086:1000`; the test guest used e1000e instead.

A listed guest therefore needs **non-virtio devices**: a SATA or NVMe disk, an e1000e NIC, and no reliance on virtio-balloon or qemu-ga. e1000e (82574L) is the NIC that was tested and verified on the side QEMU. Other emulated NICs (rtl8139, e1000, vmxnet3) are untested here and are not recommended without a test; note that vmxnet3 has no inbox Windows driver, so a fresh Windows install would be left without a network. NVMe is also untested (no row below). The other option is a guest driver that matches the spoofed IDs.

**Switch the guest's devices before you add it to the list.** Do it on the vendor QEMU (the guest is not yet in `/etc/qemu-ad/vms`), so the guest OS installs the SATA and e1000e drivers while it still boots normally. Only then run `add-vm`. In practice, for Windows:

1. With the guest still unlisted, move the disk to SATA (`sata0`) and the NIC to `e1000e`, set `balloon: 0`, and turn the guest agent off in the VM options. Boot it and let Windows install the drivers.
2. Shut down, then `./qemu-ad-pve.sh add-vm <vmid>`.
3. For a new Windows install, do the install itself on SATA and e1000e on the vendor QEMU (Windows Setup has the AHCI and e1000e drivers built in), and only then add the guest.

`del-vm` restores the normal IDs: the patch is applied only to the side binary, and a guest that is not listed runs on the vendor binary (`pve-qemu-kvm`), which reports `1af4` as usual. Switch back to virtio devices after `del-vm` if you want them again (the guest then needs the virtio drivers still installed).

`add-vm <vmid>` and `showcmd <vmid>` (for a listed VMID) read `/etc/pve/qemu-server/<vmid>.conf` and print a `WARNING` line on stdout for each of these:

- a virtio disk (`virtio0:` and so on);
- `scsihw: virtio-scsi-pci` or `virtio-scsi-single` together with a `scsiN:` disk (the PVE default `scsihw` is `lsi`, which is not warned about);
- an explicit virtio NIC (`net0: virtio=...`);
- `balloon: N` with N other than 0;
- the guest agent enabled (`agent: 1` or `agent: enabled=1`), because the qemu-ga channel is a virtio-serial port. `type=isa` is not warned about.

The warning changes nothing: `add-vm` still adds the guest and `showcmd` still prints, and the exit status is the same. Only the current config is read, up to the first `[snapshot]` section. If the file is missing or unreadable the check is skipped without a message. The directory can be changed with `PVE_QEMU_CONF_DIR` (default `/etc/pve/qemu-server`); the tests use it. It is a check of the config lines only: it does not look at `args:` lines or at devices that Proxmox adds by default. **Ballooning is on by default in Proxmox** when the config has no `balloon:` line, so a guest without `balloon: 0` can still get a virtio-balloon device without a warning. Set `balloon: 0` explicitly. When the config has no `balloon:` line, `add-vm` and `showcmd` print one `INFO:` line (not a `WARNING`) saying so; it is only printed when the config file was read.

### Device table

Vendor ID is what the guest sees on the vendor QEMU; side ID is what it sees on the side QEMU. Rows come from PCI listings of a Windows 10 guest on both binaries (guest device manager and QEMU `info pci`). Rows marked *inferred* were not observed and follow from the same rewrite.

| Device | Vendor ID | Side ID | Works on the side QEMU? |
| --- | --- | --- | --- |
| virtio-scsi-pci | `1af4:1004` | `8086:1004` | No. Guest vioscsi does not bind; OVMF: `No bootable option`; Windows Setup fails on the disk |
| virtio-serial (qemu-ga channel) | `1af4:1003` | `8086:1003` | No. The qemu-ga channel is lost (the device exists, the guest driver does not bind) |
| virtio-net | `1af4:1000` | `8086:1000` | No (inferred: the driver binds by `1af4`; the test guest switched to e1000e before trying it) |
| virtio-blk (`virtioN:`) | `1af4:*` (inferred) | `8086:*` (inferred) | No (inferred: same rewrite; not tested, exact IDs not recorded) |
| virtio-balloon | `1af4:*` (inferred) | `8086:*` (inferred) | No (inferred: same rewrite; not tested, exact IDs not recorded) |
| AHCI SATA controller (ICH9) | `8086:2922` | `8086:2922` | Yes. SATA disk boots and installs |
| e1000e NIC (82574L) | `8086:10d3` | `8086:10d3` | Yes |
| PCIe root port (`pcie-root-port`) | `1b36:000c` | `8086:000c` | Yes (only the ID changes; no guest driver needed) |
| PCI bridge (`pci.N`) | `1b36:0001` | `8086:0001` | Yes (only the ID changes) |
| Standard VGA | `1234:1111` | not present with `vga none` | n/a. Test guests used `vga none` with a passed-through GPU |
| ICH9 LPC (`2918`), AHCI (`2922`), SMBus (`2930`), USB UHCI/EHCI (`2934` to `2939`, `293a`, `293c`), HD audio (`293e`), host bridge (`29c0`) | subsystem `1af4:1100` | subsystem `8086:8086` | Yes (only the subsystem ID changes; the device ID stays `8086:xxxx`) |

By default the patched side binary reports an ASUS M4A88TD-M board in SMBIOS (the patch's built-in default for PC machine types; override it per guest with `-smbios` in `args:`). Passed-through devices (for example a GPU, with its own `10de:xxxx` ID) keep their own IDs.

## Install

Run on the Proxmox node, as root.

```bash
./qemu-ad-pve.sh install
./qemu-ad-pve.sh add-vm 100
qm set 100 --machine pc-q35-10.1
qm set 100 --cpu host,hidden=1,hv-vendor-id=GenuineIntel
./qemu-ad-pve.sh showcmd 100
qm start 100
```

`install` is safe to re-run. It installs build dependencies, shallow-clones the patch repository into `/opt/src/qemu-anti-detection`, downloads the matching QEMU tarball, applies `qemu-10.2.2.patch`, and builds with `--prefix=/opt/qemu-ad`. A stamp file stops a second run from reapplying the patch. Set `FORCE_REBUILD=1` to build again.

`hidden=1` is the stock Proxmox CPU flag. Proxmox turns it into `kvm=off` on the `-cpu` line, which hides the KVM signature leaf. It does not by itself clear the CPUID hypervisor bit. SMBIOS manufacturer and product strings still have to be passed in the guest's `args:` line. PCI passthrough stays a normal `hostpci` line. Do not assign that same PCI address to another guest.

## Commands

| Command | Effect |
| --- | --- |
| `install` | Dependencies, fetch, patch, build, divert, wrapper |
| `add-vm <vmid>` | Route that guest to the side binary |
| `del-vm <vmid>` | Route that guest back to `pve-qemu-kvm` |
| `showcmd <vmid>` | Print the vendor argv and the stripped side argv |
| `status` | Prefix, divert, and listed VMIDs |
| `uninstall` | Restore `/usr/bin/kvm`, leave `/opt/qemu-ad` |
| `uninstall --purge` | Also remove `/opt/qemu-ad` and the VMID list |

Overrides (environment variables): `QEMU_VER`, `PREFIX`, `SRC_ROOT`, `FORCE_REBUILD` (set to `1`), `PATCH_REPO`, `TARBALL_URL`, `LIST_FILE`, `WRAPPER_PATH`, `VENDOR_PATH`, `LOG_FILE`, `QEMU_SHA256`, `PATCH_SHA256`, `DPKG_LOCK` (the dpkg lock file that `install`/`uninstall` check before touching the divert; default `/var/lib/dpkg/lock-frontend`), `PVE_QEMU_CONF_DIR` (where `add-vm` and `showcmd` read `<vmid>.conf` for the virtio warning; default `/etc/pve/qemu-server`). `./qemu-ad-pve.sh help` lists them all. `LIST_FILE` and `PREFIX` are also what `uninstall --purge` deletes, so both are checked against an allow-list first: `PREFIX` must be a directory below `/opt`, `/srv` or `/usr/local` (not one of the standard `/usr/local` subdirectories such as `bin` or `share`), and `LIST_FILE` must be a file under `/etc/qemu-ad` or `/var/lib/qemu-ad` (removed with `rm -f`; a directory is refused). If `--purge` refuses your `LIST_FILE`, nothing has been changed: run plain `uninstall` and delete the file by hand. Non-canonical spellings (`..`, `//`, a trailing `/`, a `.` component such as `/./` or a trailing `/.`) are rejected for both. The patch file name and the tarball version must match. The default is 10.2.2 because that is the patch this script asks the cloned repo for.

`install` checks the QEMU tarball and the patch file against pinned SHA-256 values for 10.2.2 and stops on a mismatch. For another `QEMU_VER` there is no built-in pin: the script warns and continues, or you can export `QEMU_SHA256` and `PATCH_SHA256` to enforce your own. `status` and a repeated `install` warn if the built side binary does not report `QEMU_VER`; set `FORCE_REBUILD=1` to rebuild.

## The VMID list file

`/etc/qemu-ad/vms` holds **one VMID per line**: digits only, no leading zeros. Use `add-vm` and `del-vm` rather than editing by hand. The wrapper, `add-vm`, `del-vm` and `showcmd` all use the same matching rule: a line matches when it is exactly the VMID, and leading or trailing whitespace and a trailing carriage return (CRLF line endings, from a file saved on Windows) are ignored. So `add-vm` on a CRLF list does not append a duplicate, and `del-vm` removes the CRLF line. Anything else on the line, such as a comment after the number, means that line does not match and the guest runs on the vendor binary (it still starts, just not on the side build). A line that starts with `#` is never matched. A missing or unreadable list also means everybody runs on the vendor binary.

## How the wrapper starts QEMU

The wrapper runs QEMU with `exec -a /usr/bin/kvm`, so the process reports `/usr/bin/kvm` as its program name even though the binary lives elsewhere. This matters: qemu-server only recognises a running VM when argv[0] ends in `kvm` or looks like `qemu-...`, and QEMU only enables KVM by default when it was started under a `kvm` name. Without it `qm status`, `qm stop` and friends do not see the guest, and a guest asking for `-cpu host` fails with "CPU model 'host' requires KVM".

On the side-binary path the wrapper removes options that vanilla QEMU does not understand and records each one in `/var/log/qemu-ad-wrapper.log` (`dropped=...`). Current list: `-id <vmid>` (a Proxmox-only dummy option). `+pveN` is also stripped, but only inside the value of `-machine` / `-M`. `./qemu-ad-pve.sh showcmd <vmid>` runs the same code, so what it prints is what would be exec'd.

## Vendor vs side version skew

`qm` builds the command line for the vendor `pve-qemu-kvm` (11.0.x at the time of writing), but a listed guest runs on the side QEMU (10.2.2). The wrapper only rewrites what it has to. Anything else that the newer vendor build accepts and the older side build does not is passed through and fails when QEMU starts, usually with a plain QEMU error. Unlisted guests are never affected.

| Option | Cause | Fix |
| --- | --- | --- |
| `-id <vmid>` | Vendor-only dummy option (a `pve-qemu` patch) | Handled: the wrapper drops it on the side path |
| `+pveN` in `-machine` / `-M` | Proxmox machine-type revision | Handled: stripped inside the `-machine` / `-M` value only |
| `-iscsi initiator-name=...` | Needs libiscsi in the side build | Handled: the side build uses `--enable-libiscsi` |
| argv[0] | qemu-server recognises its VM by argv[0] ending in `kvm` | Handled: the wrapper uses `exec -a /usr/bin/kvm` |
| `-vnc unix:...,password=on` fails with `Cipher backend does not support DES algorithm` | A side build without a crypto backend has no DES, so any guest with a VGA (the `qm create` default) fails | Fixed: the build uses `--enable-gcrypt --disable-gnutls` (`libgcrypt20-dev`). `install` rebuilds an existing side build that was made without it (see below) |
| `-spice`, `-device qxl*` (`qm set --vga qxl`) | Vendor-only: `-spice: invalid option` on 10.2.2. SPICE is in vanilla QEMU, but the side build is configured with `--disable-spice` (it installs no libspice) | Use `vga: std` (or `serial0`). `showcmd` prints a `WARNING` |
| machine `pc-q35-11.0`, `pc-i440fx-11.0` | The side tree only knows machine types up to 10.2: `unsupported machine type` | Pin the guest to `pc-q35-10.1` or `10.2`. An unversioned `q35` resolves to the side's newest and works. `showcmd` prints a `WARNING` |
| `rbd:` / `pbs:` drive paths and `-blockdev` with `driver=rbd`, `driver=pbs`, `alloc-track` or `zeroinit` (key=value or JSON) | `pbs`, `alloc-track`, `zeroinit` and `backup-dump-drive` are `pve-qemu` patches. `rbd` is in vanilla QEMU but the side build is configured with `--disable-rbd` (no librbd) | Keep listed guests on local/LVM/ZFS/file/iSCSI storage. `showcmd` prints a `WARNING` for these |
| `http(s)://` / `ftp(s)://` drives | In vanilla QEMU (`block/curl.c`), but the side build is configured with `--disable-curl` (no libcurl) | Use local files. Not detected by `showcmd` |
| CPU model `SapphireRapids-v5` (10.2.2 has `SapphireRapids` v1 to v4) and models or versions added after 10.2 | Newer in 11.0.x | Use `host` or an older model/version. `GraniteRapids`, `SierraForest`, `ClearwaterForest`, `EPYC-Turin` and the `avx10` flags exist in 10.2.2. |
| `-device usb-redir` | The side build is configured with `--disable-usb-redir` (no libusbredir) and `--disable-spice` | Not supported. Use `usb-host` passthrough instead |
| `-loadstate` (resume from a RAM snapshot) | Vendor-only option | Not available on listed guests. Use snapshots without RAM. `showcmd` prints a `WARNING` |

`./qemu-ad-pve.sh showcmd <vmid>` prints a `WARNING` line for a **listed** guest whose command line has `-spice`, a `qxl` device, a `pc-q35-N.M` / `pc-i440fx-N.M` machine newer than the side binary (its own `--version` is used), `-loadstate`, or an `rbd` / `pbs` / `alloc-track` / `zeroinit` drive (an `rbd:` / `pbs:` path, or a `driver=NAME` token or `"driver": "NAME"` member in `-blockdev`). A file or VM name that merely contains `rbd` does not warn. It is a simple string check on the `qm showcmd` output, not a guarantee that everything else will start.

### Crypto backend and rebuilding an older install

The side build also passes `--disable-spice --disable-rbd --disable-curl --disable-usb-redir`, so the result does not depend on which dev packages the build host happens to have. Changing the flag list changes the stamp, so an existing build made with other flags (for example one from before these `--disable-*` flags) is rebuilt by the next `install`.

**USB passthrough:** `-device usb-host` (`qm set <vmid> --usb0 host=<vid>:<pid>`) is supported: the side build uses `--enable-libusb` (`libusb-1.0-0-dev` is installed by `install`). `usb-redir` and SPICE are still not supported. The host needs access to `/dev/bus/usb` (QEMU runs as root under PVE, so this is normally fine). A real passthrough test needs a physical USB device on the host; the tier-1 tests only check the build flags, the dependency and the rebuild, not a device. An existing install built with `--disable-libusb` is rebuilt once by the next `install`, which also installs the new build dependency first. `usb-host` also needs the runtime library `libusb-1.0-0` at run time. It is pulled in by the `libusb-1.0-0-dev` build dependency, so keep it installed: run `apt-mark manual libusb-1.0-0` so that `apt autoremove` does not remove it later (the script does not do this for you).

Builds made before this check have no crypto backend, so a guest with a VGA/VNC console fails to start. `install` now rebuilds the side binary when it is missing the backend: it compares the configure flags recorded in `/opt/qemu-ad/.qemu-ad-configure-flags` with the current ones, and for a build that predates the stamp it checks with `ldd` that `libgcrypt` is linked. `status` prints a `WARNING` for the same condition. The first `install` and any rebuild is a full QEMU compile: it takes from about a minute on a fast 8-core machine (warm caches) to 30-60 minutes on small hosts, depending on CPU. `FORCE_REBUILD=1 ./qemu-ad-pve.sh install` forces one.

## Do not `apt remove pve-qemu-kvm` while diverted

With the divert active, `pve-qemu-kvm` owns `/usr/bin/kvm.pve`, and the wrapper at `/usr/bin/kvm` is not part of the package. Removing the package deletes `kvm.pve` but leaves the wrapper behind. Every guest that is not in `/etc/qemu-ad/vms` then fails to start, because the wrapper has no vendor binary to hand off to. Upgrades and reinstalls of `pve-qemu-kvm` are fine.

To remove the package, run `./qemu-ad-pve.sh uninstall` first, then remove it. To bring the setup back after a reinstall, run `./qemu-ad-pve.sh install` again (the build is reused).

### Recovery: the package was already removed

If `pve-qemu-kvm` was removed while the divert was active, `/usr/bin/kvm.pve` is gone, `/usr/bin/kvm` is still the wrapper, and `uninstall` refuses to run because there is no vendor binary to restore. `status` shows a `WARNING` for this state, and `install`/`uninstall` print the same hint. To recover:

```bash
apt install --reinstall pve-qemu-kvm   # dpkg writes the vendor binary back to /usr/bin/kvm.pve
./qemu-ad-pve.sh uninstall             # restore /usr/bin/kvm; or `install` to keep the setup
```

Then remove the package, if that is what you wanted, only after `uninstall` has run.

### Recovery: break-glass back-out

If `qemu-ad-pve.sh uninstall` cannot be used at all (the script is gone, the divert is half-applied, or it keeps failing), use the standalone `tools/qemu-ad-breakglass.sh`. It does not need `qemu-ad-pve.sh`, honours the same `PREFIX`, `SRC_ROOT`, `LIST_FILE`, `WRAPPER_PATH`, `VENDOR_PATH`, `LOG_FILE` and `DPKG_LOCK` overrides, and is idempotent. **It is a dry run unless you pass `--apply`.**

```bash
tools/qemu-ad-breakglass.sh                    # dry run: prints the plan and the current-state report, changes nothing
tools/qemu-ad-breakglass.sh --capture-prestate --apply   # optional: snapshot VM status/PIDs first (the verifier compares against it)
tools/qemu-ad-breakglass.sh --apply            # restore the real kvm, then remove the VMID list, wrapper log, PREFIX and build tree
tools/qemu-ad-breakglass.sh --verify           # read-only PASS/FAIL end-state report
# test node only, deliberate: also destroy the VMs in QAD_BREAKGLASS_VMIDS (see the list below)
QAD_BREAKGLASS_TEST_HOSTNAME=<this-node> QAD_BREAKGLASS_VMIDS="<vmid>" QAD_PROTECTED_VMIDS=none \
  tools/qemu-ad-breakglass.sh --apply --destroy-vms [--clear-vm-protection]
```

It restores the real `/usr/bin/kvm` first (removes the divert and moves `kvm.pve` back; reinstalls `pve-qemu-kvm` or, as a last resort, symlinks the packaged binary if the vendor file is gone) and removes the side QEMU only if that worked. A divert that is not ours is left alone. Guests are not touched by default. Destroying VMs is meant for a **dedicated test node only** and needs all of the following, none of which is implied by another:

- the `--destroy-vms` flag **and** `QAD_BREAKGLASS_VMIDS="<vmid> ..."` (either alone is refused, so an inherited environment variable never destroys anything);
- `QAD_PROTECTED_VMIDS="<vmid> ..."` (or the word `none`); a VMID in both lists is refused (leading zeros are normalised: `07001` is `7001`);
- `QAD_BREAKGLASS_TEST_HOSTNAME` equal to the node's `hostname`, `qm list` readable, the node not in a cluster, and every VM on the node named in one of the two lists;
- a typed confirmation: the tool prints a phrase with a fresh random token (`destroy <vmids> on <hostname> <token>`) and reads your answer from the terminal; it refuses when stdin is not a terminal, so `yes |`, `</dev/null` and cron cannot confirm;
- each target must be provably `stopped` right before `qm destroy`, and every `qm` call is checked: any failure (an unreadable `qm list`/`status`/`config`, a failed `stop` or `destroy`) exits 1 and leaves the kvm wrapper alone;
- a VM with PVE's own `protection` flag is only destroyed if you also pass `--clear-vm-protection`.

`--capture-prestate` fails (and writes nothing) if any `qm` call fails. The tool refuses to write to a block or character device (or anything under `/dev`, `/proc`, `/sys`), refuses paths with characters other than letters, digits and `. _ / + @ : -`, refuses a `PREFIX` that contains or nests with `SRC_ROOT`, the wrapper, the list, the log or the state dir, only deletes a `PREFIX` that looks like ours (has `bin/qemu-system-x86_64` or the build stamp, or is empty), and refuses `PREFIX`/`LIST_FILE` outside the same allow-lists as `uninstall --purge`. Run `tools/qemu-ad-breakglass.sh --help` for the full list. Tests: `tests/breakglass-test.sh` (stubs only, see `tests/README.md`).

## Upstream

The device-identity patch is not vendored here. `install` clones [qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection) and applies the patch that matches `QEMU_VER`. QEMU itself is downloaded from `https://download.qemu.org`. Both remain under their own licenses.
