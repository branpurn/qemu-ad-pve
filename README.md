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

## Install

Run on the Proxmox node, as root.

```bash
./qemu-ad-pve.sh install
./qemu-ad-pve.sh add-vm 200
qm set 200 --machine pc-q35-10.1
qm set 200 --cpu host,hidden=1,hv-vendor-id=GenuineIntel
./qemu-ad-pve.sh showcmd 200
qm start 200
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

Overrides (environment variables): `QEMU_VER`, `PREFIX`, `SRC_ROOT`, `FORCE_REBUILD` (set to `1`), `PATCH_REPO`, `TARBALL_URL`, `LIST_FILE`, `WRAPPER_PATH`, `VENDOR_PATH`, `LOG_FILE`, `QEMU_SHA256`, `PATCH_SHA256`, `DPKG_LOCK` (the dpkg lock file that `install`/`uninstall` check before touching the divert; default `/var/lib/dpkg/lock-frontend`). `./qemu-ad-pve.sh help` lists them all. `LIST_FILE` and `PREFIX` are also what `uninstall --purge` deletes, so both are checked against an allow-list first: `PREFIX` must be a directory below `/opt`, `/srv` or `/usr/local` (not one of the standard `/usr/local` subdirectories such as `bin` or `share`), and `LIST_FILE` must be a file under `/etc/qemu-ad` or `/var/lib/qemu-ad` (removed with `rm -f`; a directory is refused). If `--purge` refuses your `LIST_FILE`, nothing has been changed: run plain `uninstall` and delete the file by hand. Non-canonical spellings (`..`, `//`, a trailing `/`, a `.` component such as `/./` or a trailing `/.`) are rejected for both. The patch file name and the tarball version must match. The default is 10.2.2 because that is the patch this script asks the cloned repo for.

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
| `usb-host`, `usb-redir` | The side build is configured with `--disable-libusb --disable-usb-redir` (no libusb / libusbredir) | USB passthrough needs a side build with those libraries and the flags removed from `QAD_CONFIGURE_FLAGS` |
| `-loadstate` (resume from a RAM snapshot) | Vendor-only option | Not available on listed guests. Use snapshots without RAM. `showcmd` prints a `WARNING` |

`./qemu-ad-pve.sh showcmd <vmid>` prints a `WARNING` line for a **listed** guest whose command line has `-spice`, a `qxl` device, a `pc-q35-N.M` / `pc-i440fx-N.M` machine newer than the side binary (its own `--version` is used), `-loadstate`, or an `rbd` / `pbs` / `alloc-track` / `zeroinit` drive (an `rbd:` / `pbs:` path, or a `driver=NAME` token or `"driver": "NAME"` member in `-blockdev`). A file or VM name that merely contains `rbd` does not warn. It is a simple string check on the `qm showcmd` output, not a guarantee that everything else will start.

### Crypto backend and rebuilding an older install

The side build also passes `--disable-spice --disable-rbd --disable-curl --disable-libusb --disable-usb-redir`, so the result does not depend on which dev packages the build host happens to have. Changing the flag list changes the stamp, so an existing build made with other flags (for example one from before these `--disable-*` flags) is rebuilt by the next `install`.

Builds made before this check have no crypto backend, so a guest with a VGA/VNC console fails to start. `install` now rebuilds the side binary when it is missing the backend: it compares the configure flags recorded in `/opt/qemu-ad/.qemu-ad-configure-flags` with the current ones, and for a build that predates the stamp it checks with `ldd` that `libgcrypt` is linked. `status` prints a `WARNING` for the same condition. The rebuild takes a minute or two on 8 vCPUs; `FORCE_REBUILD=1 ./qemu-ad-pve.sh install` forces one.

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

## Upstream

The device-identity patch is not vendored here. `install` clones [qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection) and applies the patch that matches `QEMU_VER`. QEMU itself is downloaded from `https://download.qemu.org`. Both remain under their own licenses.
