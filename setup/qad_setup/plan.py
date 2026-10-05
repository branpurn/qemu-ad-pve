"""Pure builders: qm commands for the L1 VM, cloud-init seed, hookscript, L1 env files.

Nothing here touches the host; cli/steps execute (or, with --dry-run, print) the result.
"""
from __future__ import annotations

import hashlib
import ipaddress
import shlex
from typing import Dict, List, Optional

from .config import Config, l2_addresses
from .hostinfo import Gpu
from .manifest import vm_marker

GPU_BRIDGE_ID = "gpubr"  # same id as tools/gen-launch.py and the lab launch scripts
ROOT_PORT = "ich9-pcie-port-1"  # defined by qemu-server's pve-q35-4.0.cfg on every q35 VM


def l1_args(gpu: Gpu, mmio64_mb: int) -> str:
    """The args: line. qm cannot put both GPU functions behind a pcie-pci-bridge (PR #4:
    'group N used in multiple address spaces' with the Intel vIOMMU), so the GPU is NOT a
    hostpciN entry but raw -device options appended by qm at the end of the command line.
    intel-iommu + kernel-irqchip=split come from `machine: q35,viommu=intel`."""
    parts = [f"-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string={mmio64_mb}",
             f"-device pcie-pci-bridge,id={GPU_BRIDGE_ID},bus={ROOT_PORT},addr=0x0"]
    for i, f in enumerate(gpu.functions):
        fn = f.bdf.rsplit(".", 1)[1]
        dev = f"-device vfio-pci,host={f.bdf},id=qadgpu{i},bus={GPU_BRIDGE_ID},addr=0x1.{fn}"
        if i == 0 and len(gpu.functions) > 1:
            dev += ",multifunction=on"
        parts.append(dev)
    return " ".join(parts)


def description(cfg: Config, install_id: str) -> str:
    return (f"{vm_marker(install_id)}\n"
            "Nested L1 for qemu-ad-pve (patched KVM + Windows L2 with the passed-through GPU).\n"
            "Created by setup.sh; remove with `setup.sh uninstall` (see docs/SETUP.md).\n"
            "The GPU is in args: (pcie-pci-bridge topology), not in hostpciN.")


def seed_volname(vmid: str) -> str:
    return f"qad-l1-{vmid}-seed.iso"


def hook_volname(vmid: str) -> str:
    return f"qad-l1-{vmid}-hook.sh"


def qm_create(cfg: Config, vmid: str, install_id: str, gpu: Gpu, image_path: str, seed_volid: str,
              hook_volid: Optional[str]) -> List[List[str]]:
    st = cfg["l1.storage"]
    cmd = [
        "qm", "create", vmid,
        "--name", cfg["l1.name"],
        "--description", description(cfg, install_id),
        "--tags", "qemu-ad-pve",
        "--machine", "q35,viommu=intel",
        "--bios", "ovmf",
        "--efidisk0", f"{st}:1,efitype=4m,pre-enrolled-keys=0",
        "--ostype", "l26",
        "--cpu", "host",
        "--sockets", "1",
        "--cores", cfg["l1.cores"],
        "--memory", cfg["l1.memory_mb"],
        "--balloon", "0",
        "--scsihw", "virtio-scsi-single",
        "--scsi0", f"{st}:0,import-from={image_path},discard=on,ssd=1",
        "--ide2", f"{seed_volid},media=cdrom",
        "--boot", "order=scsi0",
        "--net0", f"virtio,bridge={cfg['l1.bridge']}",
        "--agent", "enabled=1",
        "--serial0", "socket",
        "--vga", "std",
        "--onboot", "1" if cfg.bool("l1.onboot") else "0",
        "--startup", f"down={cfg['l1.shutdown_timeout']}",
        "--args", l1_args(gpu, cfg.int("gpu.mmio64_mb")),
    ]
    if hook_volid:
        cmd += ["--hookscript", hook_volid]
    cmds = [cmd, ["qm", "disk", "resize", vmid, "scsi0", f"{cfg['l1.disk_gb']}G"]]
    src = cfg["l2.source"]
    if src == "iso":
        cmds.append(["qm", "set", vmid, "--scsi1", f"{st}:{cfg['l2.disk_gb']},discard=on,ssd=1"])
        cmds.append(["qm", "set", vmid, "--ide0", f"{cfg['l2.windows_iso']},media=cdrom"])
    elif src == "image":
        cmds.append(["qm", "set", vmid, "--scsi1",
                     f"{st}:0,import-from={cfg['l2.image']},discard=on,ssd=1"])
    return cmds


def l2_mac(vmid: str) -> str:
    h = hashlib.sha256(f"qad-l2-{vmid}".encode()).hexdigest()
    return "52:54:00:" + ":".join(h[i:i + 2] for i in (0, 2, 4))


