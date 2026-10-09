# Bare-metal appearance (lab/dev software compatibility)

Some lab software (licensing checks, vendor tools, drivers that refuse to start in a VM) behaves differently when
the machine looks virtual. `setup.sh` therefore makes the L1 and the Windows L2 look like an ordinary desktop
(ASUS ROG STRIX X670E-E, Ryzen 9 7950X) **by default**, with no extra flags. This is a software-compatibility aid for
a lab; it is not a way to defeat anti-cheat or other integrity systems and has not been tested for that.

## What is hidden by default

| What | L1 / L2 | Default setting | Where it is implemented |
|---|---|---|---|
| CPUID leaf 1 ECX bit 31 (hypervisor) clear, KVM leaf 0x40000000 empty, `HypervisorPresent=False` | L2 | `l2.cpu = host,-hypervisor,kvm=off` | `setup/qad_setup/config.py` -> `QAD_L2_CPU` -> `/etc/qemu-ad-l2.env` `CPU=` -> `scripts/l1-w10/start-l2.sh` |
| Same for the L1 (`systemd-detect-virt` = `none`, no `hypervisor` in `/proc/cpuinfo`) | L1 | `l1.hide_hypervisor = yes` | `plan.qm_create` (`cpu: host,hidden=1` + `-cpu host,-hypervisor,kvm=off`) |
| SMBIOS 0 (AMI 1654 01/12/2024, "virtual machine" BIOS bit clear for L1), 1, 2, 3 (raw chassis type 3 Desktop, ASUSTeK), 4, 17 | L2 | `l2.smbios = asus-am5`, `l2.smbios_chassis = desktop` | `plan.l2_smbios`, `plan.l2_chassis_bin`, `qad-l1.sh scripts` (`smbios.txt`, `smbios-type3.bin`) |
| Same SMBIOS for the L1; types 0/3 as raw files | L1 | `l1.smbios = asus-am5` | `steps.s_l1_smbios`, `plan.l1_smbios_files/l1_smbios_args`, files in `/var/lib/qemu-ad/setup/smbios/` (removed by uninstall) |
| NIC MAC with an Intel OUI (NIC model e1000e = 82574L) | L2 | `l2.mac_oui = a4:bf:01` | `plan.l2_mac` |
| Disk model / serial / firmware (Samsung SSD 980 PRO 1TB) | L2 | `l2.disk_model`, `l2.disk_serial` (derived), `l2.disk_firmware` | `start-l2.sh` `DISKOPTS` |
| ACPI WAET table removed; ACPI OEM id / table id / revision `ALASKA` / `A M I` / `0x1072009` on every table QEMU writes | L2 | `l2.optional_patches` (both patches, built in L1) | `patches/optional/qemu-10.2.2/`, `steps.s_l1_optional_qemu`, docs/optional-qemu-patches.md |
| Registry `SystemBiosVersion` = `ALASKA - 1072009`, `1654`, `American Megatrends International, LLC. - 5001B` | L2 | `l2.ovmf_identity = yes` (OVMF built in L1) | `scripts/ovmf-identity/`, `steps.s_l1_ovmf_identity`, docs/ovmf-identity.md |
| QEMU PCI/chipset IDs rewritten | L2 | always (qemu-anti-detection patch) | `qemu-ad-pve.sh` |

The PVE host itself stays stock (no host package, kernel, modprobe or `storage.cfg` change).

## Opt-in / not default

* `l2.vga = std` is the default (needed to watch the install over VNC). It leaves an emulated "Standard VGA"
  adapter (PCI 1234:1111) visible in Windows. Set `l2.vga = none` after the install (edit `VGA=` in
  `/etc/qemu-ad-l2.env` in L1 and restart `w10-l2`) for the passed-through GPU as the only display.
* Every item above has an opt-out key (`none` / `no`); `setup.sh audit` then reports the changed expectation as INFO.

## Not feasible (not hidden, by design or limitation)

* **Monitor EDID**: with no physical monitor there is no EDID; Windows shows a generic or no monitor. A real model name would
  need a physical display or an EDID override on the GPU output, which a VM cannot provide.
* **Stale registry `Enum` keys**: Windows keeps device instance keys (`HKLM\SYSTEM\CurrentControlSet\Enum`) of the
  devices it saw during the install (e.g. Standard VGA, the QEMU/ICH9 devices); they stay until removed by hand or by a
  reinstall without them.
* **CD-ROM name**: the QEMU CD-ROM keeps its `QEMU DVD-ROM` model; the staging CD is only attached during install/first boot.
* PCI device list in general (Q35/ICH9 bridges, virtio/AHCI/e1000e controllers, USB tablet), timing behaviour (TSC,
  RDTSCP/latency measurements), the `QEMU` / `Bochs` strings in the DSDT/SSDT that Windows does not enumerate, and a
  hypervisor seen by anything that runs on the PVE host.

## `setup.sh audit`

Opt-in and read-only: `./setup.sh audit` (or `./setup.sh verify --audit`) runs `qad-l1.sh audit` in L1:

* `scripts/bare-metal-audit/l1-facts.sh`: `systemd-detect-virt`, `/proc/cpuinfo` hypervisor flag, DMI strings, chassis type;
* `l2-facts.ps1` (CIM: computer system, BIOS, board, enclosure/chassis, CPU, DIMM, disk, NIC, video + problem code) and `l2-facts.py`
  (CPUID leaf 1 / 0x40000000, ACPI table list and OEM fields via `GetSystemFirmwareTable`, BIOS registry strings; needs the staged Python venv)
  are copied to `C:\qad\audit\` in the L2 and run over the pinned SSH connection;
* `evaluate.py` compares the facts with the settings in `/etc/qemu-ad/setup.env` and prints `PASS`/`FAIL`/`INFO`/`SKIP` rows and
  `AUDIT=PASS|FAIL`. Raw facts stay in `/root/w10/audit-l1.txt` and `audit-l2.txt` in L1.

An unreachable L2 gives SKIP rows (and no FAIL) for the L2 part. Offline tests: `tests/setup/test_bare_metal_audit.py`.

## Live result

Clean default install of `main` on the lab host (AMD 7950X + RTX 4080, Windows 10 22H2, driver 576.88): every row of `setup.sh audit` passes (docs/setup-e2e-live-20261009-phaseG.md);
GPU Code 0, torch fp32 ~34.5 / fp16 ~101 TFLOP/s, and the result survives a full `qm shutdown` / `qm start` cycle.
