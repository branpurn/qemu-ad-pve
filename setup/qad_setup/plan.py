"""Pure builders: qm commands for the L1 VM, cloud-init seed, hookscript, L1 env files.

Nothing here touches the host; cli/steps execute (or, with --dry-run, print) the result.
"""
from __future__ import annotations

import base64
import hashlib
import ipaddress
import re
import shlex
import struct
import uuid
from typing import Dict, List, Optional

from .config import Config, l2_addresses
from .hostinfo import Gpu
from .manifest import vm_marker

GPU_BRIDGE_ID = "gpubr"  # same id as tools/gen-launch.py and the lab launch scripts
ROOT_PORT = "ich9-pcie-port-1"  # defined by qemu-server's pve-q35-4.0.cfg on every q35 VM


L1_CPU_HIDDEN_ARG = "-cpu host,-hypervisor,kvm=off"


def l1_args(gpu: Gpu, mmio64_mb: int, hide_hypervisor: bool = False, smbios: Optional[List[str]] = None) -> str:
    """The args: line, in the exact shape PR #24 proved with plain `qm start 9200`
    (docs/gpu-phase-qm-native-9200.md, samples/qm-native-9200/9200.conf.active-final):
    pcie-pci-bridge on ich9-pcie-port-1, every GPU function behind it, then the OVMF MMIO fw_cfg.
    No hostpciN (qm-native topology fails with 'group N used in multiple address spaces'), no
    hand-written intel-iommu: `machine: q35,viommu=intel` makes qemu-server emit intel-iommu
    (intremap, caching-mode) and kernel-irqchip=split itself."""
    parts = [f"-device pcie-pci-bridge,id={GPU_BRIDGE_ID},bus={ROOT_PORT},addr=0x0"]
    for i, f in enumerate(gpu.functions):
        fn = f.bdf.rsplit(".", 1)[1]
        dev_id = "gpu-vga" if i == 0 else ("gpu-audio" if f.cls.startswith("0403") else f"gpu-fn{fn}")
        dev = f"-device vfio-pci,host={f.bdf},id={dev_id},bus={GPU_BRIDGE_ID},addr=0x1.{fn}"
        if i == 0 and len(gpu.functions) > 1:
            dev += ",multifunction=on"
        parts.append(dev)
    parts.append(f"-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string={mmio64_mb}")
    if hide_hypervisor:
        # a later -cpu replaces the qm one: no CPUID hypervisor bit, no KVM signature (phase B/C, docs/SETUP.md)
        parts.append(L1_CPU_HIDDEN_ARG)
    for a in smbios or []:
        parts.append("-smbios " + shlex.quote(a))
    return " ".join(parts)


def description(cfg: Config, install_id: str) -> str:
    return (f"{vm_marker(install_id)}\n"
            "Nested L1 for qemu-ad-pve (patched KVM + Windows L2 with the passed-through GPU).\n"
            "Created by setup.sh; remove with `setup.sh uninstall` (see docs/SETUP.md).\n"
            "The GPU is in args: (pcie-pci-bridge topology), not in hostpciN.")


def seed_volname(vmid: str) -> str:
    return f"qad-l1-{vmid}-seed.iso"


def hook_volname(vmid: str) -> str:
    return f"qad-l1-{vmid}-gpu-guard.pl"


def qm_create(cfg: Config, vmid: str, install_id: str, gpu: Gpu, image_path: str, seed_volid: str,
              hook_volid: Optional[str], smbios_dir: Optional[str] = None) -> List[List[str]]:
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
        "--cpu", "host,hidden=1" if cfg.bool("l1.hide_hypervisor") else "host",
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
        "--args", l1_args(gpu, cfg.int("gpu.mmio64_mb"), cfg.bool("l1.hide_hypervisor"),
                          l1_smbios_args(vmid, smbios_dir) if smbios_dir and cfg["l1.smbios"] == "asus-am5" else None),
    ]
    if cfg["l1.smbios"] == "asus-am5":
        cmd += ["--smbios1", l1_smbios1(vmid, install_id)]
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


def l2_mac(vmid: str, oui: str = "52:54:00") -> str:
    h = hashlib.sha256(f"qad-l2-{vmid}".encode()).hexdigest()
    return (oui or "52:54:00") + ":" + ":".join(h[i:i + 2] for i in (0, 2, 4))


def l2_disk_serial(vmid: str, serial: str = "") -> str:
    if serial:
        return serial
    h = int(hashlib.sha256(f"qad-l2-disk-{vmid}".encode()).hexdigest()[:12], 16)
    return f"S5GXNX0T{h % 1000000:06d}A"


