#!/usr/bin/env python3
"""gen-launch.py - turn `qm showcmd <vmid>` output into a raw QEMU launch script.

Why: `qm` cannot express the topology that made GPU passthrough work through a
nested L1 (docs: PR #4 / #5 / #6 of this repo, summarised in docs/roadmap.md):

* Intel vIOMMU (AMD vIOMMU never registered a VFIO notifier):
  `-machine ...,kernel-irqchip=split` plus
  `-device intel-iommu,intremap=on,caching-mode=on`.
* BOTH GPU functions (video + audio) behind one pcie-root-port ->
  pcie-pci-bridge, so they share one IOMMU address space (qm's native
  topology fails with "group 13 used in multiple address spaces").
* A large 64-bit MMIO aperture for the GPU's BARs (AI workloads need the full
  BAR / VRAM mapping): `-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536`.

GPU passthrough with a vIOMMU is a first-class requirement, not an option:
those three things are applied by default and `check()` fails the run if the
result violates them.  Everything else is a pass-through of qm's own output.

Host impact: none.  This tool only reads text and writes a script; it never
runs qm, qemu or touches a VM.  The generated script, when *you* run it, starts
one QEMU process with the same disks/NICs as qm would; qm's VM config is not
modified.  Remove the script and nothing remains.

Usage:
    qm showcmd 9200 | tools/gen-launch.py - -o /root/launch-9200.sh
    tools/gen-launch.py showcmd.txt --qemu-bin /opt/qemu-ad/bin/qemu-system-x86_64
"""
from __future__ import annotations

import argparse
import os
import re
import shlex
import stat
import sys
from dataclasses import dataclass, field

# Flags that take no value in QEMU's command line (the ones qm emits).
BOOL_FLAGS = {
    "-daemonize", "-no-shutdown", "-nodefaults", "-S", "-no-reboot",
    "-enable-kvm", "-nographic", "-snapshot", "-no-user-config", "-usb",
    "-no-hpet",
}

MIN_MMIO64_MB = 32768  # 32 GiB: room for a 16 GiB BAR1 plus headroom
DEFAULT_MMIO64_MB = 65536
FWCFG_MMIO64 = "opt/ovmf/X-PciMmio64Mb"
ROOT_BUSES = {"pcie.0", "pci.0"}


class GenError(Exception):
    """Input cannot be converted safely."""


# --------------------------------------------------------------------------
# command line parsing
# --------------------------------------------------------------------------
@dataclass
class Opt:
    flag: str
    value: str | None = None


def tokenize(text: str) -> list[str]:
    """Split showcmd text (single line, or --pretty with backslash-newlines)."""
    text = re.sub(r"\\\r?\n", " ", text)
    try:
        return shlex.split(text)
    except ValueError as exc:
        raise GenError(f"cannot tokenize input: {exc}") from exc


def parse_cmdline(tokens: list[str]) -> tuple[str, list[Opt]]:
    if not tokens:
        raise GenError("empty input")
    binary, rest = tokens[0], tokens[1:]
    if "kvm" not in os.path.basename(binary) and "qemu" not in os.path.basename(binary):
        raise GenError(f"first word {binary!r} does not look like a QEMU binary; is this `qm showcmd` output?")
    opts: list[Opt] = []
    i = 0
    while i < len(rest):
        tok = rest[i]
        if not tok.startswith("-"):
            raise GenError(f"unexpected bare argument {tok!r}")
        if tok in BOOL_FLAGS:
            opts.append(Opt(tok))
            i += 1
        elif i + 1 >= len(rest):
            raise GenError(f"option {tok} has no value")
        else:
            opts.append(Opt(tok, rest[i + 1]))
            i += 2
    return binary, opts


