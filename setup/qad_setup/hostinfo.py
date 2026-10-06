"""Read-only facts about the PVE host: parsers (pure, unit-tested) and thin collectors.

Collectors take a ``root`` prefix (default "/") so tests can point them at a fake
sysfs/procfs/etc tree. Nothing in this module writes anything.
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional, Set, Tuple

BDF_RE = re.compile(r"^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$")
ANY_BDF_RE = re.compile(r"(?:(?P<dom>[0-9a-fA-F]{4}):)?(?P<bus>[0-9a-fA-F]{2}):(?P<dev>[0-9a-fA-F]{2})(?:\.(?P<fn>[0-7]))?")


# ------------------------------------------------------------------ PCI / IOMMU
@dataclass
class PciFunc:
    bdf: str
    vendor: str  # "10de"
    device: str  # "2704"
    cls: str  # "0300" (class+subclass)
    driver: str = ""
    iommu_group: Optional[str] = None
    name: str = ""

    @property
    def slot(self) -> str:
        return self.bdf.rsplit(".", 1)[0]

    @property
    def ids(self) -> str:
        return f"{self.vendor}:{self.device}"

    @property
    def is_bridge(self) -> bool:
        return self.cls.startswith("06")


@dataclass
class VmRef:
    vmid: str
    how: str  # "hostpci0", "args", "mapping:<name>"
    running: bool = False
    name: str = ""


@dataclass
class Gpu:
    slot: str
    functions: List[PciFunc]
    group_members: List[PciFunc] = field(default_factory=list)  # every device in the IOMMU group(s)
    refs: List[VmRef] = field(default_factory=list)

    @property
    def name(self) -> str:
        return self.functions[0].name or self.functions[0].ids

    @property
    def groups(self) -> List[str]:
        return sorted({f.iommu_group for f in self.functions if f.iommu_group is not None}, key=_numkey)

    def foreign_group_members(self) -> List[PciFunc]:
        """Endpoints sharing the IOMMU group that are not functions of this GPU slot (bridges are fine)."""
        mine = {f.bdf for f in self.functions}
        return [m for m in self.group_members if m.bdf not in mine and not m.is_bridge]

    def drivers(self) -> Dict[str, str]:
        return {f.bdf: f.driver for f in self.functions}

    def running_refs(self) -> List[VmRef]:
        return [r for r in self.refs if r.running]


def _numkey(s: str):
    return (0, int(s)) if s.isdigit() else (1, s)


def norm_bdf(text: str) -> Tuple[str, Optional[str]]:
    """'01:00' -> ('0000:01:00', None); '0000:01:00.1' -> ('0000:01:00', '1')."""
    m = ANY_BDF_RE.fullmatch(text.strip())
    if not m:
        raise ValueError(f"not a PCI address: {text!r}")
    dom = (m.group("dom") or "0000").lower()
    return f"{dom}:{m.group('bus').lower()}:{m.group('dev').lower()}", m.group("fn")


LSPCI_RE = re.compile(
    r"^(?P<bdf>(?:[0-9a-f]{4}:)?[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]) (?P<clsname>[^\[]+?) \[(?P<cls>[0-9a-f]{4})\]: "
    r"(?P<rest>.*)$"
)
IDS_RE = re.compile(r"\[([0-9a-f]{4}):([0-9a-f]{4})\]")


def parse_lspci_nn(text: str) -> Dict[str, PciFunc]:
    """Parse ``lspci -Dnn`` (or -nn) output into {bdf: PciFunc} (driver/group unset)."""
    out: Dict[str, PciFunc] = {}
    for line in text.splitlines():
        m = LSPCI_RE.match(line.strip())
        if not m:
            continue
        ids = IDS_RE.findall(m.group("rest"))
        if not ids:
            continue
        vendor, device = ids[-1]
        name = IDS_RE.sub("", m.group("rest"))
        name = re.sub(r"\s*\(rev [0-9a-f]+\)", "", name)
        name = re.sub(r"\s*\(prog-if.*$", "", name)
        bdf = m.group("bdf")
        if bdf.count(":") == 1:
            bdf = "0000:" + bdf
        out[bdf] = PciFunc(bdf=bdf, vendor=vendor, device=device, cls=m.group("cls"), name=" ".join(name.split()))
    return out


def _read(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().strip()
    except OSError:
        return ""


def read_sysfs_pci(root: str = "/") -> Dict[str, PciFunc]:
    """Every PCI function from /sys/bus/pci/devices with vendor/device/class/driver/iommu_group."""
    base = os.path.join(root, "sys/bus/pci/devices")
    out: Dict[str, PciFunc] = {}
    try:
        entries = sorted(os.listdir(base))
    except OSError:
        return out
    for bdf in entries:
        if not BDF_RE.match(bdf):
            continue
        d = os.path.join(base, bdf)
        vendor = _read(os.path.join(d, "vendor")).lower().replace("0x", "")
        device = _read(os.path.join(d, "device")).lower().replace("0x", "")
        cls = _read(os.path.join(d, "class")).lower().replace("0x", "")[:4]
        drv = os.path.join(d, "driver")
        driver = os.path.basename(os.readlink(drv)) if os.path.islink(drv) else ""
        grp = os.path.join(d, "iommu_group")
        group = os.path.basename(os.readlink(grp)) if os.path.islink(grp) else None
        out[bdf] = PciFunc(bdf=bdf, vendor=vendor, device=device, cls=cls, driver=driver, iommu_group=group)
    return out


def iommu_enabled(root: str = "/") -> bool:
    try:
        return len(os.listdir(os.path.join(root, "sys/kernel/iommu_groups"))) > 0
    except OSError:
        return False


def group_members(funcs: Dict[str, PciFunc], group: str) -> List[PciFunc]:
    return [f for f in funcs.values() if f.iommu_group == group]


def find_gpus(funcs: Dict[str, PciFunc], names: Optional[Dict[str, PciFunc]] = None) -> List[Gpu]:
    """Display-class devices (class 03xx), grouped by slot with all functions of that slot."""
    names = names or {}
    for bdf, f in funcs.items():
        if not f.name and bdf in names:
            f.name = names[bdf].name
    slots: Dict[str, List[PciFunc]] = {}
    for f in funcs.values():
        slots.setdefault(f.slot, []).append(f)
    gpus = []
    for slot, fs in sorted(slots.items()):
        if not any(f.cls.startswith("03") for f in fs):
            continue
        fs.sort(key=lambda f: f.bdf)
        members: Dict[str, PciFunc] = {}
        for g in {f.iommu_group for f in fs if f.iommu_group is not None}:
            for m in group_members(funcs, g):
                members[m.bdf] = m
        gpus.append(Gpu(slot=slot, functions=fs, group_members=sorted(members.values(), key=lambda f: f.bdf)))
    return gpus


# ------------------------------------------------------------------ VM configs
def current_section(conf_text: str) -> str:
    """Only the active config, i.e. up to the first [snapshot] / [special] section."""
    out = []
    for line in conf_text.splitlines():
        if line.startswith("["):
            break
        out.append(line)
    return "\n".join(out)


def parse_vm_conf(conf_text: str) -> Dict[str, str]:
    conf = {}
    for line in current_section(conf_text).splitlines():
        if not line or line.startswith("#"):
            continue
        k, sep, v = line.partition(":")
        if sep:
            conf[k.strip()] = v.strip()
    return conf


def parse_pci_mappings(text: str, node: str) -> Dict[str, List[str]]:
    """/etc/pve/mapping/pci.cfg -> {mapping name: [bdf/slot strings for this node]}."""
    out: Dict[str, List[str]] = {}
    cur = None
    for line in text.splitlines():
        if not line.strip():
            continue
        if not line[0].isspace():
            cur = line.strip()
            out.setdefault(cur, [])
            continue
        if cur is None:
            continue
        k, _, v = line.strip().partition(" ")
        if k == "map":
            props = dict(p.split("=", 1) for p in v.split(",") if "=" in p)
            if props.get("node") == node and "path" in props:
                out[cur].extend(props["path"].split(";"))
    return out


def vm_pci_refs(conf: Dict[str, str], mappings: Optional[Dict[str, List[str]]] = None) -> List[Tuple[str, str, Optional[str]]]:
    """[(how, slot, fn-or-None)] for every PCI device a VM config references."""
    mappings = mappings or {}
    refs = []
    for k, v in conf.items():
        if re.fullmatch(r"hostpci\d+", k):
            first = v.split(",", 1)[0]
            if first.startswith("mapping="):
                name = first.split("=", 1)[1]
                targets = [(f"{k}(mapping:{name})", t) for t in mappings.get(name, [])]
            else:
                if first.startswith("host="):
                    first = first.split("=", 1)[1]
                targets = [(k, t) for t in first.split(";")]
            for how, t in targets:
                try:
                    slot, fn = norm_bdf(t)
                except ValueError:
                    continue
                refs.append((how, slot, fn))
        elif k == "args":
            for m in re.finditer(r"host=([0-9a-fA-F:.]+)", v):
                try:
                    slot, fn = norm_bdf(m.group(1))
                except ValueError:
                    continue
                refs.append(("args", slot, fn))
    return refs


def refs_to_gpu(gpu: Gpu, vm_confs: Dict[str, Dict[str, str]], running: Set[str],
                names: Optional[Dict[str, str]] = None,
                mappings: Optional[Dict[str, List[str]]] = None) -> List[VmRef]:
    names = names or {}
    fns = {f.bdf for f in gpu.functions}
    out = []
    for vmid, conf in sorted(vm_confs.items(), key=lambda kv: int(kv[0]) if kv[0].isdigit() else 0):
        for how, slot, fn in vm_pci_refs(conf, mappings):
            if slot != gpu.slot:
                continue
            if fn is not None and f"{slot}.{fn}" not in fns:
                continue
            out.append(VmRef(vmid=vmid, how=how, running=vmid in running, name=names.get(vmid, conf.get("name", ""))))
            break
    return out


def read_vm_confs(root: str = "/") -> Dict[str, Dict[str, str]]:
    d = os.path.join(root, "etc/pve/qemu-server")
    out = {}
    try:
        files = os.listdir(d)
    except OSError:
        return out
    for f in files:
        m = re.fullmatch(r"(\d+)\.conf", f)
        if m:
            out[m.group(1)] = parse_vm_conf(_read(os.path.join(d, f)))
    return out


def parse_qm_list(text: str) -> Dict[str, Tuple[str, str]]:
    """``qm list`` -> {vmid: (name, status)}."""
    out = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0].isdigit():
            out[parts[0]] = (parts[1], parts[2])
    return out


# ------------------------------------------------------------------ storage / host
@dataclass
class Storage:
    name: str
    type: str
    status: str
    total_kib: int
    used_kib: int
    avail_kib: int

    @property
    def avail_gib(self) -> float:
        return self.avail_kib / 1024 / 1024

    @property
    def active(self) -> bool:
        return self.status == "active"


def parse_pvesm_status(text: str) -> List[Storage]:
    out = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) < 6 or parts[0] == "Name":
            continue
        try:
            out.append(Storage(parts[0], parts[1], parts[2], int(parts[3]), int(parts[4]), int(parts[5])))
        except ValueError:
            continue
    return out


def parse_meminfo(text: str) -> Dict[str, int]:
    """/proc/meminfo -> {key: KiB}."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"(\w+):\s+(\d+)", line)
        if m:
            out[m.group(1)] = int(m.group(2))
    return out