# One entry per -smbios argument. ",," is QEMU's escape for a comma; '|' is reserved by l1_env().
SMBIOS_ASUS_AM5 = [
    "type=0,vendor=American Megatrends Inc.,version=1654,date=01/12/2024,release=5.27",
    "type=1,manufacturer=ASUS,product=System Product Name,version=System Version,"
    "serial=System Serial Number,family=To be filled by O.E.M.",
    "type=2,manufacturer=ASUSTeK COMPUTER INC.,product=ROG STRIX X670E-E GAMING WIFI,version=Rev 1.xx,"
    "serial={board_serial},asset=Default string,location=Default string",
    "type=3,manufacturer=Default string,version=Default string,serial=Default string,asset=Default string",
    "type=4,sock_pfx=AM5,manufacturer=Advanced Micro Devices,, Inc.,"
    "version=AMD Ryzen 9 7950X 16-Core Processor,max-speed=5700,current-speed=4500,"
    "serial=Unknown,asset=Unknown,part=Unknown",
    "type=17,loc_pfx=DIMM_A,bank=BANK 0,manufacturer=Kingston,serial={dimm_serial},asset=Unknown,"
    "part=KF560C40-16,speed=6000",
]


L2_CHASSIS_FILE = "smbios-type3.bin"  # next to start-l2.sh / smbios.txt in L1 (/root/w10)


def l2_chassis_strings(vmid: str) -> List[str]:
    """Type 3 strings of the L2 chassis: manufacturer, version, serial, asset tag."""
    h = hashlib.sha256(f"qad-l2-chassis-{vmid}".encode()).hexdigest()
    return ["ASUSTeK COMPUTER INC.", "1.00", "CS" + str(int(h[:12], 16))[:10].ljust(10, "0"), "No Asset Tag"]


def l2_chassis_bin(vmid: str) -> bytes:
    return smbios_type3_bin(strings=l2_chassis_strings(vmid))


def l2_smbios(profile: str, vmid: str, chassis_dir: str = "") -> str:
    """'|'-joined -smbios arguments for the L2 ('' = leave the patched-QEMU defaults).
    chassis_dir: when set (l2.smbios_chassis=desktop) the type 3 entry becomes `file=<dir>/smbios-type3.bin`
    (a raw structure with chassis type 3 = Desktop; `-smbios type=3` cannot set the chassis type)."""
    if profile != "asus-am5":
        return ""
    h = hashlib.sha256(f"qad-l2-smbios-{vmid}".encode()).hexdigest()
    out = []
    for x in SMBIOS_ASUS_AM5:
        if chassis_dir and x.startswith("type=3,"):
            x = "file=" + chassis_dir.rstrip("/") + "/" + L2_CHASSIS_FILE
        out.append(x.format(board_serial="23" + str(int(h[:12], 16))[:13].ljust(13, "0"),
                            dimm_serial=h[12:20].upper()))
    return "|".join(out)


# ------------------------------------------------------------------ cloud-init seed
# ---- L1 SMBIOS (bare-metal look for the L1 itself, `systemd-detect-virt` = none) -------------------
# Same ASUS AM5 identity as the L2 (SMBIOS_ASUS_AM5) with its own serials. Two things cannot be done with
# `-smbios type=N,...` fields and are passed as raw `-smbios file=` structures:
#   type 0: QEMU always sets BIOS-characteristics-extension byte 2 bit 4 ("system is a virtual machine"),
#           which systemd-detect-virt reads from /sys/firmware/dmi ("DMI BIOS Extension table indicates
#           virtualization" -> vm-other even with the CPUID hypervisor bit hidden);
#   type 3: the chassis type field is not settable (QEMU writes 1 = Other; a desktop is 3).
L1_SMBIOS_FILES = {"type0": "qad-l1-{vmid}-smbios-type0.bin", "type3": "qad-l1-{vmid}-smbios-type3.bin"}


def smbios_type0_bin(vendor: str = "American Megatrends Inc.", version: str = "1654",
                     date: str = "01/12/2024", major: int = 5, minor: int = 27) -> bytes:
    """SMBIOS type 0 (BIOS information), spec 2.4 layout (0x18 bytes), VM bit clear."""
    head = struct.pack("<BBHBBHBB", 0, 0x18, 0x0000, 1, 2, 0xE000, 3, 0xFF)
    # characteristics: PCI, flash upgradeable, shadowing, boot from CD, selectable boot;
    # extension: ACPI + USB legacy, byte 2 = BIOS boot spec + UEFI (bit 4, "virtual machine", is 0)
    head += bytes([0x80, 0x98, 0x01, 0, 0, 0, 0, 0]) + bytes([0x03, 0x09]) + bytes([major, minor, 0xFF, 0xFF])
    assert len(head) == 0x18
    return head + b"".join(x.encode() + b"\0" for x in (vendor, version, date)) + b"\0"


