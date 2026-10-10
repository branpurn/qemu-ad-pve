"""Configuration: schema, defaults, INI parsing and validation (pure logic, unit-tested).

The config file is INI (configparser) with three sections plus [stage]:

    [l1]    the nested L1 VM that is created on the PVE host
    [gpu]   which host GPU is handed to L1 (and from there to L2)
    [l2]    the Windows L2 created inside L1
    [stage] optional offline files for the L2 (NVIDIA driver, Python, wheels, OpenSSH)

Every key has a default; ``auto`` means "decide from the host at preflight time".
Unknown keys are an error (typos must not silently fall back to a default).
"""
from __future__ import annotations

import configparser
import ipaddress
import re
from dataclasses import dataclass
from typing import Callable, Dict, List, Optional, Tuple

DEBIAN_IMAGE_URL = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"


class ConfigError(ValueError):
    """Invalid configuration (message is user-facing)."""


@dataclass(frozen=True)
class Key:
    section: str
    name: str
    default: str
    help: str
    kind: str = "str"  # str | int | bool | choice | path | cidr | vmid | slot | ip
    choices: Tuple[str, ...] = ()
    minimum: Optional[int] = None
    secret: bool = False
    prompt: bool = False  # asked interactively (others only via --config)

    @property
    def fq(self) -> str:
        return f"{self.section}.{self.name}"