def split_props(value: str) -> list[tuple[str, str | None]]:
    """Split a QEMU option value on commas ('' = literal comma) into (key, val)."""
    parts: list[str] = []
    cur: list[str] = []
    i = 0
    while i < len(value):
        ch = value[i]
        if ch == ",":
            if i + 1 < len(value) and value[i + 1] == ",":
                cur.append(",")
                i += 2
                continue
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
        i += 1
    parts.append("".join(cur))
    props: list[tuple[str, str | None]] = []
    for part in parts:
        if not part:
            continue
        if "=" in part:
            k, v = part.split("=", 1)
            props.append((k, v))
        else:
            props.append((part, None))
    return props


def join_props(props: list[tuple[str, str | None]]) -> str:
    out = []
    for k, v in props:
        out.append(k if v is None else f"{k}={v.replace(',', ',,')}")
    return ",".join(out)


def prop_get(props, key, default=None):
    for k, v in props:
        if k == key:
            return v
    return default


def prop_set(props, key, value):
    for idx, (k, _) in enumerate(props):
        if k == key:
            props[idx] = (key, value)
            return
    props.append((key, value))


def prop_del(props, *keys):
    props[:] = [(k, v) for k, v in props if k not in keys]


def driver_of(opt: Opt) -> str | None:
    if opt.flag != "-device" or opt.value is None:
        return None
    props = split_props(opt.value)
    return props[0][0] if props and props[0][1] is None else None


def mkdev(driver: str, **props) -> Opt:
    plist: list[tuple[str, str | None]] = [(driver, None)]
    plist += [(k.replace("_", "-"), str(v)) for k, v in props.items()]
    return Opt("-device", join_props(plist))


# --------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------
@dataclass
class Config:
    qemu_bin: str | None = None
    qemu_share: str | None = None
    argv0: str = "/usr/bin/kvm"
    gpu: list[str] = field(default_factory=list)  # PCI slots "0000:02:00"
    topology: str = "bridge"  # bridge | root-port
    own_root_port: bool = False
    pref64_reserve: str | None = None
    mmio64_mb: int = DEFAULT_MMIO64_MB
    iommu_extra: list[str] = field(default_factory=list)  # key=value for intel-iommu
    iommu_position: str = "first"  # first | keep
    allow_single_function: bool = False
    allow_small_mmio: bool = False
    no_virtio: bool = False
    keep_id: bool = False
    extra_args: list[str] = field(default_factory=list)


def norm_bdf(bdf: str) -> str:
    """'02:00.0' -> '0000:02:00.0'"""
    if not re.fullmatch(r"([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}\.[0-7]", bdf):
        raise GenError(f"not a PCI address: {bdf!r}")
    return (bdf if bdf.count(":") == 2 else "0000:" + bdf).lower()


def norm_slot(slot: str) -> str:
    if re.fullmatch(r"([0-9a-fA-F]{4}:)?[0-9a-fA-F]{2}:[0-9a-fA-F]{2}", slot):
        return (slot if slot.count(":") == 2 else "0000:" + slot).lower()
    raise GenError(f"--gpu wants a PCI slot like 0000:02:00 (no function), got {slot!r}")


# --------------------------------------------------------------------------
# transformation
# --------------------------------------------------------------------------
def _machine(opts: list[Opt], cfg: Config, warnings: list[str]) -> None:
    machines = [o for o in opts if o.flag in ("-machine", "-M") and o.value]
    if not machines:
        raise GenError("no -machine option: Intel vIOMMU needs a q35 machine")
    typ = None
    for o in machines:
        props = split_props(o.value)
        t = prop_get(props, "type") or (props[0][0] if props and props[0][1] is None else None)
        if t:
            typ = t
    if not typ or not typ.startswith(("q35", "pc-q35")):
        raise GenError(f"machine type {typ!r} is not q35; the Intel vIOMMU setup only exists for q35")
    seen = False
    for o in machines:
        props = split_props(o.value)
        if prop_get(props, "kernel-irqchip") is not None:
            prop_set(props, "kernel-irqchip", "split")
            seen = True
        if cfg.qemu_bin:  # alternate binary: drop PVE's machine-version suffix
            for idx, (k, v) in enumerate(props):
                if k == "type" and v:
                    props[idx] = (k, re.sub(r"\+pve\d+$", "", v))
                elif v is None and idx == 0:
                    props[idx] = (re.sub(r"\+pve\d+$", "", k), None)
        o.value = join_props(props)
    if not seen:
        last = max(i for i, o in enumerate(opts) if o in machines)
        opts.insert(last + 1, Opt("-machine", "kernel-irqchip=split"))


