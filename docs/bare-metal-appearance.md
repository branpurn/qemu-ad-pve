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
| Optical drive named like a real one: Windows shows `ASUS DRW-24B1ST` (default) instead of the base patch's `ASUS ASUS DVD-ROM`; the same identity is used from the install on, and the staging ISO is ejected after the first successful verify (the empty drive stays; `stage.iso` stays in L1 for a reinstall) | L2 | `l2.cdrom_model`, `l2.cdrom_firmware`, `l2.detach_stage_iso` | `start-l2.sh` (`CDROM_MODEL`/`CDROM_VER`/`STAGE_ISO`), `qad-l2-create.sh`, optional QEMU patch `0003-atapi-inquiry-from-model` (needed because `ide-cd` takes `model=`/`ver=` but its INQUIRY strings are hardcoded), `qad-l1.sh detach-stage` |
| Emulated Standard VGA (PCI 1234:1111) gone: the RTX is the only display adapter (the L2 restarts once after the first successful verify; reverted automatically when verify, the display check (`vga-check.ps1`: RTX only, Code 0, `dwm.exe` running in the console session) fails) | L2 | `l2.vga_after_verify = none` | `qad-l1.sh finalize` (`vga.switched` marker, `VGA=none` in `/etc/qemu-ad-l2.env`) |
| Stale device instance keys of earlier identities removed (old CD-ROM instances, install-time `ASUS HARDDISK`, the Standard VGA after it is gone); keys exported to `/root/w10/ghost-backup/` in L1 first; present, NVIDIA, Samsung and volume entries are never touched | L2 | `l2.cleanup_ghosts = yes` | `setup/l1/windows/ghosts.ps1` as SYSTEM via a one-shot scheduled task (`qad-l1.sh ghosts`) |
| GPU root port ("rpg") advertises a CPU-like Gen4 x16 link instead of QEMU's Gen4 x32 default | L2 | `l2.gpu_link_speed = 16`, `l2.gpu_link_width = 16` (empty = QEMU default) | `start-l2.sh` (`GPU_LINK_SPEED`/`GPU_LINK_WIDTH` -> `pcie-root-port,...,x-speed=16,x-width=16`), `qad-l2-create.sh` |
| e1000e (82574L) subsystem `1043:8369` (a real ASUS onboard 82574L) instead of `8086:0000` | L2 | `l2.nic_subsystem = 1043:8369` (empty = QEMU default) | `start-l2.sh` (`NIC_SUBSYS_*` -> stock `subsys_ven`/`subsys`), `qad-l2-create.sh` |
| ICH9 LPC/AHCI/SMBus/USB and host bridge subsystem `1043:8877` (ASUS) instead of `8086:8086` | L2 | `l2.pci_subsystem = 1043:8877`, optional patch 0004 | `start-l2.sh` (`PCI_SUBSYS_*` -> `-global q35-pcihost.x-pci-sub-*`) |
| No QEMU USB tablet (`USB\VID_0627&PID_0001`) once the emulated VGA is off; the UHCI/EHCI controllers stay | L2 | `l2.usb_tablet = auto` (yes/no) | `start-l2.sh` (`USB_TABLET`), `qad-l1.sh scripts` |
| No hidden fw_cfg ACPI device (`ACPI\ASUS0002`, Code 28) | L2 | optional patch 0005 | `patches/optional/qemu-10.2.2/0005-acpi-omit-fwcfg-device.patch` |
| QEMU PCI/chipset IDs rewritten | L2 | always (qemu-anti-detection patch) | `qemu-ad-pve.sh` |
| No install residue: `C:\Windows\Panther\unattend.xml` (+ `UnattendGC`, `actionqueue`, Setup/Panther logs, other answer-file copies; the audit row looks at the answer files and `actionqueue`: Windows itself recreates a few hundred bytes of `Panther\UnattendGC` logs, without credentials, at every boot) removed | L2 | `l2.cleanup_unattend = yes` | `setup/l1/windows/hygiene.ps1` run by the `l2_finalize` step (`qad-l1.sh finalize`) after the first successful verify |
| No staging leftovers: `C:\qad\nvidia`, `python`, `openssh`, `firstlogon.*`, `gpu-driver.*`, `w10-code43-check.ps1` removed (kept: `venv`, `py`, `audit`, `authorized_keys`, `pytorch-offline-bench.py` which `setup.sh verify` runs; sshd and the admin account) | L2 | `l2.cleanup_staging = yes` | same script; skipped while the NVIDIA driver is not installed yet |

