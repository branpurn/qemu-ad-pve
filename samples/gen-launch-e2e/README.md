# gen-launch end-to-end boot samples (VM 9200, 2026-10-05)

Captured during the run in [docs/gpu-phase-gen-launch-e2e.md](../../docs/gpu-phase-gen-launch-e2e.md).

| File | What |
| --- | --- |
| `qm-showcmd-9200-raw.txt` | `qm showcmd 9200` with the Intel-vIOMMU active config (`machine: q35,viommu=intel`, `memory: 12288`, `scsi1` Windows disk, `hostpci0: 0000:02:00`). Byte-identical to the 2026-10-05 10:45 capture from separate-kvm-feasibility PR #10. |
| `launch-9200-gen.sh` | `tools/gen-launch.py qm-showcmd-9200-raw.txt -o launch-9200-gen.sh`, generator from separate-kvm-feasibility PR #10 (`gpubr` id fix; ported to this repo in PR #20). Unedited. sha256 `e0a4940978d60e03e65649f52bdd9da1394c9cc9a03a681205d603864d63ae4b`. |
| `live-argv-l0-9200-gen.txt` | `/proc/<pid>/cmdline` of the L0 QEMU that this script started (NUL -> newline). After `argv[0]`, its 91 tokens are identical to the script's argv. |

The script was run as `QEMU_BIN=/usr/bin/kvm.pve ./launch-9200-gen.sh` so the stock PVE
binary was used explicitly (on this host `/usr/bin/kvm` is the qemu-ad-pve wrapper; 9200 is
not in its VMID list, so the default would have reached `kvm.pve` as well).

With the generator currently on `main` (before PR #20) the only difference is the bridge id
`gpubr0` instead of `gpubr` (3 lines); the topology is the same.