def _iommu(opts: list[Opt], cfg: Config, warnings: list[str]) -> None:
    props: list[tuple[str, str | None]] = [("intel-iommu", None)]
    first_idx = None
    kept: list[Opt] = []
    for o in opts:
        drv = driver_of(o)
        if drv == "amd-iommu":
            warnings.append("removed -device amd-iommu: AMD vIOMMU registered no VFIO notifier (PR #2/#3)")
            continue
        if drv == "intel-iommu":
            old = split_props(o.value or "")
            for k, v in old[1:]:
                prop_set(props, k, v)
            first_idx = len(kept) if first_idx is None else first_idx
            continue
        kept.append(o)
    prop_set(props, "intremap", "on")
    prop_set(props, "caching-mode", "on")
    for extra in cfg.iommu_extra:
        if "=" not in extra:
            raise GenError(f"--iommu-opt wants key=value, got {extra!r}")
        k, v = extra.split("=", 1)
        prop_set(props, k, v)
    if prop_get(props, "pt") is not None:
        warnings.append("intel-iommu has a 'pt' property only in QEMU <= 10.x; QEMU 11 rejects it (PR #4/#6)")
    iommu = Opt("-device", join_props(props))
    if cfg.iommu_position == "keep" and first_idx is not None:
        kept.insert(first_idx, iommu)
    else:
        pos = next((i for i, o in enumerate(kept) if o.flag == "-device"), len(kept))
        kept.insert(pos, iommu)
    opts[:] = kept


def _gpu_devices(opts: list[Opt], cfg: Config):
    """Return {slot: {function: (index, Opt)}} for vfio-pci devices to treat as the GPU."""
    wanted = {norm_slot(s) for s in cfg.gpu}
    slots: dict[str, dict[int, tuple[int, Opt]]] = {}
    for idx, o in enumerate(opts):
        if driver_of(o) != "vfio-pci":
            continue
        props = split_props(o.value or "")
        host = prop_get(props, "host")
        if not host:
            raise GenError("vfio-pci device without host=<BDF> (sysfsdev/mdev not supported by this tool)")
        bdf = norm_bdf(host)
        slot, fn = bdf.rsplit(".", 1)
        if wanted and slot not in wanted:
            continue
        slots.setdefault(slot, {})[int(fn)] = (idx, o)
    if wanted and wanted - set(slots):
        raise GenError(f"--gpu slot(s) not found among vfio-pci devices: {sorted(wanted - set(slots))}")
    if not slots:
        raise GenError("no vfio-pci device in the input: GPU passthrough is a required part of this setup "
                       "(add `hostpci0: <slot>,pcie=1` to the VM first)")
    return slots