def parse_cpu_vendor(cpuinfo: str) -> str:
    m = re.search(r"^vendor_id\s*:\s*(\S+)", cpuinfo, re.M)
    v = m.group(1) if m else ""
    return {"AuthenticAMD": "amd", "GenuineIntel": "intel"}.get(v, v or "unknown")


def parse_cpu_flags(cpuinfo: str) -> Set[str]:
    m = re.search(r"^flags\s*:\s*(.*)$", cpuinfo, re.M)
    return set(m.group(1).split()) if m else set()


def parse_pveversion(text: str) -> Optional[Tuple[int, int, int]]:
    m = re.search(r"pve-manager/(\d+)\.(\d+)(?:\.(\d+))?", text)
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), int(m.group(3) or 0)


def nested_enabled(root: str, vendor: str) -> Optional[bool]:
    mod = {"amd": "kvm_amd", "intel": "kvm_intel"}.get(vendor)
    if not mod:
        return None
    v = _read(os.path.join(root, f"sys/module/{mod}/parameters/nested"))
    if not v:
        return None
    return v.upper() in ("1", "Y")


def parse_guest_ifaces(text: str, mac: Optional[str] = None) -> List[str]:
    """``qm guest cmd <vmid> network-get-interfaces`` JSON -> IPv4 addresses (MAC match first)."""
    try:
        data = json.loads(text)
    except ValueError:
        return []
    if isinstance(data, dict):
        data = data.get("result", [])
    preferred, other = [], []
    for iface in data if isinstance(data, list) else []:
        if iface.get("name") == "lo":
            continue
        hw = (iface.get("hardware-address") or "").lower()
        for a in iface.get("ip-addresses", []) or []:
            if a.get("ip-address-type") != "ipv4":
                continue
            ip = a.get("ip-address", "")
            if ip.startswith("127.") or ip.startswith("169.254."):
                continue
            (preferred if mac and hw == mac.lower() else other).append(ip)
    return preferred + other


