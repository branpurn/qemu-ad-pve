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

## Use on the Windows L2

`setup.sh` (opt-in, default off): set `l2.optional_patches` (and `l2.oem_id`, `l2.oem_table_id`, `l2.oem_revision`),
run `setup.sh install` (step `l1_optional_qemu` builds `/opt/qemu-ad-optpatch` inside L1, `l1_scripts` writes
`QB=` and `OEM_*` into `/etc/qemu-ad-l2.env`). `start-l2.sh` turns `OEM_ID` / `OEM_TABLE_ID` / `OEM_REVISION` into
`-machine q35,accel=kvm,x-oem-id=...,x-oem-table-id=...,x-oem-revision=...`.

By hand on a running stack (this is what was live-tested, see below):

1. Build in a **scratch VM** (not in the running L1) with `QAD_OPTIONAL_PATCHES=... PREFIX=/opt/qemu-ad-optpatch
   ./qemu-ad-pve.sh build` and copy the tree to the same path in L1 (`tar -C /opt -c qemu-ad-optpatch | ssh L1 tar -C /opt -x`;
   same Debian 13 userland, no missing libraries).
2. In L1 back up `/etc/qemu-ad-l2.env` and `/root/w10/start-l2.sh`; append to `/etc/qemu-ad-l2.env`:
   `QB=/opt/qemu-ad-optpatch/bin/qemu-system-x86_64`, `OEM_ID=ALASKA`, `OEM_TABLE_ID="A M I   "`, `OEM_REVISION=0x1072009`.
3. `systemctl restart w10-l2`, then check inside Windows: `SystemBiosVersion`, and the ACPI tables
   (`GetSystemFirmwareTable('ACPI')` from Python/ctypes; WAET must be absent).
4. Revert: restore the env file backup (or delete the lines above) and `systemctl restart w10-l2`; `/opt/qemu-ad` was never touched.

Do **not** put the OEM options into `EXTRA`: `start-l2.sh` word-splits `EXTRA` (quotes are not honoured, so a table
ID with spaces breaks), and QEMU pads the table ID with NUL bytes, not spaces; pass it padded to 8 characters
(`"A M I   "`) through `OEM_TABLE_ID`, which keeps the spaces.

Switching binaries on the L2 is a different machine from the one Windows activated and was installed on; changing
ACPI OEM IDs can trigger Windows to treat the platform as changed (re-activation prompts on OEM-licensed images).
Live result 2026-10-09 on the L2 (Windows 10): booted normally, GPU Code 0, torch fp32 ~34.5 / fp16 ~101 TFLOP/s,
verify PASS, full `qm shutdown`/`qm start` cycle fine; no activation prompt was observed.

## What was tested (scratch VM, no GPU, nothing on the live stack)

Scratch Debian 13 VM with its own build of QEMU 10.2.2 (base patch only) and of QEMU 10.2.2 + both optional patches,
each booting Debian 13 cloud image under OVMF on `q35` (AHCI disk: the base patch's virtio IDs are not recognised by
OVMF), tables read from `/sys/firmware/acpi/tables`:

| | base patch only | + both optional patches, `-machine q35,x-oem-id=ALASKA,x-oem-table-id=A\ M\ I,x-oem-revision=0x1072009` |
|---|---|---|
| table list | APIC BGRT1 BGRT2 DSDT FACP FACS HPET MCFG **WAET** | APIC BGRT1 BGRT2 DSDT FACP FACS HPET MCFG |
| FACP / APIC / DSDT / HPET / MCFG header | OEM `INTEL ` / `PC8086  ` / rev 0x1 | OEM `ALASKA` / `A M I` / rev 0x1072009 |
| BGRT2 (added by OVMF, not QEMU) | `INTEL ` / `EDK2    ` / rev 0x2 | unchanged (comes from the firmware, see `scripts/ovmf-identity`) |

Live L2 (Windows 10): `SystemBiosVersion` first string went from `INTEL  - 1` to `ALASKA - 1072009`; the WAET table
is gone from `GetSystemFirmwareTable('ACPI')` (tables seen before: MCFG FACP APIC WAET HPET BGRT, all
`INTEL ` / `PC8086  ` / rev 1; after: MCFG FACP APIC HPET BGRT, all `ALASKA` / `A M I   ` / rev 0x1072009).
