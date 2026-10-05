# Docs (nested KVM + qemu-ad-pve lab)

| Doc | Summary |
| --- | --- |
| [feasibility.md](feasibility.md) | Desk study: separate KVM alongside PVE — options, risks, recommended nested-L1 path |
| [roadmap.md](roadmap.md) | Phases, host impact/rollback, acceptance criteria |
| [viommu-nested-spike.md](viommu-nested-spike.md) | Nested vIOMMU spike (AMD-Vi) |
| [gpu-phase-nested-viommu.md](gpu-phase-nested-viommu.md) | RTX 4080 host→L1→L2 on AMD vIOMMU (blocked at DMA remap) |
| [gpu-phase-qemu-11.0.3.md](gpu-phase-qemu-11.0.3.md) | Retry on QEMU 11.0.3-4 (still blocked) |
| [gpu-phase-intel-viommu.md](gpu-phase-intel-viommu.md) | Intel vIOMMU makes the hand-off work |
| [gpu-phase-windows-l2.md](gpu-phase-windows-l2.md) | Windows 10 L2 + RTX 4080 on Intel-vIOMMU path |
| [gpu-phase-patched-qemu.md](gpu-phase-patched-qemu.md) | qemu-ad-pve as L0 QEMU for L1 VM 9200 |
| [gpu-phase-patched-kvm-l1.md](gpu-phase-patched-kvm-l1.md) | Patched kvm/kvm-amd (DKMS) inside L1; Windows L2 + GPU |
| [gpu-phase-patched-kvm-default.md](gpu-phase-patched-kvm-default.md) | Patched KVM as L1 boot default + hardened L2 start |
| [gpu-phase-gen-launch-real-showcmd.md](gpu-phase-gen-launch-real-showcmd.md) | Real `qm showcmd 9200` sample + gen-launch `gpubr` match |
| [gpu-phase-pytorch-l2.md](gpu-phase-pytorch-l2.md) | PyTorch CUDA on Windows L2 under default patched KVM |
| [gpu-phase-gen-launch-e2e.md](gpu-phase-gen-launch-e2e.md) | L1 booted from gen-launch E2E + offline PyTorch under qemu-ad-pve L2 |
| [gpu-phase-qm-native-9200.md](gpu-phase-qm-native-9200.md) | VM 9200 driven by plain `qm start`/`qm shutdown` (args + guard hookscript) + L1 autostart unit for the Windows L2 |

Source archive: [branpurn/separate-kvm-feasibility](https://github.com/branpurn/separate-kvm-feasibility).