SCHEMA: List[Key] = [
    # ---- L1 -------------------------------------------------------------------------
    Key("l1", "vmid", "auto", "VMID of the new L1 VM (auto = next free VMID from pvesh)", "vmid", prompt=True),
    Key("l1", "name", "qad-l1", "Name of the L1 VM", prompt=True),
    Key("l1", "storage", "auto", "Storage for the L1 disks (needs content 'images')", prompt=True),
    Key("l1", "iso_storage", "auto", "Storage for the cloud-init seed ISO (needs content 'iso')"),
    Key("l1", "bridge", "vmbr0", "Host bridge for the L1 NIC (L1 needs internet for apt/DKMS)", prompt=True),
    Key("l1", "memory_mb", "12288", "L1 RAM in MiB (must hold the L2 RAM plus ~4 GiB)", "int", minimum=4096, prompt=True),
    Key("l1", "cores", "8", "L1 vCPUs", "int", minimum=2, prompt=True),
    Key("l1", "disk_gb", "48", "L1 root disk size in GiB (DKMS sources, QEMU, staging ISOs)", "int", minimum=24),
    Key("l1", "ip", "dhcp", "L1 address: 'dhcp' or CIDR like 192.168.1.50/24", "cidr"),
    Key("l1", "gateway", "", "Gateway when l1.ip is static", "ip"),
    Key("l1", "dns", "", "DNS server when l1.ip is static (default: the gateway)", "ip"),
    Key("l1", "debian_image_url", DEBIAN_IMAGE_URL,
        "Debian 13 *generic* cloud image (standard kernel; genericcloud's cloud kernel is untested)"),
    Key("l1", "debian_image", "", "Use this local qcow2 instead of downloading (path on the PVE host)", "path"),
    Key("l1", "hold_kernel", "yes", "apt-mark hold the L1 kernel (DKMS AUTOINSTALL is off in dkms/)", "bool"),
    Key("l1", "kvm_source", "debian", "Source for the patched KVM: debian (linux-source of the L1 kernel, "
        "like the lab build) or upstream (dkms/fetch-kvm-source.sh)", "choice", ("debian", "upstream")),
    Key("l1", "qemu_ad", "auto", "qemu-ad-pve binary for L2: copy (host /opt/qemu-ad, read-only), build "
        "(qemu-ad-pve.sh build inside L1) or auto (copy if present on host, else build)", "choice",
        ("auto", "copy", "build")),
    Key("l1", "hookscript", "auto", "Install the GPU-guard hookscript from scripts/qm-native-9200 (refuses start unless the GPU is "
        "on vfio-pci; reserves it via qemu-server so hostpci VMs are refused while L1 runs). auto = yes. "
        "no = unprotected (not recommended)", "choice", ("auto", "yes", "no")),
    Key("l1", "snippets_storage", "auto", "Existing storage with content 'snippets' for the hookscript "
        "(setup.sh never changes storage.cfg)"),
    Key("l1", "smbios", "asus-am5",
        "SMBIOS identity of the L1 (bare-metal look, `systemd-detect-virt` = none): asus-am5 | none (QEMU/Proxmox defaults)",
        "choice", ("asus-am5", "none")),
    Key("l1", "hide_hypervisor", "yes",
        "Hide the hypervisor from the L1 (no CPUID hypervisor bit, kvm=off); nested KVM and the GPU keep working", "bool"),
    Key("l1", "onboot", "no", "Start L1 when the host boots (GPU is then taken from other VMs)", "bool"),
    Key("l1", "shutdown_timeout", "240", "startup down= : seconds `qm shutdown`/host shutdown wait for L1 "
        "(L2 ACPI wait 150 s < w10-l2.service TimeoutStopSec 180 s < this)", "int", minimum=200),
    # ---- GPU ------------------------------------------------------------------------
    Key("gpu", "slot", "auto", "Host PCI slot of the GPU, e.g. 0000:01:00 (all functions are passed)", "slot",
        prompt=True),
    Key("gpu", "mmio64_mb", "65536", "OVMF 64-bit MMIO aperture (X-PciMmio64Mb) for L1 and L2", "int",
        minimum=32768),
    # ---- L2 -------------------------------------------------------------------------
    Key("l2", "source", "iso", "How to create the Windows L2: iso (install from a Windows ISO), image "
        "(existing qcow2/raw), none (L1 only)", "choice", ("iso", "image", "none"), prompt=True),
    Key("l2", "windows_iso", "", "Windows ISO: PVE volid (local:iso/Win10.iso) or absolute path", prompt=True),
    Key("l2", "image", "", "Existing Windows disk image (qcow2/raw) on the PVE host; must boot on SATA/AHCI",
        "path", prompt=True),
    Key("l2", "disk_gb", "128", "Windows disk size in GiB (iso source)", "int", minimum=40, prompt=True),
    Key("l2", "memory_mb", "6144", "L2 RAM in MiB", "int", minimum=2048, prompt=True),
    Key("l2", "cores", "4", "L2 vCPUs", "int", minimum=1),
    Key("l2", "autounattend", "generate", "generate (unattended install), none (interactive via VNC) "
        "or a path to your own autounattend.xml", prompt=True),
    Key("l2", "windows_version", "10", "10 or 11 (11 adds the TPM/SecureBoot setup bypass; untested)",
        "choice", ("10", "11")),
    Key("l2", "windows_edition", "auto", "Image name in install.wim (auto: 'Windows <ver> Pro')"),
    Key("l2", "product_key", "", "Your own product key (empty = none; Setup may ask, see docs)", secret=True,
        prompt=True),
    Key("l2", "admin_user", "qad", "Local administrator created by autounattend"),
    Key("l2", "admin_password", "", "Password for admin_user (empty = random, shown once at the end)",
        secret=True),
    Key("l2", "computer_name", "QAD-L2", "Windows computer name"),
    Key("l2", "timezone", "UTC", "Windows time zone id (e.g. 'Eastern Standard Time')"),
    Key("l2", "locale", "en-US", "Windows UI/input locale"),
    Key("l2", "cpu", "host,-hypervisor,kvm=off",
        "L2 -cpu value (hypervisor bit 31 cleared + KVM CPUID leaf 0x40000000 hidden; Code 0 + CUDA verified)"),
    Key("l2", "mac_oui", "a4:bf:01",
        "First 3 bytes of the L2 NIC MAC (default: an Intel OUI, the NIC is an Intel 82574L; empty = QEMU 52:54:00)"),
    Key("l2", "disk_model", "Samsung SSD 980 PRO 1TB",
        "Model string the L2 sees for its disk (empty = the patched QEMU default)"),
    Key("l2", "disk_serial", "", "L2 disk serial (empty = derived from the L1 VMID)"),
    Key("l2", "disk_firmware", "5B2QGXA7", "L2 disk firmware revision"),
    Key("l2", "cdrom_model", "ASUS DRW-24B1ST",
        "Model string of the L2 optical drive (ATAPI; first word = vendor in Windows). Used from the install on, so "
        "Windows never sees another CD identity. Empty = the patched QEMU default ('ASUS DVD-ROM', shown as 'ASUS ASUS DVD-ROM')"),
    Key("l2", "cdrom_firmware", "1.00", "Firmware revision of the L2 optical drive (needs l2.cdrom_model)"),
    Key("l2", "gpu_link_speed", "16",
        "Link speed (GT/s: 2.5 5 8 16 32 64) the L2's GPU root port ('rpg') advertises; QEMU's own default is 16. The GPU's own "
        "link status in Windows (nvidia-smi) always follows the physical link; empty = QEMU default"),
    Key("l2", "gpu_link_width", "16",
        "Link width (1 2 4 8 12 16 32) the L2's GPU root port advertises; QEMU's own default is x32, a real CPU root port is x16; empty = QEMU default"),
    Key("l2", "detach_stage_iso", "yes",
        "After the first successful verify, eject the staging ISO from the L2 CD drive and keep it detached after restarts "
        "(the empty drive stays; the ISO file is kept in L1 for a reinstall). no = keep it attached"),
    Key("l2", "smbios", "asus-am5",
        "SMBIOS identity of the L2 (types 0/1/2/3/4/17): asus-am5 | none (patched-QEMU defaults)"),
    Key("l2", "smbios_chassis", "desktop",
        "desktop = the L2 SMBIOS type 3 is a raw structure with chassis type 3 (Desktop) and ASUS strings "
        "(QEMU's own type 3 is chassis type 1 'Other' with 'Default string'); none = the type=3 fields of l2.smbios. "
        "Needs l2.smbios = asus-am5"),
    Key("l2", "optional_patches", "0001-acpi-omit-waet,0002-acpi-oem-id-table-id-revision,0003-atapi-inquiry-from-model",
        "Comma-separated optional QEMU patches (patches/optional/, docs/optional-qemu-patches.md); default = all three "
        "(omit the WAET table + configurable ACPI OEM ids + ATAPI INQUIRY vendor/product from the CD model). Built into /opt/qemu-ad-optpatch INSIDE L1 during install "
        "(the L2 uses it via QB=; /opt/qemu-ad stays untouched). 'none' = opt out (the L2 keeps /opt/qemu-ad)"),
    Key("l2", "oem_id", "ALASKA", "ACPI OEM ID (<=6 chars); needs patch 0002. Empty = INTEL"),
    Key("l2", "oem_table_id", "A M I", "ACPI OEM table ID (<=8 chars, space padded); needs patch 0002"),
    Key("l2", "oem_revision", "0x1072009", "ACPI OEM revision, hex; needs patch 0002"),
    Key("l2", "ovmf_identity", "yes",
        "yes = build OVMF with another firmware identity (AMI vendor string, ACPI OEM ids = l2.oem_*; "
        "scripts/ovmf-identity, docs/ovmf-identity.md) INSIDE L1 during install and use it for the L2. no = Debian's OVMF"),
    Key("l2", "ovmf_identity_dir", "",
        "Optional: PVE-host directory with a prebuilt OVMF_CODE_4M.fd (scripts/ovmf-identity/build-ovmf-identity.sh); "
        "copied to L1 instead of building in L1. Empty = build in L1 (when l2.ovmf_identity=yes)", "path"),
    Key("l2", "vga", "std",
        "std = emulated VGA (QEMU PCI 1234:1111; needed to watch the install over VNC); "
        "none = no emulated VGA, the passed-through GPU is the only display (use after install)"),
    Key("l2", "cleanup_unattend", "yes",
        "After the first successful verify, delete the answer-file copies (C:\\Windows\\Panther\\unattend.xml, UnattendGC, "
        "actionqueue, other Setup/Panther logs) from the L2 (setup residue; docs/bare-metal-appearance.md). no = keep", "bool"),
    Key("l2", "cleanup_staging", "yes",
        "After the first successful verify, delete the staged installers and one-shot first-boot scripts/logs from "
        "C:\\qad in the L2 (nvidia, python, openssh, firstlogon.*, gpu-driver.*). The venv, py, audit dir, sshd and the "
        "admin account stay. no = keep", "bool"),
    Key("l2", "cleanup_ghosts", "yes",
        "After the first successful verify, remove stale (not present) device instance keys of earlier VM identities from the "
        "L2 registry (old CD-ROM instances, the install-time 'ASUS HARDDISK', the emulated Standard VGA after vga_after_verify = "
        "none); the keys are exported to /root/w10/ghost-backup in L1 first. no = keep", "bool"),
    Key("l2", "vga_after_verify", "none",
        "none = after the first successful verify switch the emulated VGA off (VGA=none in /etc/qemu-ad-l2.env, L2 restart, "
        "re-verify, automatic revert when the GPU stops working or the desktop is gone); keep = leave l2.vga as it is "
        "(the install keeps showing the Standard VGA adapter)", "choice", ("none", "keep")),
    Key("l2", "edid_monitor", "none",
        "EXPERIMENTAL registry EDID override for the L2 monitor node (asus-vg248qe | dell-s2421h | none). Live result on the "
        "lab host: no effect without an attached display (Windows creates no monitor node; only placeholder "
        "DISPLAY\\Default_Monitor entries exist), so the default is none; the real fix is an HDMI/DP EDID emulator dongle "
        "(docs/bare-metal-appearance.md)", "choice", ("none", "asus-vg248qe", "dell-s2421h")),
    Key("l2", "net_cidr", "10.254.77.0/24", "Isolated L1<->L2 network (no NAT, no internet for L2)", "cidr"),
    Key("l2", "install_timeout_min", "240", "Max minutes to wait for the Windows install/first boot", "int",
        minimum=10),
    Key("l2", "vnc", "127.0.0.1:0", "VNC display of the L2 *inside L1* during install (reach it with ssh -L)"),
    # ---- staging --------------------------------------------------------------------
    Key("stage", "nvidia_driver", "", "NVIDIA Windows driver .exe on the PVE host (installed at first GPU boot)",
        "path", prompt=True),
    Key("stage", "python_installer", "", "python-3.x-amd64.exe on the PVE host", "path"),
    Key("stage", "wheelhouse", "", "Directory of Windows wheels (*.whl, optional SHA256SUMS*) on the PVE host",
        "path"),
    Key("stage", "openssh_zip", "", "OpenSSH-Win64.zip (Win32-OpenSSH release) for offline sshd in L2", "path"),
    Key("stage", "extra_files", "", "Comma-separated extra files copied to the staging ISO root", "str"),
    Key("stage", "downloads", "", "Only with --download-proprietary: 'url sha256 [name]' entries separated "
        "by ';'. Downloaded INSIDE L1, sha256-checked, put on the staging ISO", "str"),
    # ---- verify ---------------------------------------------------------------------
    Key("verify", "cuda", "auto", "Run the PyTorch CUDA check in L2: auto (if torch was staged), yes, no",
        "choice", ("auto", "yes", "no")),
]

