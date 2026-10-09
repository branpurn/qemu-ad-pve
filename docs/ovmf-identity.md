# Firmware identity: `SystemBiosVersion`, OVMF vendor string, ACPI OEM IDs

Lab/dev software-compatibility aid (some software reads these values and expects ordinary PC hardware).
Nothing here is applied by `setup.sh`; it is a build recipe plus an honest list of what can and cannot be changed.

## Where the Windows values come from

`HKLM\HARDWARE\DESCRIPTION\System\SystemBiosVersion` (REG_MULTI_SZ) on the L2 today:

| string | comes from | can it be changed? |
|---|---|---|
| `INTEL  - 1` | ACPI FADT OEM ID + OEM revision | **yes, at run time** with the optional QEMU patch `0002-acpi-oem-id-table-id-revision` (PR #34): `-machine q35,x-oem-id=ALASKA,x-oem-table-id='A M I   ',x-oem-revision=0x1072009`. Without the patch the base anti-detection patch hardcodes `INTEL`/`PC8086`/1. |
| `1654` | SMBIOS type 0 BIOS Version | **yes, already** (`l2.smbios = asus-am5`, PR #32) |
| `Debian distribution of EDK II - 10000` | EFI System Table `FirmwareVendor` + `FirmwareRevision` (hex) | **only by rebuilding OVMF**: both are build-time PCDs (`PcdFirmwareVendor`, `PcdFirmwareRevision`). Debian's `debian/rules` sets the vendor to `<LSB vendor> distribution of EDK II`. No QEMU option, SMBIOS field or fw_cfg item changes it, and the string sits inside the LZMA-compressed DXE firmware volume, so patching the shipped `OVMF_CODE_4M.fd` in place is not practical. |

`HKLM\HARDWARE\DESCRIPTION\System\BIOS` (`BIOSVendor`, `BIOSVersion`, `BIOSReleaseDate`) is SMBIOS type 0 and is already
the AMI values from `l2.smbios`.

The firmware also installs its own ACPI **BGRT** table (second `BGRT`, OEM `INTEL` / table `EDK2` / rev 2), taken from
`PcdAcpiDefaultOemId` / `PcdAcpiDefaultOemTableId` / `PcdAcpiDefaultOemRevision`; those are PCDs too.

## Build a modified OVMF (scratch host only)

```
# Debian 13 scratch VM/container, NOT the Proxmox host (the script refuses when it sees /etc/pve).
# deb-src must be enabled (Types: deb deb-src in /etc/apt/sources.list.d/debian.sources; apt-get update).
scripts/ovmf-identity/build-ovmf-identity.sh            # defaults: AMI vendor, rev 0x5001B, ALASKA / A M I / 0x1072009
OVMF_VENDOR="American Megatrends International, LLC." OUT=/root/ovmf-ami scripts/ovmf-identity/build-ovmf-identity.sh
scripts/ovmf-identity/build-ovmf-identity.sh --print-pcd   # only print the PCD flags (no root, no network)
```

It runs `apt-get build-dep edk2` + `apt-get source edk2` and `make -f debian/rules build-ovmf` with `PCD_FLAGS`
replaced, and copies `OVMF_CODE_4M.fd` / `OVMF_VARS_4M.fd` to `$OUT`. A full build (CODE, secboot, strictnx and the
pre-enrolled variable stores) took about 5 minutes on 12 vCPUs. Inputs are validated (no shell metacharacters).

## Try it on the L2 (steps only, not done by the repo)

`start-l2.sh` boots `-drive if=pflash,...,file=/root/l2/OVMF_CODE.fd` with the persistent `/root/w10/VARS.fd`.

1. `systemctl stop w10-l2.service` (clean ACPI shutdown).
2. `cp /root/l2/OVMF_CODE.fd /root/l2/OVMF_CODE.fd.orig`; copy the new `OVMF_CODE_4M.fd` over `/root/l2/OVMF_CODE.fd`.
   Keep the existing `VARS.fd` (same 4M layout; Windows' boot entry lives there).
3. `systemctl start w10-l2.service`; check `SystemBiosVersion` and that the GPU is still Code 0 (`setup.sh verify`).
4. Revert: copy `OVMF_CODE.fd.orig` back and restart.

## Tested (scratch VM, no GPU, nothing on the live stack)

Debian 13 scratch VM; QEMU 10.2.2 with the base patch + optional patches (PR #34); Debian cloud image booted from AHCI
on q35 with the rebuilt `OVMF_CODE_4M.fd`; tables from `/sys/firmware/acpi/tables`, firmware vendor from `dmesg`:

| | stock Debian OVMF | rebuilt OVMF + QEMU `-machine x-oem-*` |
|---|---|---|
| `dmesg`: `efi: EFI v2.7 by ...` | `Debian distribution of EDK II` | `American Megatrends International, LLC.` |
| BGRT (firmware's own table) OEM / table / rev | `INTEL` / `EDK2    ` / 0x2 | `ALASKA` / `A M I   ` / 0x1072009 |
| FACP/APIC/DSDT/HPET/MCFG OEM / table / rev (QEMU) | `INTEL` / `PC8086  ` / 0x1 | `ALASKA` / `A M I   ` / 0x1072009 |

Not tested: the Windows registry value itself (no Windows scratch guest) and the live L2 (would swap the firmware file);
`FirmwareRevision` was set (`0x5001B`) but is only visible to Windows. Secure Boot variants (`*.secboot*.fd`) are built
too, but the L2 uses the non-secboot image.

`tests/ovmf-identity-test.sh` covers the flag generation and input validation offline.
