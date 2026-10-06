"""Preflight: collect host facts (read-only) and evaluate them into a PASS/WARN/FAIL table.

``collect()`` only reads (sysfs, /proc, /etc/pve, `qm list`, `pvesm status`, ...).
``evaluate()`` is pure and unit-tested with fixtures.
"""
from __future__ import annotations

import json
import os
import shutil
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Set, Tuple

from . import hostinfo as hi
from .config import Config
from .runner import Runner

THIN_TYPES = {"lvmthin", "zfspool", "zfs", "btrfs", "dir", "nfs", "cifs", "rbd", "cephfs", "glusterfs"}
TOOLS = ["qm", "pvesm", "pvesh", "ssh", "scp", "ssh-keygen", "genisoimage", "qemu-img", "sha512sum", "tar"]
TESTED_PVE = (9, 2)
MIN_PVE = (8, 1)  # machine viommu=intel


@dataclass
class Check:
    name: str
    status: str  # PASS | WARN | FAIL | INFO
    detail: str
    fix: str = ""


@dataclass
class Snapshot:
    pveversion: str = ""
    is_root: bool = False
    cpu_vendor: str = "unknown"
    cpu_flags: Set[str] = field(default_factory=set)
    nested: Optional[bool] = None
    iommu: bool = False
    cmdline: str = ""
    gpus: List[hi.Gpu] = field(default_factory=list)
    vm_list: Dict[str, Tuple[str, str]] = field(default_factory=dict)  # vmid -> (name, status)
    vm_mem_mb: Dict[str, int] = field(default_factory=dict)
    storages: Dict[str, List[hi.Storage]] = field(default_factory=dict)  # content -> storages
    meminfo: Dict[str, int] = field(default_factory=dict)
    nextid: Optional[str] = None
    bridges: List[str] = field(default_factory=list)
    bridge_kinds: Dict[str, str] = field(default_factory=dict)  # bridge -> "linux" | "ovs"
    bridges_down: List[str] = field(default_factory=list)  # declared in /etc/network/interfaces, not present
    tools: Dict[str, bool] = field(default_factory=dict)
    host_qemu_ad: str = ""  # version line of /opt/qemu-ad/bin/qemu-system-x86_64, "" if absent
    paths: Dict[str, Optional[int]] = field(default_factory=dict)  # input path -> size (None = missing)
    iso_path: Optional[str] = None  # resolved path of l2.windows_iso
    image_vsize: Optional[int] = None
    var_lib_free: Optional[int] = None  # bytes free under /var/lib