def _gpu(opts: list[Opt], cfg: Config, warnings: list[str]) -> None:
    slots = _gpu_devices(opts, cfg)
    for slot, fns in slots.items():
        if 0 not in fns:
            raise GenError(f"GPU slot {slot}: function 0 missing (got {sorted(fns)})")
        if len(fns) < 2 and not cfg.allow_single_function:
            raise GenError(
                f"GPU slot {slot}: only function(s) {sorted(fns)} passed through. Both GPU functions "
                "(video .0 and audio .1) must go to the VM; pass `hostpciN: <slot>` without a function, "
                "or use --allow-single-function")
    # Idempotence: a slot whose function 0 already sits on a declared pcie-pci-bridge is left alone.
    bridge_ids = {prop_get(split_props(o.value or ""), "id") for o in opts if driver_of(o) == "pcie-pci-bridge"}
    if cfg.topology == "bridge":
        slots = {
            slot: fns for slot, fns in slots.items()
            if prop_get(split_props(fns[0][1].value or ""), "bus") not in bridge_ids
        }
        if not slots:
            return
    first_idx = min(i for fns in slots.values() for i, _ in fns.values())
    drop = {i for fns in slots.values() for i, _ in fns.values()}
    new: list[Opt] = []
    used_parents: set[str] = set()
    for n, (slot, fns) in enumerate(sorted(slots.items())):
        fn0_props = split_props(fns[0][1].value or "")
        orig_bus = prop_get(fn0_props, "bus")
        need_rp = (
            cfg.own_root_port or cfg.pref64_reserve is not None or cfg.topology == "root-port"
            or not orig_bus or orig_bus in ROOT_BUSES or orig_bus in used_parents
        )
        if need_rp:
            parent = f"gpurp{n}"
            rp = mkdev("pcie-root-port", id=parent, bus="pcie.0", chassis=40 + n, slot=40 + n)
            if cfg.pref64_reserve:
                rp.value += f",pref64-reserve={cfg.pref64_reserve}"
            new.append(rp)
        else:
            parent = orig_bus
        used_parents.add(parent)
        if cfg.topology == "bridge":
            bus = f"gpubr{n}"
            new.append(mkdev("pcie-pci-bridge", id=bus, bus=parent, addr="0x0"))
            addr_base = "0x1"
        else:
            bus = parent
            addr_base = "0x0"
            warnings.append(
                "topology=root-port puts both GPU functions on one root port; with intel-iommu that fails with "
                "'group N used in multiple address spaces' when they share a host IOMMU group (PR #4). Untested.")
        for fn in sorted(fns):
            props = split_props(fns[fn][1].value or "")
            prop_del(props, "bus", "addr", "multifunction")
            props += [("bus", bus), ("addr", f"{addr_base}.{fn}")]
            if fn == 0 and len(fns) > 1:
                props.append(("multifunction", "on"))
            new.append(Opt("-device", join_props(props)))
    out: list[Opt] = []
    for i, o in enumerate(opts):
        if i == first_idx:
            out.extend(new)
        if i not in drop:
            out.append(o)
    opts[:] = out


def _mmio(opts: list[Opt], cfg: Config, warnings: list[str]) -> None:
    for o in opts:
        if o.flag == "-fw_cfg" and o.value and prop_get(split_props(o.value), "name") == FWCFG_MMIO64:
            return  # user already set it; check() validates the size
    if cfg.mmio64_mb <= 0:
        warnings.append("64-bit MMIO aperture NOT configured (--mmio64-mb 0): large-BAR GPUs may fail to map")
        return
    opts.append(Opt("-fw_cfg", f"name={FWCFG_MMIO64},string={cfg.mmio64_mb}"))
    cpu = next((o.value for o in opts if o.flag == "-cpu" and o.value), "")
    if not cpu.startswith("host"):
        warnings.append(f"-cpu is {cpu!r}, not 'host': a {cfg.mmio64_mb} MiB 64-bit aperture needs enough guest physical-address bits")


