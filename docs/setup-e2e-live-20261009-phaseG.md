# Phase G (2026-10-09): clean default install of `main` reproduces the hardened result

Lab/dev software-compatibility check. AMD 7950X host, RTX 4080 passed to L1 (VM 9320) and on to the Windows 10 22H2 L2.

* Previous run: VM 9310 = clean install of main 9dcbaa4 plus live edits (PR #40 chassis applied live).
* This run: `./setup.sh install` from a fresh deploy of main 66c9cf1 (PRs up to #41) with only `l1.vmid=9320`, `gpu.slot`, `l1.bridge`,
  the Windows ISO and the offline stage files. No identity / optional-patch / hypervisor / SMBIOS flags. No bug found, no `--redo`,
  about 25 min (in-L1 QEMU build ~4 min, OVMF ~3 min, Windows ~12 min).
* Drift check: `qm config` of 9320 equals the one of 9310 apart from ids/serials/MAC; `/etc/qemu-ad-l2.env`, `/root/w10/smbios.txt`
  and `start-l2.sh` are identical; the type 3 chassis file differs only by its per-VM serial string.

| Check | Previous (9310, phase E+F) | This reproduction (9320) |
|---|---|---|
| CPUID leaf 1 ECX bit 31 / leaf 0x40000000 | 0 / zeros | 0 / zeros |
| `HypervisorPresent` | False | False |
| ACPI tables / WAET | MCFG FACP APIC HPET BGRT, no WAET | MCFG FACP APIC HPET BGRT BGRT, no WAET |
| ACPI OEM id / table id / revision | ALASKA / A M I / 0x1072009 | same, all tables |
| SMBIOS 0 / 1 | AMI 1654 01/12/2024 / ASUS System Product Name | same |
| SMBIOS 2 / 3 / 4 / 17 | ROG STRIX X670E-E / Desktop (3) ASUSTeK / Ryzen 9 7950X AM5 / Kingston KF560C40-16 | same |
| NIC MAC OUI | A4:BF:01 (Intel 82574L) | A4:BF:01 |
| Disk | Samsung SSD 980 PRO 1TB, fw 5B2QGXA7 | same |
| Registry `SystemBiosVersion` | ALASKA - 1072009; 1654; American Megatrends International, LLC. - 5001B | same |
| L1 `systemd-detect-virt` / cpuinfo flag / DMI | none / 0 / ASUS, chassis 3 | none / 0 / ASUS, chassis 3 |
| GPU Code / driver | 0 / 576.88 | 0 / 576.88 |
| torch fp32 / fp16 TFLOP/s | 34.6 / 101.2 | 34.6 / 101.1 (after install 100.7 - 101.1) |
| `qm shutdown` + `qm start` cycle, verify again | PASS | PASS, `setup.sh audit` PASS |

`setup.sh audit` (`scripts/bare-metal-audit`) printed `AUDIT=PASS` (27 rows) before and after the cycle.
Observation: a `verify` started right after the install's last step failed once (`GPU_CODE unknown`, SSH to L2 dropped while Windows was
still finishing first-boot work); a second `verify` a minute later passed.