# ------------------------------------------------------------------ collection (read-only)
def collect(cfg: Config, runner: Runner, root: str = "/") -> Snapshot:
    s = Snapshot()
    s.is_root = os.geteuid() == 0
    s.pveversion = runner.probe(["pveversion"]).stdout.strip()
    cpuinfo = _read(os.path.join(root, "proc/cpuinfo"))
    s.cpu_vendor = hi.parse_cpu_vendor(cpuinfo)
    s.cpu_flags = hi.parse_cpu_flags(cpuinfo)
    s.nested = hi.nested_enabled(root, s.cpu_vendor)
    s.iommu = hi.iommu_enabled(root)
    s.cmdline = _read(os.path.join(root, "proc/cmdline"))
    funcs = hi.read_sysfs_pci(root)
    names = hi.parse_lspci_nn(runner.probe(["lspci", "-Dnn"]).stdout)
    s.vm_list = hi.parse_qm_list(runner.probe(["qm", "list"]).stdout)
    running = {v for v, (_, st) in s.vm_list.items() if st == "running"}
    confs = hi.read_vm_confs(root)
    for vmid, conf in confs.items():
        if conf.get("memory", "").isdigit():
            s.vm_mem_mb[vmid] = int(conf["memory"])
    node = runner.probe(["hostname"]).stdout.strip()
    mappings = hi.parse_pci_mappings(_read(os.path.join(root, "etc/pve/mapping/pci.cfg")), node)
    vm_names = {v: n for v, (n, _) in s.vm_list.items()}
    s.gpus = hi.find_gpus(funcs, names)
    for g in s.gpus:
        g.refs = hi.refs_to_gpu(g, confs, running, vm_names, mappings)
    for content in ("images", "iso", "snippets"):
        s.storages[content] = hi.parse_pvesm_status(runner.probe(["pvesm", "status", "--content", content]).stdout)
    s.meminfo = hi.parse_meminfo(_read(os.path.join(root, "proc/meminfo")))
    s.nextid = hi.parse_nextid(runner.probe(["pvesh", "get", "/cluster/nextid"]).stdout)
    s.bridge_kinds, s.bridges_down = hi.detect_bridges(
        root, runner.probe(["ovs-vsctl", "list-br"]).stdout, runner.probe(["ip", "-o", "link", "show"]).stdout)
    s.bridges = list(s.bridge_kinds)
    s.tools = {t: shutil.which(t) is not None for t in TOOLS}
    s.tools["wget|curl"] = bool(shutil.which("wget") or shutil.which("curl"))
    qad = "/opt/qemu-ad/bin/qemu-system-x86_64"
    if os.access(qad, os.X_OK):
        s.host_qemu_ad = runner.probe([qad, "--version"]).stdout.split("\n")[0].strip() or "present"
    for _, p in cfg.stage_files():
        s.paths[p] = _size(p)
    for k in ("l1.debian_image", "l2.image"):
        if cfg[k]:
            s.paths[cfg[k]] = _size(cfg[k])
    if cfg["l2.autounattend"].startswith("/"):
        s.paths[cfg["l2.autounattend"]] = _size(cfg["l2.autounattend"])
    w = cfg["l2.windows_iso"]
    if cfg["l2.source"] == "iso" and w:
        s.iso_path = w if w.startswith("/") else (runner.probe(["pvesm", "path", w]).stdout.strip() or None)
        if s.iso_path:
            s.paths[s.iso_path] = _size(s.iso_path)
    if cfg["l2.source"] == "image" and cfg["l2.image"] and s.paths.get(cfg["l2.image"]) is not None:
        p = runner.probe(["qemu-img", "info", "--output", "json", cfg["l2.image"]], timeout=120)
        try:
            s.image_vsize = int(json.loads(p.stdout)["virtual-size"])
        except (ValueError, KeyError):
            s.image_vsize = None
    try:
        st = os.statvfs(os.path.join(root, "var/lib"))
        s.var_lib_free = st.f_bavail * st.f_frsize
    except OSError:
        s.var_lib_free = None
    return s