def _no_virtio(opts: list[Opt], warnings: list[str]) -> None:
    """Replace virtio-scsi / virtio-net by AHCI / e1000e (what PR #6 used with the patched QEMU)."""
    ctrl: dict[str, str] = {}
    out: list[Opt] = []
    n_ahci = 0
    for o in opts:
        drv = driver_of(o)
        if o.flag == "-object" and o.value and o.value.startswith("iothread,id=iothread-virtioscsi"):
            continue
        if drv == "virtio-scsi-pci":
            p = split_props(o.value or "")
            cid = prop_get(p, "id") or ""
            new_id = f"ahci{n_ahci}"
            n_ahci += 1
            ctrl[cid] = new_id
            out.append(mkdev("ahci", id=new_id, **{k: v for k, v in p[1:] if k in ("bus", "addr")}))
            continue
        out.append(o)
    final: list[Opt] = []
    for o in out:
        drv = driver_of(o)
        p = split_props(o.value or "") if drv else []
        if drv in ("scsi-hd", "scsi-cd"):
            bus = prop_get(p, "bus") or ""
            cid, _, _ = bus.partition(".")
            if cid not in ctrl:
                warnings.append(f"{drv} on unknown controller {bus!r} left unchanged")
                final.append(o)
                continue
            port = int(prop_get(p, "scsi-id", "0"))
            if port > 5:
                raise GenError(f"scsi-id {port} does not fit AHCI's 6 ports")
            keep = {k: v for k, v in p[1:] if k in ("drive", "id", "bootindex", "serial", "model")}
            final.append(mkdev("ide-hd" if drv == "scsi-hd" else "ide-cd", bus=f"{ctrl[cid]}.{port}", **keep))
        elif drv == "virtio-net-pci":
            keep = {k: v for k, v in p[1:] if k in ("mac", "netdev", "bus", "addr", "id", "bootindex")}
            final.append(mkdev("e1000e", **keep))
        elif o.flag == "-netdev" and o.value:
            np = split_props(o.value)
            prop_del(np, "vhost", "queues")
            final.append(Opt(o.flag, join_props(np)))
        else:
            if drv in ("virtio-blk-pci", "virtio-balloon-pci", "virtio-rng-pci"):
                warnings.append(f"{drv} left unchanged (not converted)")
            final.append(o)
    opts[:] = final


def transform(binary: str, opts: list[Opt], cfg: Config) -> tuple[list[Opt], list[str]]:
    opts = [Opt(o.flag, o.value) for o in opts]
    warnings: list[str] = []
    if cfg.qemu_bin and not cfg.keep_id:
        opts = [o for o in opts if o.flag != "-id"]
    _machine(opts, cfg, warnings)
    _iommu(opts, cfg, warnings)
    _gpu(opts, cfg, warnings)
    _mmio(opts, cfg, warnings)
    if cfg.no_virtio:
        _no_virtio(opts, warnings)
    for extra in cfg.extra_args:
        toks = shlex.split(extra)
        if not toks or not toks[0].startswith("-"):
            raise GenError(f"--extra-arg must start with a QEMU flag, got {extra!r}")
        opts.append(Opt(toks[0], toks[1] if len(toks) > 1 else None))
        if len(toks) > 2:
            raise GenError(f"--extra-arg takes one flag with at most one value: {extra!r}")
    return opts, warnings