KEYS: Dict[str, Key] = {k.fq: k for k in SCHEMA}
TRUE = {"1", "yes", "true", "on", "y"}
FALSE = {"0", "no", "false", "off", "n"}
SLOT_RE = re.compile(r"^(?:[0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}$")
VOLID_RE = re.compile(r"^[A-Za-z][A-Za-z0-9\-_.]*:[^\s]+$")


def as_bool(value: str) -> bool:
    v = value.strip().lower()
    if v in TRUE:
        return True
    if v in FALSE:
        return False
    raise ConfigError(f"not a yes/no value: {value!r}")


def norm_slot(value: str) -> str:
    v = value.strip().lower()
    if not SLOT_RE.match(v):
        raise ConfigError(f"gpu.slot must look like 0000:01:00 (no function), got {value!r}")
    return v if v.count(":") == 2 else "0000:" + v


def _check(key: Key, value: str) -> str:
    """Validate/normalise one value; return the normalised string."""
    v = value.strip()
    if v == "auto" and key.default == "auto":
        return v
    if key.kind == "int":
        if not re.fullmatch(r"\d+", v):
            raise ConfigError(f"{key.fq}: expected a whole number, got {value!r}")
        if key.minimum is not None and int(v) < key.minimum:
            raise ConfigError(f"{key.fq}: {v} is below the minimum {key.minimum}")
        return str(int(v))
    if key.kind == "bool":
        return "yes" if as_bool(v) else "no"
    if key.kind == "choice":
        if v not in key.choices:
            raise ConfigError(f"{key.fq}: must be one of {', '.join(key.choices)}, got {value!r}")
        return v
    if key.kind == "vmid":
        if not re.fullmatch(r"[1-9]\d{2,8}", v) or int(v) < 100:
            raise ConfigError(f"{key.fq}: VMID must be a number >= 100, got {value!r}")
        return v
    if key.kind == "slot":
        return norm_slot(v)
    if key.kind == "cidr":
        if key.fq == "l1.ip" and v == "dhcp":
            return v
        try:
            iface = ipaddress.ip_interface(v)
        except ValueError:
            raise ConfigError(f"{key.fq}: expected CIDR like 192.168.1.50/24, got {value!r}") from None
        if iface.version != 4:
            raise ConfigError(f"{key.fq}: only IPv4 is supported")
        if key.fq == "l2.net_cidr":
            net = iface.network
            if net.prefixlen > 28:
                raise ConfigError(f"{key.fq}: network {net} is too small (need /28 or larger)")
            return str(net)
        if iface.network.prefixlen == 32:
            raise ConfigError(f"{key.fq}: give the prefix length, e.g. {v}/24")
        return str(iface)
    if key.kind == "ip":
        if v == "":
            return v
        try:
            ipaddress.IPv4Address(v)
        except ValueError:
            raise ConfigError(f"{key.fq}: expected an IPv4 address, got {value!r}") from None
        return v
    if key.kind == "path":
        if v and not v.startswith("/"):
            raise ConfigError(f"{key.fq}: expected an absolute path on the PVE host, got {value!r}")
        return v
    if "\n" in v:
        raise ConfigError(f"{key.fq}: newlines are not allowed")
    return v