def parse_net0_mac(net0: str) -> Optional[str]:
    m = re.search(r"(?:virtio|e1000e?|vmxnet3|rtl8139|macaddr)=([0-9A-Fa-f:]{17})", net0)
    return m.group(1).upper() if m else None


def parse_nextid(text: str) -> Optional[str]:
    t = text.strip().strip('"')
    return t if t.isdigit() else None


def iter_bridges(root: str = "/") -> Iterable[str]:
    d = os.path.join(root, "sys/class/net")
    try:
        names = sorted(os.listdir(d))
    except OSError:
        return []
    return [n for n in names if os.path.isdir(os.path.join(d, n, "bridge"))]


# Bridges PVE can attach a VM NIC to: Linux bridges (sysfs .../bridge) AND Open vSwitch bridges.
# An OVS bridge is a netdev without a sysfs "bridge" dir, so iter_bridges() alone misses it
# (live QA: vmbr1 is OVS and preflight reported "vmbr1 not found").
OVS, LINUX = "ovs", "linux"
_NOT_FOR_VMS = ("fwbr", "fwpr", "fwln", "tap", "veth", "ovs-system")


def parse_ovs_list_br(text: str) -> List[str]:
    """`ovs-vsctl list-br`: one bridge per line."""
    return [ln.strip() for ln in text.splitlines() if ln.strip()]