# --------------------------------------------------------------------------
# acceptance check (GPU passthrough + vIOMMU are required)
# --------------------------------------------------------------------------
def check(opts: list[Opt], cfg: Config | None = None) -> list[str]:
    """Return a list of violations of the setup's hard requirements (empty = OK)."""
    cfg = cfg or Config()
    bad: list[str] = []
    machine_props = [p for o in opts if o.flag in ("-machine", "-M") and o.value for p in split_props(o.value)]
    if prop_get(machine_props, "kernel-irqchip") != "split":
        bad.append("-machine must carry kernel-irqchip=split (interrupt remapping needs it)")
    mtype = prop_get(machine_props, "type") or next((k for k, v in machine_props if v is None), "")
    if not mtype.startswith(("q35", "pc-q35")):
        bad.append(f"machine type {mtype!r} is not q35")
    devs = [(i, o) for i, o in enumerate(opts) if o.flag == "-device"]
    if any(driver_of(o) == "amd-iommu" for _, o in devs):
        bad.append("amd-iommu present: AMD vIOMMU does not register VFIO notifiers")
    iommus = [(i, o) for i, o in devs if driver_of(o) == "intel-iommu"]
    if len(iommus) != 1:
        bad.append(f"expected exactly one intel-iommu device, found {len(iommus)}")
    else:
        ip = split_props(iommus[0][1].value or "")
        if prop_get(ip, "intremap") != "on":
            bad.append("intel-iommu needs intremap=on")
        if prop_get(ip, "caching-mode") != "on":
            bad.append("intel-iommu needs caching-mode=on (required for assigned devices)")
        if cfg.iommu_position == "first" and devs and devs[0][1] is not iommus[0][1]:
            bad.append("intel-iommu should be the first -device (QEMU VT-d wiki)")
    ids_bridge = {prop_get(split_props(o.value or ""), "id") for _, o in devs if driver_of(o) == "pcie-pci-bridge"}
    slots: dict[str, set[int]] = {}
    buses: dict[str, set[str | None]] = {}
    for _, o in devs:
        if driver_of(o) != "vfio-pci":
            continue
        p = split_props(o.value or "")
        host = prop_get(p, "host")
        if not host:
            continue
        slot, fn = norm_bdf(host).rsplit(".", 1)
        slots.setdefault(slot, set()).add(int(fn))
        buses.setdefault(slot, set()).add(prop_get(p, "bus"))
    if not slots:
        bad.append("no vfio-pci GPU device: passthrough is required")
    for slot, fns in slots.items():
        if len(fns) < 2 and not cfg.allow_single_function:
            bad.append(f"GPU {slot}: both functions must be passed through (got {sorted(fns)})")
        if len(buses[slot]) != 1:
            bad.append(f"GPU {slot}: functions are on different buses {buses[slot]}")
        elif cfg.topology == "bridge" and next(iter(buses[slot])) not in ids_bridge:
            bad.append(f"GPU {slot}: functions are not behind a pcie-pci-bridge (qm-native topology fails with the vIOMMU)")
    mmio = [prop_get(split_props(o.value or ""), "string") for o in opts
            if o.flag == "-fw_cfg" and prop_get(split_props(o.value or ""), "name") == FWCFG_MMIO64]
    if not mmio:
        if not cfg.allow_small_mmio:
            bad.append(f"-fw_cfg {FWCFG_MMIO64} missing: large-BAR GPU needs a big 64-bit MMIO aperture")
    elif not mmio[0] or not mmio[0].isdigit() or int(mmio[0]) < MIN_MMIO64_MB:
        if not cfg.allow_small_mmio:
            bad.append(f"-fw_cfg {FWCFG_MMIO64} is {mmio[0]!r} MiB; need >= {MIN_MMIO64_MB}")
    return bad


# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------
def render(binary: str, opts: list[Opt], cfg: Config, warnings: list[str], source_note: str) -> str:
    qbin = cfg.qemu_bin or binary
    lines = [
        "#!/usr/bin/env bash",
        f"# Generated by tools/gen-launch.py from {source_note}. Do not edit by hand; regenerate.",
        "#",
        "# Applied (see docs/roadmap.md): Intel vIOMMU (kernel-irqchip=split, intel-iommu intremap+caching-mode),",
        "# both GPU functions behind pcie-root-port -> pcie-pci-bridge, large 64-bit MMIO aperture.",
        "# Host impact: none by itself. Running this starts one QEMU process like `qm start` would, with the",
        "# VM's existing disks/NICs; the VM config under /etc/pve is not modified. Do not run it while `qm`",
        "# has the VM running. Remove this file to remove everything.",
    ]
    for w in warnings:
        lines.append(f"# NOTE: {w}")
    lines += [
        "set -euo pipefail",
        f"QEMU_BIN=${{QEMU_BIN:-{shlex.quote(qbin)}}}",
    ]
    args: list[str] = []
    if cfg.qemu_share:
        args.append(f"-L {shlex.quote(cfg.qemu_share)}")
    for o in opts:
        args.append(o.flag if o.value is None else f"{o.flag} {shlex.quote(o.value)}")
    lines.append(f"exec -a {shlex.quote(cfg.argv0)} \"$QEMU_BIN\" \\")
    for i, a in enumerate(args):
        lines.append("  " + a + (" \\" if i < len(args) - 1 else ""))
    return "\n".join(lines) + "\n"


