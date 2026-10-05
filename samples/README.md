# Captured L0 launch samples (real VM 9200)

Captured 2026-10-05 on bare-metal PVE while VM 9200 was in the working Intel-vIOMMU + GPU
configuration used for nested Windows L2 + RTX 4080 (both GPU functions behind
`pcie-pci-bridge` on `ich9-pcie-port-1`).

| File | What |
| --- | --- |
| `qm-showcmd-9200-intel-raw.txt` | Exact `qm showcmd 9200` (one line) with `machine: q35,viommu=intel`, `memory: 12288`, `scsi1` Windows disk, `hostpci0: 0000:02:00`. |
| `qm-showcmd-9200-intel-pretty.txt` | Same with `--pretty`. |
| `launch-l1-kvmmod.sh` | The raw launch script that was actually exec'd (post-`sed` bridge rewrite from `mk-launch-win.sh`). |
| `actual-argv-9200-pytorch.txt` | NUL-split argv of the live QEMU process (`/proc/<pid>/cmdline`), one token per line. |
| `gen-launch-9200-from-real-showcmd.sh` | Output of `tools/gen-launch.py` on the raw showcmd (after the `gpubr` id fix). |

## Match status (`gen-launch.py` vs working L0)

| Item | Working launch / live argv | `gen-launch.py` output | Status |
| --- | --- | --- | --- |
| `kernel-irqchip=split` | yes | yes | match |
| `intel-iommu,intremap=on,caching-mode=on` as first `-device` | yes | yes | match |
| Both GPU functions on `pcie-pci-bridge` under `ich9-pcie-port-1` | `id=gpubr` | `id=gpubr` (was `gpubr0`; fixed) | match |
| vfio host addresses / multifunction | yes | yes | match |
| smp/cpu/memory/disks/netdev | yes | yes | match |
| `-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536` | **absent** on L0 (L2 guest has it) | **present** by default | **intentional** — gen-launch hard-requires a large L0 BAR aperture; disable with `--mmio64-mb 0 --allow-small-mmio` to bit-match the historical script |

`qm start 9200` still cannot express this topology (fails with IOMMU group used in multiple address spaces). One-command path: `qm showcmd 9200 | tools/gen-launch.py - -o launch.sh && ./launch.sh`.