def smbios_type3_bin(text: str = "Default string", strings: Optional[List[str]] = None) -> bytes:
    """SMBIOS type 3 (chassis), spec 2.3 layout (0x15 bytes), chassis type 3 (Desktop).
    strings = manufacturer, version, serial, asset tag (default: `text` four times)."""
    strs = list(strings) if strings else [text] * 4
    assert len(strs) == 4
    head = struct.pack("<BBHBBBBBBBBBIBBBB", 3, 0x15, 0x0300, 1, 3, 2, 3, 4, 3, 3, 3, 2, 0, 0, 1, 0, 0)
    assert len(head) == 0x15
    return head + b"".join(x.encode() + b"\0" for x in strs) + b"\0"


def l1_smbios_files(vmid: str) -> Dict[str, bytes]:
    return {L1_SMBIOS_FILES["type0"].format(vmid=vmid): smbios_type0_bin(),
            L1_SMBIOS_FILES["type3"].format(vmid=vmid): smbios_type3_bin()}


def l1_smbios_args(vmid: str, directory: str) -> List[str]:
    """-smbios arguments (without the flag) for the L1: types 0/3 from files, 2/4/17 as fields."""
    h = hashlib.sha256(f"qad-l1-smbios-{vmid}".encode()).hexdigest()
    out = []
    for e in SMBIOS_ASUS_AM5:
        if e.startswith("type=0,"):
            out.append("file=" + directory.rstrip("/") + "/" + L1_SMBIOS_FILES["type0"].format(vmid=vmid))
        elif e.startswith("type=3,"):
            out.append("file=" + directory.rstrip("/") + "/" + L1_SMBIOS_FILES["type3"].format(vmid=vmid))
        elif e.startswith("type=1,"):
            continue  # the L1 type 1 comes from `qm --smbios1`
        else:
            out.append(e.format(board_serial="24" + str(int(h[:12], 16))[:13].ljust(13, "0"),
                                dimm_serial=h[12:20].upper()))
    return out


def l1_smbios1(vmid: str, install_id: str) -> str:
    """`qm --smbios1` value (type 1, base64 fields) with a stable per-install UUID."""
    b = lambda t: base64.b64encode(t.encode()).decode()  # noqa: E731
    u = uuid.uuid5(uuid.NAMESPACE_URL, f"qad-l1-{install_id}-{vmid}")
    return (f"uuid={u},manufacturer={b('ASUS')},product={b('System Product Name')},"
            f"version={b('System Version')},serial={b('System Serial Number')},"
            f"family={b('To be filled by O.E.M.')},base64=1")


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
def optional_patches(cfg: Config) -> List[str]:
    """Names from l2.optional_patches (comma/space separated), in order, without duplicates."""
    out: List[str] = []
    if cfg["l2.optional_patches"].strip().lower() == "none":
        return out
    for x in re.split(r"[,\s]+", cfg["l2.optional_patches"]):
        if x and x not in out:
            out.append(x)
    return out