The PVE host itself stays stock (no host package, kernel, modprobe or `storage.cfg` change).

## Opt-in / not default

* `l2.vga = std` stays the install-time setting (the install is watched over VNC). `l2.vga_after_verify = none` (default)
  switches the emulated VGA off after the first successful verify, see the table. `keep` leaves "Standard VGA"
  (PCI 1234:1111) in Windows. With the VGA off there is no console image any more; normal L2 boots have no VNC anyway
  (the audit shows an INFO row for this).
* Every item above has an opt-out key (`none` / `no`); `setup.sh audit` then reports the changed expectation as INFO.

## Not feasible (not hidden, by design or limitation)

* **Monitor EDID** (tried live on the lab host, driver 576.88, VGA off): with no monitor attached the RTX reports no display
  target, so Windows has no real monitor node, only the placeholder `DISPLAY\Default_Monitor\...` entries ("Generic Non-PnP
  Monitor", `Win32_DesktopMonitor` = "Default Monitor", `WmiMonitorID` empty). (a) A registry EDID / `EDID_OVERRIDE\0` value written
  to those nodes (as SYSTEM, `setup/l1/windows/edid.ps1`, EDID from `setup/l1/edid.py`: valid checksum, ASUS/Dell 24" profile)
  survived an L2 restart but changed nothing: no monitor appeared and the names stayed generic. (b) NVIDIA has no documented
  per-output EDID override on GeForce/Windows (the `NvAPI_GPU_SetEdid` call is unsupported there; the undocumented
  `nvlddmkm\State\DisplayDatabase\EdidLockData` trick reportedly cannot be removed reliably and was deliberately not tried).
  (c) What works: a physical **HDMI/DisplayPort EDID emulator dongle** (EDID of a real monitor), or a third-party virtual
  display driver (IDD), which this project does not install. `l2.edid_monitor` (default `none`) keeps the experimental
  registry route available; the audit shows an INFO row with the monitor name Windows reports.
* **Stale registry `Enum` keys that are not device instances of the three classes above** (e.g. old volume entries,
  QEMU/ICH9 devices that are still present) stay; present devices cannot be removed.
* **CD-ROM name**: with the base patch alone the drive is `ASUS ASUS DVD-ROM` (not `QEMU DVD-ROM`); the realistic model needs optional patch 0003 (default on, built in L1). A QEMU built without it keeps `ASUS ASUS DVD-ROM` (the audit row is INFO then). Stale CD entries of earlier identities are removed by the stale-device cleanup.
* **PCI device list** (audited in the L2, 2026-10-10): what remains is the Intel Q35/ICH9 set (host bridge 29C0, LPC 2918, AHCI 2922, SMBus 2930, UHCI 2934-2936, EHCI 293A, e1000e 10D3)
  on a machine that claims an AMD AM5 board, the root port `rpg` as `8086:000C` (QEMU's "PCIe root port" ID, vendor rewritten by the base patch; subsystem `0000:8086`) and, as ICH9 revision/class
  values, whatever QEMU emulates. Windows' names for these ("Intel(R) ICH9 Family USB ...", "Standard SATA AHCI Controller", "LPC Controller") also occur on real PCs; no `1AF4`/`1B36`/`QEMU`
  string remains, and the subsystem IDs are ASUS (see the table). Not changed: changing the device/vendor ID of the chipset functions would change what drivers bind to, and changing the ID
  of `rpg` (the GPU's root port) would make Windows re-enumerate the GPU under a new parent: deliberately left alone on the passthrough path.
* **ACPI strings** (tables dumped in the L2 with `GetSystemFirmwareTable`, before and after patch 0005): FACP/APIC/HPET/MCFG/BGRT/XSDT/DSDT carry OEM `ALASKA` / `A M I` / rev `0x1072009`, ASL creator `PTL `;
  no `QEMU`, `BOCHS`, `BXPC`, `SeaBIOS`, `EDK II` string in any table (no SSDT is generated). The only QEMU-specific device in the AML that Windows enumerated was `FWCF` (`ASUS0002`, already renamed
  from `QEMU0002` by the base patch, with problem code 28): patch 0005 drops it. Still in the DSDT and left alone, because they are AML structures Windows binds drivers to or
  the root bus layout depends on: the `PNP0A08` PCI root bridge, `PNP0A06` "Extended IO Bus" resource devices (`CPU_HOTPLUG_RESOURCES`, `GPE0_RESOURCES`, `PCI_HOTPLUG_RESOURCES`), `ACPI0010`/`ACPI0006`,
  `PNP0C01`, and the field/method names (`CPEN`, `PCIU`, ...) which no Windows API exposes by name.
* **Timing (TSC, RDTSCP / latency measurements)** was not implemented (wave 2, item 6): under nested KVM (L0 PVE -> L1 -> L2) the guest's TSC is a virtualised/offset TSC and instruction timing includes two
  hypervisors' exits. Hiding that means trapping RDTSC/RDTSCP (`TSC exiting`) and faking a monotonic cost for CPUID/exits, which (a) costs performance on every timestamp read (Windows and CUDA read it constantly),
  (b) risks clock drift and watchdog/driver timeouts (the NVIDIA driver and Windows' timekeeping use it), and (c) cannot be made exact in software anyway; there is no low-risk setting, so nothing is changed and
  the CPUID hypervisor bits stay the only hiding done at the CPU level. A hypervisor seen by anything that runs on the PVE host stays visible as well.

## GPU PCIe link (what the guest sees, 2026-10-10 findings)

* On the lab host the RTX 4080 sits behind GPP bridge `00:01.5` whose own capability is **Gen4 x4** (`LnkCap` Port #3, 16GT/s x4): the physical slot
  is an x4 slot, so the card's `LnkCap` x16 shows as "x4 (downgraded)" on the host. At idle the link also drops to 2.5GT/s (ASPM L1 +
  GPU power state, target stays 16GT/s); under a torch load the host link is **16GT/s x4** (polled `lspci -vv` at 00:01.5 and 02:00.0 while
  the benchmark ran) and falls back when idle. Host ASPM policy is the kernel `default`; it was not touched.
* Inside the L2, `nvidia-smi` reports `pcie.link.gen.current` 1 at idle and 4 under load, `.gen.max` 4, `.width.current` 4, `.width.max` 16.
  NVML reads these from the GPU itself, not from the (emulated) PCI config space, so no QEMU option changes them and they are exactly what a real PC with
  this card in this x4 slot reports. Pinned 1 GiB host<->device copies: 6.7 GB/s both ways (the x4 Gen4 limit is about 7.9 GB/s).
* The L1 sees the GPU as a conventional PCI device behind `pcie-pci-bridge` (no PCI Express capability in `lspci -vv`); this arrangement is what
  makes passthrough + vIOMMU work in the nested stack and is deliberately left as it is.
* What `l2.gpu_link_speed/width` changes: the L2's own root port `rpg` (QEMU defaults: 16GT/s **x32**, which no real CPU port has) now advertises `x-speed=16,x-width=16`.
  Live test on VM 9320: Code 0, verify PASS, torch 34.71 / 100.93 TFLOP/s, bandwidth identical to before, no AER/Xid, IO_PAGE_FAULT unchanged.
  Values accepted by QEMU 10.2.2: speed 2.5 5 8 16 32 64 (written as `2_5` for 2.5), width 1 2 4 8 12 16 32.
  Revert: empty both keys (or delete the `GPU_LINK_*` lines of `/etc/qemu-ad-l2.env`) and restart `w10-l2`.

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