def generate(text: str, cfg: Config, source_note: str = "`qm showcmd`") -> tuple[str, list[str]]:
    binary, opts = parse_cmdline(tokenize(text))
    new_opts, warnings = transform(binary, opts, cfg)
    problems = check(new_opts, cfg)
    if problems:
        raise GenError("result violates requirements:\n  - " + "\n  - ".join(problems))
    return render(binary, new_opts, cfg, warnings, source_note), warnings


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("input", nargs="?", default="-", help="file with `qm showcmd` output, or - for stdin")
    ap.add_argument("-o", "--output", help="write the script here (mode 0755); default stdout")
    ap.add_argument("--qemu-bin", help="alternate QEMU binary (e.g. /opt/qemu-ad/bin/qemu-system-x86_64); "
                    "also drops '-id N' and the '+pveN' machine suffix, which only PVE's QEMU understands")
    ap.add_argument("--qemu-share", help="firmware/ROM dir passed as -L (e.g. /opt/qemu-11.0.3/usr/share/kvm)")
    ap.add_argument("--argv0", default="/usr/bin/kvm", help="argv[0] for exec -a (default /usr/bin/kvm, as in the PR runs)")
    ap.add_argument("--keep-id", action="store_true", help="keep '-id N' even with --qemu-bin")
    ap.add_argument("--gpu", action="append", default=[], metavar="SLOT",
                    help="PCI slot (no function), e.g. 0000:02:00; repeatable. Default: every vfio-pci device")
    ap.add_argument("--allow-single-function", action="store_true", help="accept a GPU without its audio function")
    ap.add_argument("--topology", choices=("bridge", "root-port"), default="bridge",
                    help="bridge (default, tested): root port -> pcie-pci-bridge; root-port: untested")
    ap.add_argument("--own-root-port", action="store_true", help="create a dedicated pcie-root-port instead of reusing qm's")
    ap.add_argument("--pref64-reserve", metavar="SIZE", help="pcie-root-port pref64-reserve (implies --own-root-port)")
    ap.add_argument("--mmio64-mb", type=int, default=DEFAULT_MMIO64_MB,
                    help=f"OVMF 64-bit MMIO aperture in MiB (default {DEFAULT_MMIO64_MB}; 0 = off, discouraged)")
    ap.add_argument("--allow-small-mmio", action="store_true", help="do not fail when the aperture is small/missing")
    ap.add_argument("--iommu-opt", action="append", default=[], metavar="K=V",
                    help="extra intel-iommu property, e.g. device-iotlb=on or aw-bits=48; repeatable")
    ap.add_argument("--iommu-position", choices=("first", "keep"), default="first",
                    help="first (default): before every other -device, as the QEMU VT-d wiki asks; keep: where qm put it")
    ap.add_argument("--no-virtio", action="store_true",
                    help="convert virtio-scsi/virtio-net to AHCI/e1000e (needed by the patched qemu-ad-pve, PR #6)")
    ap.add_argument("--extra-arg", action="append", default=[], metavar="'-flag value'", help="append one QEMU option")
    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    cfg = Config(
        qemu_bin=args.qemu_bin, qemu_share=args.qemu_share, argv0=args.argv0, gpu=args.gpu,
        topology=args.topology, own_root_port=args.own_root_port, pref64_reserve=args.pref64_reserve,
        mmio64_mb=args.mmio64_mb, iommu_extra=args.iommu_opt, iommu_position=args.iommu_position,
        allow_single_function=args.allow_single_function, allow_small_mmio=args.allow_small_mmio,
        no_virtio=args.no_virtio, keep_id=args.keep_id, extra_args=args.extra_arg,
    )
    try:
        text = sys.stdin.read() if args.input == "-" else open(args.input, encoding="utf-8").read()
        note = "`qm showcmd` on stdin" if args.input == "-" else f"{os.path.basename(args.input)}"
        script, warnings = generate(text, cfg, note)
    except (GenError, OSError) as exc:
        print(f"gen-launch: error: {exc}", file=sys.stderr)
        return 1
    for w in warnings:
        print(f"gen-launch: note: {w}", file=sys.stderr)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(script)
        os.chmod(args.output, os.stat(args.output).st_mode | stat.S_IXUSR)
    else:
        sys.stdout.write(script)
    return 0


if __name__ == "__main__":
    sys.exit(main())