def l1_env(cfg: Config, install_id: str, vmid: str, gpu: Gpu, cpu_vendor: str,
           win_iso_label: str = "", stage_inputs: Optional[List[str]] = None) -> str:
    """/etc/qemu-ad/setup.env inside L1 (sourced by setup/l1/qad-l1.sh). No secrets here."""
    bridge_ip, l2_ip, dstart, dend = l2_addresses(cfg["l2.net_cidr"])
    prefix = ipaddress.ip_network(cfg["l2.net_cidr"]).prefixlen
    au = cfg["l2.autounattend"]
    chassis_dir = "/root/w10" if (cfg["l2.smbios"] == "asus-am5" and cfg["l2.smbios_chassis"] == "desktop") else ""
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
        "QAD_L2_DISK_GB": cfg["l2.disk_gb"],
        "QAD_L2_CPU": cfg["l2.cpu"],
        "QAD_L2_MAC": l2_mac(vmid, cfg["l2.mac_oui"]),
        "QAD_L2_DISK_MODEL": cfg["l2.disk_model"],
        "QAD_L2_DISK_SERIAL": l2_disk_serial(vmid, cfg["l2.disk_serial"]) if cfg["l2.disk_model"] else "",
        "QAD_L2_DISK_FW": cfg["l2.disk_firmware"],
        "QAD_L2_SMBIOS": l2_smbios(cfg["l2.smbios"], vmid, chassis_dir),
        "QAD_L2_CHASSIS_B64": base64.b64encode(l2_chassis_bin(vmid)).decode() if chassis_dir else "",
        "QAD_L1_BARE_METAL": "1" if (cfg["l1.smbios"] == "asus-am5" and cfg.bool("l1.hide_hypervisor")) else "0",
        "QAD_L2_VGA": cfg["l2.vga"],
        "QAD_L2_CDROM_MODEL": cfg["l2.cdrom_model"],
        "QAD_L2_CDROM_VER": cfg["l2.cdrom_firmware"] if cfg["l2.cdrom_model"] else "",
        "QAD_L2_GPU_LINK_SPEED": cfg["l2.gpu_link_speed"],
        "QAD_L2_GPU_LINK_WIDTH": cfg["l2.gpu_link_width"],
        "QAD_L2_DETACH_STAGE": "1" if cfg.bool("l2.detach_stage_iso") else "0",
        "QAD_L2_EDID": cfg["l2.edid_monitor"],
        "QAD_L2_CLEAN_GHOSTS": "1" if cfg.bool("l2.cleanup_ghosts") else "0",
        "QAD_L2_VGA_AFTER": cfg["l2.vga_after_verify"],
        "QAD_L2_CLEAN_UNATTEND": "1" if cfg.bool("l2.cleanup_unattend") else "0",
        "QAD_L2_CLEAN_STAGING": "1" if cfg.bool("l2.cleanup_staging") else "0",
        "QAD_L2_OPTIONAL_PATCHES": ",".join(optional_patches(cfg)),
        "QAD_L2_OEM_ID": cfg["l2.oem_id"],
        "QAD_L2_OEM_TABLE_ID": cfg["l2.oem_table_id"],
        "QAD_L2_OEM_REVISION": cfg["l2.oem_revision"],
        "QAD_L2_OVMF_IDENTITY": "1" if (cfg["l2.ovmf_identity"] == "yes" or cfg["l2.ovmf_identity_dir"]) else "0",
        "QAD_L2_OVMF_BUILD": "1" if (cfg["l2.ovmf_identity"] == "yes" and not cfg["l2.ovmf_identity_dir"]) else "0",
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
GUARD_TEMPLATE = "scripts/qm-native-9200/9200-gpu-guard.pl"  # from PR #24, proven on VM 9200


class TemplateError(ValueError):
    pass


def _sub_once(text: str, old: str, new: str) -> str:
    if text.count(old) != 1:
        raise TemplateError(f"{GUARD_TEMPLATE}: expected exactly one {old!r} (found {text.count(old)}); "
                            "the template changed, update plan.hookscript()")
    return text.replace(old, new)


def hookscript(template: str, vmid: str, gpu: Gpu) -> str:
    """Render PR #24's GPU-guard hookscript for this VMID and GPU.

    The logic is used unchanged (refuse unless every function is on vfio-pci; reserve the PCI ids
    via qemu-server's own reserve_pci_usage so a hostpci VM is refused while L1 runs, and vice
    versa; release on post-stop). Only the hard-coded VMID and PCI ids are replaced, each of which
    must occur exactly once, so a changed template fails loudly instead of rendering wrongly."""
    ids = ", ".join(f"'{f.bdf}'" for f in gpu.functions)
    out = _sub_once(template, "my @ids = ('0000:02:00.0', '0000:02:00.1');", f"my @ids = ({ids});")
    out = _sub_once(out, "if ($vmid // '') ne '9200';", f"if ($vmid // '') ne '{vmid}';")
    out = _sub_once(out, "for VM 9200 only (called for", f"for VM {vmid} only (called for")
    out = out.replace("9200-gpu-guard: ", f"{vmid}-gpu-guard: ")
    lines = out.split("\n")
    if not lines[0].startswith("#!"):
        raise TemplateError(f"{GUARD_TEMPLATE}: missing shebang")
    lines.insert(1, f"# Rendered by setup.sh from {GUARD_TEMPLATE} for VM {vmid}, GPU {gpu.slot} "
                    f"({len(gpu.functions)} functions). Only the VMID and the PCI ids differ from the template.")
    return "\n".join(lines)