# ------------------------------------------------------------------ cloud-init seed
def user_data(pubkey: str, hostname: str) -> str:
    return f"""#cloud-config
# qemu-ad-pve setup: minimal L1 bootstrap. Everything else is done over SSH by setup.sh
# (logged in /var/log/qemu-ad-setup/ inside L1), so a failure is visible and resumable.
hostname: {hostname}
manage_etc_hosts: true
disable_root: false
ssh_pwauth: false
users:
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
      - {pubkey.strip()}
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
"""


def meta_data(install_id: str, hostname: str) -> str:
    return f"instance-id: qad-{install_id}\nlocal-hostname: {hostname}\n"


def network_config(cfg: Config) -> Optional[str]:
    if cfg["l1.ip"] == "dhcp":
        return None  # Debian's cloud image falls back to DHCP on the first NIC
    dns = cfg["l1.dns"] or cfg["l1.gateway"]
    return f"""version: 2
ethernets:
  nic0:
    match:
      name: "e*"
    addresses: [{cfg['l1.ip']}]
    routes:
      - to: default
        via: {cfg['l1.gateway']}
    nameservers:
      addresses: [{dns}]
"""


def hostname_for(cfg: Config) -> str:
    return cfg["l1.name"].split(".")[0]


# ------------------------------------------------------------------ L1 env file
def l1_env(cfg: Config, install_id: str, vmid: str, gpu: Gpu, cpu_vendor: str,
           win_iso_label: str = "", stage_inputs: Optional[List[str]] = None) -> str:
    """/etc/qemu-ad/setup.env inside L1 (sourced by setup/l1/qad-l1.sh). No secrets here."""
    bridge_ip, l2_ip, dstart, dend = l2_addresses(cfg["l2.net_cidr"])
    prefix = ipaddress.ip_network(cfg["l2.net_cidr"]).prefixlen
    au = cfg["l2.autounattend"]
    values: Dict[str, str] = {
        "QAD_INSTALL_ID": install_id,
        "QAD_L1_VMID": vmid,
        "QAD_CPU_VENDOR": cpu_vendor,
        "QAD_KVM_SOURCE": cfg["l1.kvm_source"],
        "QAD_HOLD_KERNEL": "1" if cfg.bool("l1.hold_kernel") else "0",
        "QAD_GPU_IDS": " ".join(f.ids for f in gpu.functions),
        "QAD_GPU_NFUNCS": str(len(gpu.functions)),
        "QAD_MMIO64_MB": cfg["gpu.mmio64_mb"],
        "QAD_L2_SOURCE": cfg["l2.source"],
        "QAD_WIN_ISO_LABEL": win_iso_label,
        "QAD_L2_MEM": cfg["l2.memory_mb"],
        "QAD_L2_SMP": cfg["l2.cores"],
        "QAD_L2_CPU": cfg["l2.cpu"],
        "QAD_L2_MAC": l2_mac(vmid),
        "QAD_L2_NET_PREFIX": str(prefix),
        "QAD_L2_BRIDGE_IP": bridge_ip,
        "QAD_L2_IP": l2_ip,
        "QAD_L2_DHCP_START": dstart,
        "QAD_L2_DHCP_END": dend,
        "QAD_AUTOUNATTEND": au if au in ("generate", "none") else "custom",
        "QAD_WIN_VERSION": cfg["l2.windows_version"],
        "QAD_WIN_EDITION": cfg.edition(),
        "QAD_COMPUTER_NAME": cfg["l2.computer_name"],
        "QAD_TIMEZONE": cfg["l2.timezone"],
        "QAD_LOCALE": cfg["l2.locale"],
        "QAD_ADMIN_USER": cfg["l2.admin_user"],
        "QAD_VNC": cfg["l2.vnc"],
        "QAD_INSTALL_TIMEOUT_MIN": cfg["l2.install_timeout_min"],
        "QAD_VERIFY_CUDA": cfg["verify.cuda"],
        "QAD_STAGE_INPUTS": " ".join(stage_inputs or []),
    }
    lines = ["# Generated by setup.sh on the PVE host. Sourced by /root/qemu-ad-pve/setup/l1/qad-l1.sh."]
    lines += [f"{k}={shlex.quote(v)}" for k, v in values.items()]
    return "\n".join(lines) + "\n"


def secrets_env(admin_password: str, product_key: str) -> str:
    return (f"QAD_ADMIN_PASSWORD={shlex.quote(admin_password)}\n"
            f"QAD_PRODUCT_KEY={shlex.quote(product_key.upper())}\n")


# ------------------------------------------------------------------ hookscript
def hookscript(template: str, vmid: str, gpu: Gpu) -> str:
    funcs = " ".join(f.bdf for f in gpu.functions)
    return (template.replace("@QAD_VMID@", vmid)
            .replace("@QAD_GPU_FUNCS@", funcs)
            .replace("@QAD_GPU_SLOT@", gpu.slot))