def parse_ip_link_names(text: str) -> List[str]:
    """`ip -o link show`: "2: eno1: <...>" / "5: vmbr0.10@vmbr0: <...>" -> names (no @parent)."""
    out = []
    for ln in text.splitlines():
        m = re.match(r"^\d+:\s+([^:\s]+):", ln)
        if m:
            out.append(m.group(1).split("@", 1)[0])
    return out


def parse_interfaces_bridges(text: str) -> Dict[str, str]:
    """/etc/network/interfaces (ifupdown2 syntax): bridges declared in iface stanzas.

    ``ovs_type OVSBridge`` -> "ovs"; ``bridge-ports``/``bridge_ports`` -> "linux"."""
    out: Dict[str, str] = {}
    cur: Optional[str] = None
    for raw in text.splitlines():
        ln = raw.split("#", 1)[0].strip()
        if not ln:
            continue
        w = ln.split()
        if w[0] == "iface" and len(w) >= 2:
            cur = w[1]
            continue
        if w[0] in ("auto", "source", "source-directory", "mapping") or w[0].startswith("allow-"):
            cur = None  # a new top-level stanza ends the current iface block
            continue
        if cur is None:
            continue
        if w[0] == "ovs_type" and len(w) >= 2 and w[1] == "OVSBridge":
            out[cur] = OVS
        elif w[0] in ("bridge-ports", "bridge_ports") and out.get(cur) != OVS:
            out[cur] = LINUX
    return out


def read_interfaces(root: str = "/") -> str:
    """/etc/network/interfaces plus /etc/network/interfaces.d/* (PVE's default `source` line)."""
    parts = []
    base = os.path.join(root, "etc/network")
    files = [os.path.join(base, "interfaces")]
    try:
        files += [os.path.join(base, "interfaces.d", n) for n in sorted(os.listdir(os.path.join(base, "interfaces.d")))]
    except OSError:
        pass
    for f in files:
        try:
            with open(f, encoding="utf-8", errors="replace") as fh:
                parts.append(fh.read())
        except OSError:
            continue
    return "\n".join(parts)


def detect_bridges(root: str = "/", ovs_list_br: str = "", ip_link: str = "") -> Tuple[Dict[str, str], List[str]]:
    """Return ({bridge: "linux"|"ovs"} that exist now, [bridges declared in interfaces but not present]).

    Sources: sysfs bridge dirs (Linux), `ovs-vsctl list-br` (OVS), /etc/network/interfaces
    (``ovs_type OVSBridge`` / ``bridge-ports``) cross-checked against `ip -o link show` and
    /sys/class/net so a declared-but-down bridge is not reported as usable."""
    kinds: Dict[str, str] = {b: LINUX for b in iter_bridges(root)}
    for b in parse_ovs_list_br(ovs_list_br):
        kinds[b] = OVS
    present = set(parse_ip_link_names(ip_link))
    try:
        present |= set(os.listdir(os.path.join(root, "sys/class/net")))
    except OSError:
        pass
    down = []
    for b, kind in parse_interfaces_bridges(read_interfaces(root)).items():
        if b in present:
            if b not in kinds or kind == OVS:
                kinds[b] = kind
        elif b not in kinds:
            down.append(b)
    for b in list(kinds):
        if b.startswith(_NOT_FOR_VMS):
            del kinds[b]
    return dict(sorted(kinds.items())), sorted(down)