class Config:
    """Validated settings. Access as cfg['l1.vmid'] (strings) or cfg.int/bool helpers."""

    def __init__(self, values: Optional[Dict[str, str]] = None, explicit: Optional[set] = None):
        self.values: Dict[str, str] = {k.fq: k.default for k in SCHEMA}
        self.explicit: set = set(explicit or ())
        for fq, v in (values or {}).items():
            self.set(fq, v)

    def set(self, fq: str, value: str, explicit: bool = True) -> None:
        if fq not in KEYS:
            raise ConfigError(f"unknown setting {fq!r}")
        self.values[fq] = _check(KEYS[fq], str(value))
        if explicit:
            self.explicit.add(fq)

    def __getitem__(self, fq: str) -> str:
        return self.values[fq]

    def int(self, fq: str) -> int:
        return int(self.values[fq])

    def bool(self, fq: str) -> bool:
        return as_bool(self.values[fq])

    def is_auto(self, fq: str) -> bool:
        return self.values[fq] == "auto"

    def edition(self) -> str:
        e = self.values["l2.windows_edition"]
        return f"Windows {self.values['l2.windows_version']} Pro" if e == "auto" else e

    def stage_files(self) -> List[Tuple[str, str]]:
        """(kind, host path) for every staging input that is set."""
        out = []
        for k in ("nvidia_driver", "python_installer", "wheelhouse", "openssh_zip"):
            if self.values[f"stage.{k}"]:
                out.append((k, self.values[f"stage.{k}"]))
        for p in split_list(self.values["stage.extra_files"]):
            out.append(("extra", p))
        return out

    def downloads(self) -> List[Tuple[str, str, str]]:
        return parse_downloads(self.values["stage.downloads"])

    def to_ini(self, include_secrets: bool = False) -> str:
        cp = configparser.ConfigParser(interpolation=None)
        for key in SCHEMA:
            if not cp.has_section(key.section):
                cp.add_section(key.section)
            v = self.values[key.fq]
            if key.secret and v and not include_secrets:
                v = ""
            cp.set(key.section, key.name, v)
        import io
        buf = io.StringIO()
        buf.write("# qemu-ad-pve setup config (secrets are not written back; see docs/SETUP.md)\n")
        cp.write(buf)
        return buf.getvalue()


