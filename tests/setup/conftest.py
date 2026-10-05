"""Shared fixtures: a fake host root (sysfs/procfs//etc/pve) and stub PVE commands on PATH."""
import os
import stat
import sys
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
FIX = Path(__file__).resolve().parent / "fixtures"
sys.path.insert(0, str(REPO / "setup"))

# bdf -> (vendor, device, class, driver, group)
HOST_PCI = {
    "0000:00:00.0": ("0x1022", "0x14d8", "0x060000", "", "0"),
    "0000:00:01.1": ("0x1022", "0x14db", "0x060400", "pcieport", "1"),
    "0000:01:00.0": ("0x10de", "0x2704", "0x030000", "vfio-pci", "14"),
    "0000:01:00.1": ("0x10de", "0x22bb", "0x040300", "snd_hda_intel", "14"),
    "0000:02:00.0": ("0x144d", "0xa80a", "0x010802", "nvme", "15"),
    "0000:0e:00.0": ("0x1002", "0x164e", "0x030000", "amdgpu", "20"),
    "0000:0e:00.1": ("0x1002", "0x1640", "0x040300", "snd_hda_intel", "20"),
    "0000:0e:00.2": ("0x1022", "0x1649", "0x108000", "ccp", "20"),
}


def fix(name: str) -> str:
    return (FIX / name).read_text()


def make_sysroot(root: Path, pci=None, nested="1", confs=("vm-100.conf", "vm-101.conf", "vm-9200.conf")) -> Path:
    pci = HOST_PCI if pci is None else pci
    (root / "proc").mkdir(parents=True)
    (root / "proc/cpuinfo").write_text(fix("cpuinfo.txt"))
    (root / "proc/meminfo").write_text(fix("meminfo.txt"))
    (root / "proc/cmdline").write_text("BOOT_IMAGE=/vmlinuz root=/dev/mapper/pve-root amd_iommu=on\n")
    p = root / "sys/module/kvm_amd/parameters"
    p.mkdir(parents=True)
    (p / "nested").write_text(nested + "\n")
    devs = root / "sys/bus/pci/devices"
    devs.mkdir(parents=True)
    for drv in {v[3] for v in pci.values() if v[3]}:
        (root / "sys/bus/pci/drivers" / drv).mkdir(parents=True, exist_ok=True)
    for bdf, (ven, dev, cls, drv, grp) in pci.items():
        d = devs / bdf
        d.mkdir()
        (d / "vendor").write_text(ven + "\n")
        (d / "device").write_text(dev + "\n")
        (d / "class").write_text(cls + "\n")
        g = root / "sys/kernel/iommu_groups" / grp / "devices"
        g.mkdir(parents=True, exist_ok=True)
        os.symlink(g.parent, d / "iommu_group")
        if drv:
            os.symlink(root / "sys/bus/pci/drivers" / drv, d / "driver")
    br = root / "sys/class/net/vmbr0/bridge"
    br.mkdir(parents=True)
    (root / "sys/class/net/eno1").mkdir(parents=True)
    qs = root / "etc/pve/qemu-server"
    qs.mkdir(parents=True)
    for c in confs:
        (qs / c.replace("vm-", "")).write_text(fix(c))
    (root / "etc/pve/mapping").mkdir(parents=True)
    (root / "etc/pve/mapping/pci.cfg").write_text(fix("pci-mapping.cfg"))
    (root / "var/lib").mkdir(parents=True)
    return root


STUB = r"""#!/bin/sh
# test stub for PVE commands; prints fixtures
F="{fix}"
cmd=$(basename "$0")
case "$cmd $*" in
  "pveversion"*) cat "$F/pveversion.txt" ;;
  "hostname"*) echo pve ;;
  "lspci"*) cat "$F/lspci-Dnn.txt" ;;
  "qm list"*) cat "$F/qm-list.txt" ;;
  "qm status"*) echo "status: stopped" ;;
  "qm config"*) exit 2 ;;
  "pvesh get /cluster/nextid"*) echo 9201 ;;
  "pvesm status --content images"*) cat "$F/pvesm-images.txt" ;;
  "pvesm status --content iso"*) cat "$F/pvesm-iso.txt" ;;
  "pvesm status --content snippets"*) cat "$F/pvesm-snippets.txt" ;;
  "pvesm list"*) printf 'Volid Format Type Size VMID\nlocal:iso/Win10_22H2_English_x64.iso iso iso 6000000000\n' ;;
  "pvesm path local:iso/"*) echo "{iso_dir}/$(echo "$2" | sed 's#local:iso/##')" ;;
  "pvesm path local:snippets/"*) echo "/var/lib/vz/snippets/$(echo "$2" | sed 's#local:snippets/##')" ;;
  "blkid"*) echo CCCOMA_X64FRE_EN-US_DV9 ;;
  *) echo "stub: unexpected $cmd $*" >&2; exit 99 ;;
esac
"""


def make_stubs(bindir: Path, iso_dir: Path) -> Path:
    bindir.mkdir(parents=True, exist_ok=True)
    body = STUB.replace("{fix}", str(FIX)).replace("{iso_dir}", str(iso_dir))
    for name in ("pveversion", "hostname", "lspci", "qm", "pvesh", "pvesm", "blkid"):
        f = bindir / name
        f.write_text(body)
        f.chmod(f.stat().st_mode | stat.S_IEXEC)
    for name in ("ssh", "scp", "ssh-keygen", "genisoimage", "qemu-img", "sha512sum", "tar", "wget"):
        f = bindir / name
        if not f.exists():
            f.write_text("#!/bin/sh\necho stub-should-not-run >&2\nexit 98\n")
            f.chmod(0o755)
    return bindir


@pytest.fixture
def sysroot(tmp_path):
    return make_sysroot(tmp_path / "root")


@pytest.fixture
def stub_env(tmp_path, monkeypatch):
    iso_dir = tmp_path / "iso"
    iso_dir.mkdir()
    (iso_dir / "Win10_22H2_English_x64.iso").write_bytes(b"\0" * 4096)
    bindir = make_stubs(tmp_path / "bin", iso_dir)
    monkeypatch.setenv("PATH", f"{bindir}:{os.environ['PATH']}")
    monkeypatch.setenv("NO_COLOR", "1")
    return {"bin": bindir, "iso_dir": iso_dir, "root": make_sysroot(tmp_path / "root"),
            "state": tmp_path / "state"}
