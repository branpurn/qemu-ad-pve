# Optional QEMU patches (WAET, ACPI OEM identity)

Lab/dev software-compatibility aid: some software reads the ACPI tables and the registry values Windows derives
from them. Two small, **optional** patches on top of the qemu-anti-detection patch (`qemu-10.2.2.patch`) are
carried in `patches/optional/qemu-10.2.2/`. They are **off by default**: without `QAD_OPTIONAL_PATCHES` the build,
the build stamp and the binary are exactly what they were before.

| name | what it does |
|---|---|
| `0001-acpi-omit-waet` | QEMU adds the ACPI **WAET** (Windows ACPI Emulated Devices Table) unconditionally at the end of `acpi_build()` in `hw/i386/acpi-build.c`; the patch drops the `acpi_add_table()` + `build_waet()` pair (the function stays, marked unused). No machine property: the table is gone from the binary. |
| `0002-acpi-oem-id-table-id-revision` | The base patch hardcodes OEM ID `INTEL `, OEM table ID `PC8086  ` and OEM revision `1` in `acpi_table_begin()`, so the stock machine properties `x-oem-id` / `x-oem-table-id` had no effect. This patch honours them again (their defaults are the same `INTEL `/`PC8086  `, so default behaviour is identical) and adds `x-oem-revision` (uint32, default 1; hex such as `0x1072009` works). |

The two patches touch different files and are independent.

## Build

```
# in L1 (nested) or on a build host; the same script that builds the side QEMU
QAD_OPTIONAL_PATCHES=0001-acpi-omit-waet,0002-acpi-oem-id-table-id-revision \
PREFIX=/opt/qemu-ad-test SRC_ROOT=/root/scratch-patch/src ./qemu-ad-pve.sh build
```

* `QAD_OPTIONAL_PATCHES` is comma or space separated; unknown names are refused with the list of what exists.
* The applied set is recorded in `<source>/.qemu-ad-optional-patches`. A patch cannot be taken back out, so a source
  tree that carries a different set makes the script stop and ask you to move that tree away (it is re-extracted).
* The set is part of the build stamp (`<prefix>/.qemu-ad-configure-flags`, suffix ` # optional-patches=...`), so
  `install`/`build` rebuild when it changes. With no optional patches the stamp is unchanged, so existing builds are
  **not** rebuilt.
* Use a different `PREFIX` for a test build. Do not build over a QEMU that a running VM uses.

## Use on the Windows L2 (not done by the repo; steps only)

The live L2 runs `/opt/qemu-ad/bin/qemu-system-x86_64` (inside L1) from `w10-l2.service`. To try the patched binary
without touching that one:

1. Build into another prefix as above (e.g. `/opt/qemu-ad-optional`).
2. Shut the L2 down cleanly (`systemctl stop w10-l2.service`, which does an ACPI shutdown).
3. Start it with the new binary and, for the OEM identity, extra machine properties:
   `QB=/opt/qemu-ad-optional/bin/qemu-system-x86_64` in `/etc/qemu-ad-l2.env` (`start-l2.sh` reads `QB`), and
   `EXTRA="-machine q35,x-oem-id=ALASKA,x-oem-table-id='A M I   ',x-oem-revision=0x1072009"`
   (`-machine` options merge; pad the table ID with spaces to 8 characters, ACPI uses space padding).
4. Check inside Windows (PowerShell): `(Get-ItemProperty HKLM:\HARDWARE\DESCRIPTION\System).SystemBiosVersion`, and
   list the ACPI tables with any ACPI table viewer (WAET must be absent).
5. Revert: restore `QB`/`EXTRA` and restart.

Switching binaries on the L2 is a different machine from the one Windows activated and was installed on; changing
ACPI OEM IDs can trigger Windows to treat the platform as changed (re-activation prompts on OEM-licensed images).

## What was tested (scratch VM, no GPU, nothing on the live stack)

Scratch Debian 13 VM with its own build of QEMU 10.2.2 (base patch only) and of QEMU 10.2.2 + both optional patches,
each booting Debian 13 cloud image under OVMF on `q35` (AHCI disk: the base patch's virtio IDs are not recognised by
OVMF), tables read from `/sys/firmware/acpi/tables`:

| | base patch only | + both optional patches, `-machine q35,x-oem-id=ALASKA,x-oem-table-id=A\ M\ I,x-oem-revision=0x1072009` |
|---|---|---|
| table list | APIC BGRT1 BGRT2 DSDT FACP FACS HPET MCFG **WAET** | APIC BGRT1 BGRT2 DSDT FACP FACS HPET MCFG |
| FACP / APIC / DSDT / HPET / MCFG header | OEM `INTEL ` / `PC8086  ` / rev 0x1 | OEM `ALASKA` / `A M I` / rev 0x1072009 |
| BGRT2 (added by OVMF, not QEMU) | `INTEL ` / `EDK2    ` / rev 0x2 | unchanged (comes from the firmware, see `scripts/ovmf-identity`) |

Not tested: the Windows registry value `SystemBiosVersion` (no Windows scratch guest); its first string
(`INTEL  - 1` today) is built by Windows from the FADT OEM ID and OEM revision, so it is expected to become
`ALASKA - 1072009`; confirm on the L2 with step 4.
