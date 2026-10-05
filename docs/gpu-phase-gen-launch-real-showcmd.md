# gen-launch.py: real `qm showcmd 9200` sample + match to working L0

Date: 2026-10-05. Follows tooling PR #7 (`tools/gen-launch.py`) and the Intel-vIOMMU /
Windows L2 / patched-KVM notes (PRs #4–#9). Host PVE stayed stock; only VM 9200 was used.

## What was captured

While 9200's **active** config was the Intel path (`machine: q35,viommu=intel`,
`hostpci0: 0000:02:00`, `memory: 12288`, Windows disk on `scsi1`), we recorded:

1. `qm showcmd 9200` (raw + pretty) — qm's native topology still places both GPU
   functions directly on `ich9-pcie-port-1` (the topology that fails under the vIOMMU).
2. The raw launch script actually used (`launch-l1-kvmmod.sh`), produced by the
   existing `mk-launch-win.sh` bridge `sed` rewrite.
3. Live argv from `/proc/<pid>/cmdline` after that script started QEMU.

Files live under [`samples/`](../samples/).

## Generator fix

`tools/gen-launch.py` named the bridge `gpubr0` for the first GPU. The working scripts
and live argv use `gpubr`. The generator now emits `gpubr` for the first slot and
`gpubr{n}` only when multiple GPU slots are rewritten.

## Match verdict

After the id fix, **every `-device` / topology flag matches** the working L0 launch.
The only remaining difference is intentional:

* **L0 `-fw_cfg X-PciMmio64Mb=65536`**: gen-launch adds it by design (hard requirement
  in `check()`). The historical working L0 script did not set it (L2 QEMU sets the
  same fw_cfg for the Windows guest). Prefer keeping the generator default; to
  reproduce the historical L0 argv exactly, pass `--mmio64-mb 0 --allow-small-mmio`.

## Not run

* Booting L1 from the generated script end-to-end in this session (L1 was started
  from the pre-existing `launch-l1-kvmmod.sh`; generator output was compared offline
  to that argv). Recommended next: `qm showcmd 9200 | tools/gen-launch.py - -o …`
  and a cold L1 bring-up when convenient.