def split_list(value: str) -> List[str]:
    return [p.strip() for p in value.split(",") if p.strip()]


def parse_downloads(value: str) -> List[Tuple[str, str, str]]:
    """'url sha256 [name]; ...' -> [(url, sha256, name)]. sha256 is mandatory."""
    out = []
    for entry in [e.strip() for e in value.split(";") if e.strip()]:
        parts = entry.split()
        if len(parts) not in (2, 3):
            raise ConfigError(f"stage.downloads: expected 'url sha256 [name]', got {entry!r}")
        url, sha = parts[0], parts[1].lower()
        if not url.startswith("https://"):
            raise ConfigError(f"stage.downloads: only https:// URLs are accepted, got {url!r}")
        if not re.fullmatch(r"[0-9a-f]{64}", sha):
            raise ConfigError(f"stage.downloads: {url}: sha256 must be 64 hex digits")
        name = parts[2] if len(parts) == 3 else url.rstrip("/").rsplit("/", 1)[-1]
        if not re.fullmatch(r"[A-Za-z0-9._+-]+", name):
            raise ConfigError(f"stage.downloads: unsafe file name {name!r}")
        out.append((url, sha, name))
    return out


def parse_ini(text: str, source: str = "<config>") -> Config:
    cp = configparser.ConfigParser(interpolation=None)
    try:
        cp.read_string(text, source=source)
    except configparser.Error as exc:
        raise ConfigError(f"{source}: {exc}") from None
    if cp.defaults():
        raise ConfigError(f"{source}: settings must be inside a [section]")
    values = {}
    for section in cp.sections():
        for name, value in cp.items(section):
            fq = f"{section}.{name}"
            if fq not in KEYS:
                raise ConfigError(f"{source}: unknown setting [{section}] {name}")
            values[fq] = value
    cfg = Config()
    for fq, v in values.items():
        try:
            cfg.set(fq, v)
        except ConfigError as exc:
            raise ConfigError(f"{source}: {exc}") from None
    return cfg