def _read(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def _size(path: str) -> Optional[int]:
    try:
        if os.path.isdir(path):
            return sum(os.path.getsize(os.path.join(path, f)) for f in os.listdir(path)
                       if os.path.isfile(os.path.join(path, f)))
        return os.path.getsize(path)
    except OSError:
        return None


# ------------------------------------------------------------------ GPU helpers
def gpu_candidates(s: Snapshot) -> List[hi.Gpu]:
    return [g for g in s.gpus if not g.foreign_group_members()]


def describe_gpu(g: hi.Gpu) -> str:
    fns = ", ".join(f"{f.bdf.rsplit(':', 1)[1]} {f.ids} [{f.driver or 'no driver'}]" for f in g.functions)
    refs = ", ".join(f"VM {r.vmid}{' (' + r.name + ')' if r.name else ''} {r.how} "
                     f"{'RUNNING' if r.running else 'stopped'}" for r in g.refs) or "no VM references it"
    groups = ",".join(g.groups) or "?"
    foreign = g.foreign_group_members()
    extra = f"; group also holds {', '.join(f.bdf for f in foreign)} (NOT isolatable)" if foreign else ""
    return f"{g.slot}  {g.name}\n      functions: {fns}\n      IOMMU group {groups}{extra}\n      {refs}"


def pick_gpu(s: Snapshot, slot: str) -> Optional[hi.Gpu]:
    return next((g for g in s.gpus if g.slot == slot), None)


def choose_storage(storages: List[hi.Storage], prefer: Tuple[str, ...] = ("local-lvm", "local-zfs", "local")) -> Optional[str]:
    act = [x for x in storages if x.active]
    for p in prefer:
        if any(x.name == p for x in act):
            return p
    act.sort(key=lambda x: x.avail_kib, reverse=True)
    return act[0].name if act else None


def needed_gib(cfg: Config, s: Snapshot) -> float:
    need = cfg.int("l1.disk_gb") + 0.1
    if cfg["l2.source"] == "iso":
        need += cfg.int("l2.disk_gb")
    elif cfg["l2.source"] == "image":
        need += (s.image_vsize or 0) / 1024 ** 3
    return need


# ------------------------------------------------------------------ evaluation (pure)
def evaluate(cfg: Config, s: Snapshot, vmid: Optional[str], gpu: Optional[hi.Gpu],
             own_vm: bool = False) -> List[Check]:
    """own_vm=True when resuming: vmid is the L1 VM this setup already created (manifest + marker)."""
    out: List[Check] = []
    own_running = bool(own_vm and vmid and s.vm_list.get(vmid, ("", ""))[1] == "running")
    if gpu is not None and own_vm:
        gpu = hi.Gpu(gpu.slot, gpu.functions, gpu.group_members, [r for r in gpu.refs if r.vmid != vmid])
    add = out.append
    ver = hi.parse_pveversion(s.pveversion)
    if ver is None:
        add(Check("Proxmox VE", "FAIL", "pveversion not found / unparsable", "Run setup.sh on the PVE node itself."))
    elif ver[:2] < MIN_PVE:
        add(Check("Proxmox VE", "FAIL", f"{s.pveversion.split()[0]} (need >= 8.1 for machine viommu=intel)",
                  "Upgrade PVE first (not done by this tool)."))
    elif ver[:2] != TESTED_PVE:
        add(Check("Proxmox VE", "WARN", f"{s.pveversion.split()[0]}; lab-tested on 9.2.x", ""))
    else:
        add(Check("Proxmox VE", "PASS", s.pveversion.split()[0]))
    add(Check("root", "PASS" if s.is_root else "FAIL", "running as root" if s.is_root else "not root",
              "" if s.is_root else "Run as root: sudo ./setup.sh ..."))
    if s.cpu_vendor == "amd":
        add(Check("CPU vendor", "PASS", "AMD (the lab-tested combination: AMD host + Intel vIOMMU in L1)"))
    elif s.cpu_vendor == "intel":
        add(Check("CPU vendor", "WARN", "Intel: L1 will use kvm_intel; only AMD hosts were tested",
                  "Expect differences; please report results."))
    else:
        add(Check("CPU vendor", "FAIL", f"unknown vendor {s.cpu_vendor!r}"))
    virt = "svm" if s.cpu_vendor == "amd" else "vmx"
    if virt not in s.cpu_flags:
        add(Check("Hardware virtualization", "FAIL", f"no '{virt}' CPU flag", "Enable SVM/VT-x in the BIOS."))
    if s.nested is False:
        mod = "kvm_amd" if s.cpu_vendor == "amd" else "kvm_intel"
        add(Check("Nested virtualization", "FAIL", f"{mod} nested=0 on the host",
                  f"L1 needs nested KVM. This tool does not change host modules; enable it yourself "
                  f"(options {mod} nested=1) and reboot, or decide otherwise."))
    elif s.nested is True:
        add(Check("Nested virtualization", "PASS", "enabled on the host kvm module"))
    else:
        add(Check("Nested virtualization", "WARN", "could not read the kvm module's nested parameter"))
    if s.iommu:
        add(Check("Host IOMMU", "PASS", "IOMMU groups present"))
    else:
        add(Check("Host IOMMU", "FAIL", "/sys/kernel/iommu_groups is empty",
                  "Enable IOMMU/AMD-Vi in BIOS (and amd_iommu=on / intel_iommu=on on the kernel cmdline). "
                  "Not changed by this tool."))
    # ---- GPU
    if not s.gpus:
        add(Check("GPU", "FAIL", "no display-class PCI device found"))
    elif gpu is None:
        cands = gpu_candidates(s)
        add(Check("GPU", "FAIL", f"no GPU selected ({len(cands)} candidate(s))",
                  "Set gpu.slot (see the GPU list above) or answer the picker."))
    else:
        foreign = gpu.foreign_group_members()
        if foreign:
            add(Check("GPU IOMMU group", "FAIL", f"group {','.join(gpu.groups)} also holds "
                      f"{', '.join(f.bdf + ' ' + f.ids for f in foreign)}",
                      "Use another slot / ACS-capable port. vfio needs every endpoint of the group."))
        else:
            add(Check("GPU IOMMU group", "PASS", f"{gpu.slot}: group {','.join(gpu.groups)} holds only its "
                      f"{len(gpu.functions)} function(s)"))
        if len(gpu.functions) < 2:
            add(Check("GPU functions", "WARN", "single function: the lab passed video+audio; "
                      "single-function was not tested"))
        elif len(gpu.functions) > 2:
            add(Check("GPU functions", "WARN", f"{len(gpu.functions)} functions (lab-tested: 2); all are passed"))
        drv = gpu.drivers()
        if own_running:
            drv = {b: "vfio-pci" for b in drv}  # in use by our own running L1
        not_vfio = {b: d for b, d in drv.items() if d != "vfio-pci"}
        disp_host = [b for b, d in not_vfio.items() if d and any(f.bdf == b and f.cls.startswith("03")
                                                                   for f in gpu.functions)]
        if not not_vfio:
            add(Check("GPU on vfio-pci", "PASS", ", ".join(f"{b.rsplit(':', 1)[1]}=vfio-pci" for b in drv)))
        else:
            fix = ("The GPU guard (scripts/qm-native-9200) refuses `qm start` unless every function is on vfio-pci, and setup.sh "
                   "does not change host driver config. Either start + shut down a VM that has this GPU as hostpci "
                   "once (qm binds it to vfio-pci and leaves it there), bind it yourself until the next host reboot "
                   "(for each function: echo vfio-pci > /sys/bus/pci/devices/<bdf>/driver_override; echo <bdf> > "
                   "/sys/bus/pci/devices/<bdf>/driver/unbind; echo <bdf> > /sys/bus/pci/drivers_probe), or make it "
                   "permanent with your own `options vfio-pci ids=...` in /etc/modprobe.d.")
            if disp_host:
                fix = "The HOST is using the display function; pick another GPU or free it first. " + fix
            add(Check("GPU on vfio-pci", "FAIL", "not on vfio-pci: " + ", ".join(
                f"{b.rsplit(':', 1)[1]}={d or 'no driver'}" for b, d in not_vfio.items()), fix))
        running = gpu.running_refs()
        if running:
            add(Check("GPU in use", "FAIL", "running VM(s) use it: " + ", ".join(f"{r.vmid} ({r.how})" for r in running),
                      "Shut them down first, e.g. " + "; ".join(f"qm shutdown {r.vmid}" for r in running)
                      + ". setup.sh never stops other VMs."))
        elif gpu.refs:
            add(Check("GPU in use", "WARN", "stopped VM(s) also reference it: " + ", ".join(r.vmid for r in gpu.refs),
                      "Only one can run at a time: with the GPU guard, qemu-server refuses whichever VM starts second."))
        else:
            add(Check("GPU in use", "PASS", "no other VM references it"))
    # ---- VMID
    if vmid is None:
        add(Check("VMID", "FAIL", "no free VMID", "Set l1.vmid."))
    elif own_vm:
        add(Check("VMID", "PASS", f"{vmid} exists and was created by this setup (resuming)"))
    elif vmid in s.vm_list:
        add(Check("VMID", "FAIL", f"{vmid} already exists ({s.vm_list[vmid][0]})", f"Pick another, e.g. {s.nextid}."))
    else:
        add(Check("VMID", "PASS", f"{vmid} is free" + (f" (next free: {s.nextid})" if s.nextid and s.nextid != vmid else "")))
    # ---- storage
    imgs = {x.name: x for x in s.storages.get("images", [])}
    st = imgs.get(cfg["l1.storage"])
    need = needed_gib(cfg, s)
    if own_vm and st is not None:
        add(Check("Disk storage", "PASS", f"{st.name}: L1 disks already allocated"))
    elif st is None:
        add(Check("Disk storage", "FAIL", f"{cfg['l1.storage']!r} has no 'images' content or does not exist",
                  "Choose one of: " + ", ".join(imgs) if imgs else "No images storage found."))
    elif not st.active:
        add(Check("Disk storage", "FAIL", f"{st.name} is {st.status}"))
    elif st.avail_gib < need:
        thin = st.type in THIN_TYPES
        add(Check("Disk storage", "WARN" if thin else "FAIL",
                  f"{st.name} ({st.type}) {st.avail_gib:.0f} GiB free < {need:.0f} GiB provisioned",
                  "Thin storage: OK until the guests fill it up." if thin else "Free space or pick another storage."))
    else:
        add(Check("Disk storage", "PASS", f"{st.name} ({st.type}) {st.avail_gib:.0f} GiB free, needs {need:.0f} GiB"))
    isos = {x.name: x for x in s.storages.get("iso", [])}
    if cfg["l1.iso_storage"] not in isos:
        add(Check("Seed ISO storage", "FAIL", f"{cfg['l1.iso_storage']!r} has no 'iso' content",
                  "Choose one of: " + ", ".join(isos) if isos else "No iso storage found."))
    else:
        add(Check("Seed ISO storage", "PASS", f"{cfg['l1.iso_storage']} (cloud-init seed ISO goes here)"))
    if cfg["l1.hookscript"] == "yes":
        snips = {x.name for x in s.storages.get("snippets", [])}
        if cfg["l1.snippets_storage"] not in snips:
            add(Check("GPU-guard hookscript", "FAIL", "no existing storage has content 'snippets'",
                      "setup.sh does not change storage.cfg. Enable 'snippets' on a storage yourself (Datacenter > "
                      "Storage > <storage> > Content) and re-run, or set l1.hookscript=no (NOT recommended: then "
                      "nothing stops a hostpci VM from taking the GPU while L1 runs)."))
        else:
            add(Check("GPU-guard hookscript", "PASS", f"{cfg['l1.snippets_storage']}:snippets/"
                      f"qad-l1-{vmid or '<vmid>'}-gpu-guard.pl (qm-native-9200 guard)"))
    else:
        add(Check("GPU-guard hookscript", "WARN", "disabled: qemu-server will not know L1 holds the GPU",
                  "Another VM with this GPU as hostpci could start (and reset the GPU) while L1 runs."))
    # ---- bridge
    br = cfg["l1.bridge"]
    kinds = s.bridge_kinds or {b: hi.LINUX for b in s.bridges}
    if br in kinds:
        add(Check("Bridge", "PASS", br + (" (Open vSwitch)" if kinds[br] == hi.OVS else " (Linux bridge)")))
    elif br in s.bridges_down:
        add(Check("Bridge", "WARN", f"{br} is declared in /etc/network/interfaces but not present (not up?)",
                  "Bring it up (`ifreload -a`, or Apply Configuration in the node's Network panel) and re-run."))
    elif kinds:
        add(Check("Bridge", "FAIL", f"{br} not found (checked Linux bridges, `ovs-vsctl list-br`, "
                  "/etc/network/interfaces + `ip link`)", "Choose one of: " + ", ".join(
                      f"{b} (OVS)" if k == hi.OVS else b for b, k in kinds.items())))
    else:
        add(Check("Bridge", "WARN", f"{br}: no bridge detected on this host, cannot verify",
                  "Check `ip link` / `ovs-vsctl list-br`; qm create fails later if the bridge does not exist."))
    # ---- RAM
    avail_mb = s.meminfo.get("MemAvailable", 0) // 1024
    need_mb = cfg.int("l1.memory_mb") + 1024
    freed = 0
    if gpu:
        freed = sum(s.vm_mem_mb.get(r.vmid, 0) for r in gpu.running_refs())
    if own_running:
        add(Check("Host RAM", "PASS", f"L1 {vmid} is already running"))
    elif avail_mb >= need_mb:
        add(Check("Host RAM", "PASS", f"{avail_mb} MiB available, L1 needs {cfg['l1.memory_mb']} MiB (+1 GiB margin)"))
    elif avail_mb + freed >= need_mb:
        add(Check("Host RAM", "WARN", f"{avail_mb} MiB available now; enough once the GPU VM(s) are stopped "
                  f"(+{freed} MiB)"))
    else:
        add(Check("Host RAM", "FAIL", f"{avail_mb} MiB available < {need_mb} MiB",
                  "Lower l1.memory_mb/l2.memory_mb or stop other VMs. vfio pins all L1 RAM (no ballooning)."))
    # ---- tools
    missing = [t for t, ok in s.tools.items() if not ok]
    if missing:
        add(Check("Host tools", "FAIL", "missing: " + ", ".join(missing),
                  "These ship with PVE (qemu-server depends on genisoimage). Nothing is installed by this tool."))
    else:
        add(Check("Host tools", "PASS", "qm, pvesm, pvesh, ssh, genisoimage, qemu-img, wget/curl present"))
    if s.var_lib_free is not None and s.var_lib_free < 2 * 1024 ** 3 and not cfg["l1.debian_image"]:
        add(Check("Space in /var/lib", "WARN", f"{s.var_lib_free // 1024 ** 2} MiB free; the Debian image "
                  "cache needs ~1 GiB", "Free space or set l1.debian_image to an existing qcow2."))
    # ---- qemu-ad binary
    mode = cfg["l1.qemu_ad"]
    if mode in ("auto", "copy") and s.host_qemu_ad:
        add(Check("qemu-ad-pve binary", "PASS", f"copy host /opt/qemu-ad into L1 (read-only): {s.host_qemu_ad}"))
    elif mode == "copy":
        add(Check("qemu-ad-pve binary", "FAIL", "l1.qemu_ad=copy but /opt/qemu-ad is not on the host",
                  "Use l1.qemu_ad=build (built inside L1 with qemu-ad-pve.sh build)."))
    else:
        add(Check("qemu-ad-pve binary", "INFO", "built inside L1 (qemu-ad-pve.sh build; 5-60 min)"))
    # ---- inputs
    src = cfg["l2.source"]
    if src == "iso":
        if not s.iso_path or s.paths.get(s.iso_path) is None:
            add(Check("Windows ISO", "FAIL", f"{cfg['l2.windows_iso'] or '(unset)'} not found",
                      "Upload it (e.g. to local:iso) and set l2.windows_iso."))
        else:
            add(Check("Windows ISO", "PASS", f"{s.iso_path} ({s.paths[s.iso_path] // 1024 ** 2} MiB)"))
    elif src == "image":
        if s.paths.get(cfg["l2.image"]) is None:
            add(Check("Windows image", "FAIL", f"{cfg['l2.image'] or '(unset)'} not found"))
        else:
            add(Check("Windows image", "PASS", f"{cfg['l2.image']} (virtual size "
                      f"{(s.image_vsize or 0) // 1024 ** 3} GiB); it must already boot on SATA/AHCI + e1000e"))
    else:
        add(Check("Windows L2", "INFO", "l2.source=none: only L1 is set up"))
    for kind, p in cfg.stage_files():
        if s.paths.get(p) is None:
            add(Check(f"Staging: {kind}", "FAIL", f"{p} not found", "Fix the path or clear the setting."))
        else:
            add(Check(f"Staging: {kind}", "PASS", f"{p} ({s.paths[p] // 1024 ** 2} MiB)"))
    if cfg["l1.debian_image"] and s.paths.get(cfg["l1.debian_image"]) is None:
        add(Check("Debian image", "FAIL", f"{cfg['l1.debian_image']} not found"))
    au = cfg["l2.autounattend"]
    if au.startswith("/") and s.paths.get(au) is None:
        add(Check("autounattend.xml", "FAIL", f"{au} not found"))
    if src != "none" and not any(k == "nvidia_driver" for k, _ in cfg.stage_files()):
        add(Check("NVIDIA driver", "WARN", "stage.nvidia_driver not set: the L2 gets no NVIDIA driver offline",
                  "Download the Windows driver yourself and set stage.nvidia_driver (no proprietary download "
                  "without --download-proprietary)."))
    return out


def failed(checks: List[Check]) -> List[Check]:
    return [c for c in checks if c.status == "FAIL"]
