# Firmware identity: `SystemBiosVersion`, OVMF vendor string, ACPI OEM IDs

Lab/dev software-compatibility aid (some software reads these values and expects ordinary PC hardware).
`setup.sh install` runs this build **by default inside L1** (step `l1_ovmf_identity`, about 5 min; opt out with `l2.ovmf_identity=no`; `l2.oem_*` set the ACPI OEM ids; `l2.ovmf_identity_dir` installs a prebuilt image instead). This is a build recipe plus an honest list of what can and cannot be changed.

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

## Use on the L2

`setup.sh` (default: built in L1 automatically; the rest of this paragraph is the `l2.ovmf_identity_dir` alternative): build the image in a scratch VM, put `OVMF_CODE_4M.fd` in a directory on the PVE host
and set `l2.ovmf_identity_dir` to it. Step `l1_ovmf_identity` copies it (sha256-checked) to `L1:/opt/ovmf-identity/OVMF_CODE.fd`
and `l1_scripts` adds `OVMF_CODE=/opt/ovmf-identity/OVMF_CODE.fd` to `/etc/qemu-ad-l2.env`. The shipped
`/root/l2/OVMF_CODE.fd` and the persistent `/root/w10/VARS.fd` are not touched.

By hand (live-tested 2026-10-09; the old firmware file stays where it is, nothing is overwritten):

1. Copy the build to L1 at a new path: `/opt/ovmf-identity/OVMF_CODE.fd`.
2. Back up `/etc/qemu-ad-l2.env`, `/root/w10/VARS.fd`, `/root/l2/OVMF_CODE.fd`; append `OVMF_CODE=/opt/ovmf-identity/OVMF_CODE.fd`
   to the env file (`start-l2.sh` reads `OVMF_CODE` and `OVMF_VARS`, defaults are the old paths).
3. `systemctl restart w10-l2`; check `SystemBiosVersion` and `setup.sh verify`.
4. Revert: remove that line (or restore the env backup) and restart.

**Keep the existing `VARS.fd`.** The rebuilt `OVMF_CODE` has the same 4M layout; Windows booted straight from the
existing NVRAM (boot entry intact, no re-add needed, full shutdown/start cycle fine). The new `OVMF_VARS_4M.fd` is an
empty template with no Windows boot entry; do not switch to it on an installed L2.

## Tested (scratch VM, no GPU, nothing on the live stack)

Debian 13 scratch VM; QEMU 10.2.2 with the base patch + optional patches (PR #34); Debian cloud image booted from AHCI
on q35 with the rebuilt `OVMF_CODE_4M.fd`; tables from `/sys/firmware/acpi/tables`, firmware vendor from `dmesg`:

| | stock Debian OVMF | rebuilt OVMF + QEMU `-machine x-oem-*` |
|---|---|---|
| `dmesg`: `efi: EFI v2.7 by ...` | `Debian distribution of EDK II` | `American Megatrends International, LLC.` |
| BGRT (firmware's own table) OEM / table / rev | `INTEL` / `EDK2    ` / 0x2 | `ALASKA` / `A M I   ` / 0x1072009 |
| FACP/APIC/DSDT/HPET/MCFG OEM / table / rev (QEMU) | `INTEL` / `PC8086  ` / 0x1 | `ALASKA` / `A M I   ` / 0x1072009 |

Live L2 (Windows 10, 2026-10-09): `SystemBiosVersion` third string went from `Debian distribution of EDK II - 10000` to
`American Megatrends International, LLC. - 5001B` (revision shown in hex without `0x`); GPU Code 0, torch fp32 ~34.6-34.8 / fp16 ~101,
verify PASS, full shutdown/start cycle fine. `HKLM\\...\\System\\BIOS` (`BIOSVendor`/`BIOSVersion`/`BIOSReleaseDate`) comes from SMBIOS and did not change.
Note: the build script's `OVMF_VERSION_STRING`/`OVMF_RELEASE_DATE` are not what Windows shows there. Secure Boot variants (`*.secboot*.fd`) are built
too, but the L2 uses the non-secboot image.

`tests/ovmf-identity-test.sh` covers the flag generation and input validation offline.
