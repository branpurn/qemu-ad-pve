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

`hidden=1` is the stock Proxmox CPU flag. It clears the hypervisor bit. SMBIOS manufacturer and product strings still have to be passed in the guest's `args:` line. PCI passthrough stays a normal `hostpci` line. Do not assign that same PCI address to another guest.

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

Overrides: `QEMU_VER`, `PREFIX`, `SRC_ROOT`, `FORCE_REBUILD=1`. The patch file name and the tarball version must match. The default is 10.2.2 because that is the patch this script asks the cloned repo for.

## Upstream

The device-identity patch is not vendored here. `install` clones [qemu-anti-detection](https://github.com/zhaodice/qemu-anti-detection) and applies the patch that matches `QEMU_VER`. QEMU itself is downloaded from `https://download.qemu.org`. Both remain under their own licenses.
