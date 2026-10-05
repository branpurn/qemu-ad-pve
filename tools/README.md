# tools/

| Tool | What it does | Host impact |
| --- | --- | --- |
| `gen-launch.py` | `qm showcmd <vmid>` text -> raw QEMU launch script with the Intel-vIOMMU + GPU topology (both functions behind pcie-root-port -> pcie-pci-bridge, large 64-bit MMIO). `--qemu-bin/--qemu-share` for an alternate QEMU, `--no-virtio` for the patched qemu-ad-pve. | **None.** Reads text, writes a file. Running the *generated* script starts one QEMU process (like `qm start`); it does not edit VM configs. Delete the script to remove. |
| `check-new-kernel.py` | Reads the public Proxmox apt `Packages.gz` and reports `proxmox-kernel-*-pve` newer than `pve-kernel-baseline.txt`. | **None.** HTTP GET against `download.proxmox.com` only. |

```
qm showcmd 9200 | tools/gen-launch.py - -o launch-9200.sh          # stock pve-qemu-kvm
qm showcmd 9200 | tools/gen-launch.py - --qemu-bin /opt/qemu-ad/bin/qemu-system-x86_64 --no-virtio -o launch-9200-ad.sh
```

`gen-launch.py` refuses to emit a script that lacks the hard requirements (it exits 1 with the list): q35 + `kernel-irqchip=split`, exactly one `intel-iommu` with `intremap=on,caching-mode=on` (first `-device`), no `amd-iommu`, a vfio-pci GPU with **both** functions on one bus behind a `pcie-pci-bridge`, and `-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string>=32768`. Escape hatches (`--allow-single-function`, `--allow-small-mmio`) exist for experiments and are noted in the script header.

Flag provenance (verified 2026-10-03 against QEMU `master` sources and the QEMU VT-d wiki):

* `kernel-irqchip=split` and `intremap=on` - VT-d wiki: interrupt remapping supports only `split` or `off` irqchip.
* `caching-mode=on` - wiki ("required when we have assigned devices") and `hw/i386/intel_iommu.c` (`Device assignment is not allowed without enabling caching-mode=on`).
* `intel-iommu` first among `-device` - VT-d wiki. The PR #4-#6 runs used qm's own position (not first); the effect of the difference was not tested. `--iommu-position keep` reproduces qm's order.
* `pt` is not emitted: QEMU 11.0's `intel-iommu` has no `pt` property (PR #4), 10.2 does (PR #6).
* `pcie-root-port` `pref64-reserve`, `pcie-pci-bridge`, `device-iotlb`, `aw-bits`: property names checked in `master`; only `pcie-pci-bridge` under a root port was actually run (PR #4-#6).
* `X-PciMmio64Mb`: used for the L2 in PR #5; for the L0 -> L1 launch it is new here and not yet run.