def cross_validate(cfg: Config) -> List[str]:
    """Checks that involve several keys. Returns problems (empty = fine)."""
    bad = []
    if cfg["l1.ip"] != "dhcp" and not cfg["l1.gateway"]:
        bad.append("l1.ip is static: set l1.gateway too")
    if cfg.int("l1.memory_mb") < cfg.int("l2.memory_mb") + 3072:
        bad.append(f"l1.memory_mb ({cfg['l1.memory_mb']}) must be at least l2.memory_mb + 3072 "
                   f"({cfg.int('l2.memory_mb') + 3072})")
    if cfg.int("l2.cores") > cfg.int("l1.cores"):
        bad.append("l2.cores cannot exceed l1.cores")
    src = cfg["l2.source"]
    if src == "iso" and not cfg["l2.windows_iso"]:
        bad.append("l2.source=iso needs l2.windows_iso (PVE volid like local:iso/Win10.iso or a path)")
    if src == "iso" and cfg["l2.windows_iso"]:
        w = cfg["l2.windows_iso"]
        if not (w.startswith("/") or VOLID_RE.match(w)):
            bad.append(f"l2.windows_iso {w!r} is neither an absolute path nor a PVE volid")
    if src == "image" and not cfg["l2.image"]:
        bad.append("l2.source=image needs l2.image (path to a qcow2/raw image on the PVE host)")
    au = cfg["l2.autounattend"]
    if au not in ("generate", "none") and not au.startswith("/"):
        bad.append("l2.autounattend must be generate, none or an absolute path")
    pk = cfg["l2.product_key"]
    if pk and not re.fullmatch(r"[A-Z0-9]{5}(-[A-Z0-9]{5}){4}", pk.upper()):
        bad.append("l2.product_key must look like XXXXX-XXXXX-XXXXX-XXXXX-XXXXX")
    if not re.fullmatch(r"[A-Za-z0-9-]{1,15}", cfg["l2.computer_name"]):
        bad.append("l2.computer_name: 1-15 letters, digits or '-'")
    if not re.fullmatch(r"[A-Za-z0-9_.-]{1,20}", cfg["l2.admin_user"]):
        bad.append("l2.admin_user: 1-20 letters, digits, '_', '.', '-'")
    for ch in "<>&\"'":
        if ch in cfg["l2.admin_password"]:
            bad.append("l2.admin_password must not contain < > & \" ' (they are written into XML)")
            break
    if not re.fullmatch(r"[A-Za-z0-9 ()+.,_-]{1,64}", cfg["l2.timezone"]):
        bad.append("l2.timezone has unexpected characters")
    if not re.fullmatch(r"[a-z]{2,3}-[A-Z]{2}", cfg["l2.locale"]):
        bad.append("l2.locale must look like en-US")
    if not re.fullmatch(r"[A-Za-z0-9 ()._-]{1,64}", cfg.edition()):
        bad.append("l2.windows_edition has unexpected characters")
    if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.-]{0,62}", cfg["l1.name"]):
        bad.append("l1.name must be a valid DNS name (letters, digits, '-', '.')")
    if not re.fullmatch(r"(127\.0\.0\.1:\d{1,2}|none)", cfg["l2.vnc"]):
        bad.append("l2.vnc must be 127.0.0.1:<display> (L1-local only) or none")
    if not re.fullmatch(r"[A-Za-z0-9_,=+.-]+", cfg["l2.cpu"]):
        bad.append("l2.cpu has unexpected characters")
    if not re.fullmatch(r"([0-9a-f]{2}:){2}[0-9a-f]{2}|", cfg["l2.mac_oui"]):
        bad.append("l2.mac_oui must look like a4:bf:01 (lower case) or be empty")
    elif cfg["l2.mac_oui"] and int(cfg["l2.mac_oui"][:2], 16) & 1:
        bad.append("l2.mac_oui must be a unicast OUI (first byte even)")
    for k in ("l2.disk_model", "l2.disk_serial", "l2.disk_firmware"):
        if not re.fullmatch(r"[A-Za-z0-9 ._-]{0,40}", cfg[k]):
            bad.append(f"{k} may only contain letters, digits, space, '.', '_' and '-' (max 40)")
    if cfg["l2.smbios"] not in ("asus-am5", "none"):
        bad.append("l2.smbios must be asus-am5 or none")
    if cfg["l2.smbios_chassis"] not in ("desktop", "none"):
        bad.append("l2.smbios_chassis must be desktop or none")
    pats = [x for x in re.split(r"[,\s]+", cfg["l2.optional_patches"]) if x and x.lower() != "none"]
    if cfg["l2.optional_patches"].strip().lower() == "none":
        pats = []
    for x in pats:
        if not re.fullmatch(r"[0-9]{4}-[a-z0-9-]+", x):
            bad.append(f"l2.optional_patches: bad patch name {x!r} (like 0001-acpi-omit-waet)")
    if not re.fullmatch(r"[A-Za-z0-9 ]{0,6}", cfg["l2.oem_id"]):
        bad.append("l2.oem_id: up to 6 letters/digits/spaces")
    if not re.fullmatch(r"[A-Za-z0-9 ]{0,8}", cfg["l2.oem_table_id"]):
        bad.append("l2.oem_table_id: up to 8 letters/digits/spaces")
    if not re.fullmatch(r"(0x[0-9A-Fa-f]{1,8})?", cfg["l2.oem_revision"]):
        bad.append("l2.oem_revision must be hex like 0x1072009")
    if cfg["l2.ovmf_identity"] not in ("yes", "no"):
        bad.append("l2.ovmf_identity must be yes or no")
    # l2.oem_* only reach QEMU with patch 0002; without it they still style the rebuilt OVMF (not an error).
    for k in ("l2.cdrom_model", "l2.cdrom_firmware"):
        if not re.fullmatch(r"[A-Za-z0-9 ._-]{0,40}", cfg[k]):
            bad.append(f"{k} may only contain letters, digits, space, '.', '_' and '-' (max 40)")
    if cfg["l2.cdrom_firmware"] and not cfg["l2.cdrom_model"]:
        bad.append("l2.cdrom_firmware needs l2.cdrom_model")
    if cfg["l2.gpu_link_speed"] not in ("", "2.5", "5", "8", "16", "32", "64"):
        bad.append("l2.gpu_link_speed must be empty or one of 2.5 5 8 16 32 64")
    if cfg["l2.gpu_link_width"] not in ("", "1", "2", "4", "8", "12", "16", "32"):
        bad.append("l2.gpu_link_width must be empty or one of 1 2 4 8 12 16 32")
    if cfg["l2.vga"] not in ("std", "none"):
        bad.append("l2.vga must be std or none")
    try:
        cfg.downloads()
    except ConfigError as exc:
        bad.append(str(exc))
    return bad


def l2_addresses(net_cidr: str) -> Tuple[str, str, str, str]:
    """(bridge_ip, l2_ip, dhcp_start, dhcp_end) inside the isolated L1<->L2 network."""
    net = ipaddress.ip_network(net_cidr)
    hosts = list(net.hosts())
    return str(hosts[0]), str(hosts[9 if len(hosts) > 12 else 1]), str(hosts[-3]), str(hosts[-2])


def answer_for_prompt(key: Key, raw: str, current: str) -> str:
    """Interactive answer -> value ('' keeps the current/default value)."""
    raw = raw.strip()
    return current if raw == "" else raw


Validator = Callable[[str], Optional[str]]
