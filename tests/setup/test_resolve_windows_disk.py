"""resolve-windows-disk.sh against a fake block-device table (stub lsblk/udevadm/blockdev/wipefs/findmnt)."""
import json
import os
import shutil
import subprocess

import pytest

from conftest import REPO

SCRIPT = REPO / "scripts/l1-w10/resolve-windows-disk.sh"
G = 1024 ** 3

STUB = r'''#!/usr/bin/env python3
import json, os, sys
disks = json.load(open(os.environ["FAKE_DISKS"]))
tool = os.path.basename(sys.argv[0]); a = sys.argv[1:]
def rows(d):
    info = disks[d]
    yield {"NAME": d.rsplit("/", 1)[1], "TYPE": "disk", "PTTYPE": info.get("pttype", ""), "FSTYPE": info.get("fstype", ""),
           "LABEL": "", "UUID": "", "MOUNTPOINT": "", "PKNAME": ""}
    for p in info.get("parts", []):
        yield {"NAME": p["name"], "TYPE": "part", "PTTYPE": "", "FSTYPE": p.get("fstype", ""), "LABEL": p.get("label", ""),
               "UUID": p.get("uuid", ""), "MOUNTPOINT": p.get("mount", ""), "PKNAME": d.rsplit("/", 1)[1]}
def find_part(dev):
    for d, info in disks.items():
        for p in info.get("parts", []):
            if "/dev/" + p["name"] == dev:
                return d, p
    return None, None
if tool == "lsblk":
    flags = [x for x in a if x.startswith("-")]; rest = [x for x in a if not x.startswith("-")]
    cols = rest[0].split(","); dev = rest[1] if len(rest) > 1 else None
    nodeps = any("d" in f for f in flags)
    if dev is None:
        for d in disks:
            print(d, "disk")
        sys.exit(0)
    if dev not in disks:
        d, p = find_part(dev)
        if p is None:
            sys.exit(32)
        print(d.rsplit("/", 1)[1] if cols == ["PKNAME"] else ""); sys.exit(0)
    for i, r in enumerate(rows(dev)):
        if nodeps and i > 0:
            break
        print(" ".join(r[c] for c in cols).rstrip())
elif tool == "udevadm":
    dev = [x.split("=", 1)[1] for x in a if x.startswith("--name=")][0]
    print("ID_SERIAL_SHORT=" + disks[dev].get("serial", ""))
elif tool == "blockdev":
    print(disks[a[-1]]["size"])
elif tool == "wipefs":
    sigs = disks[a[-1]].get("signatures", [])
    if sigs:
        print("DEVICE OFFSET TYPE UUID LABEL")
        for s in sigs:
            print(a[-1], "0x0", s)
elif tool == "findmnt":
    print(os.environ.get("FAKE_ROOT_SRC", "/dev/sda1"))
'''

L1_ROOT = {"serial": "drive-scsi0", "size": 48 * G, "pttype": "gpt",
           "parts": [{"name": "sda1", "fstype": "ext4", "mount": "/"}, {"name": "sda15", "fstype": "vfat",
                                                                       "mount": "/boot/efi"}]}


@pytest.fixture
def env(tmp_path):
    if shutil.which("bash") is None:
        pytest.skip("bash missing")
    b = tmp_path / "bin"
    b.mkdir()
    for t in ("lsblk", "udevadm", "blockdev", "wipefs", "findmnt"):
        (b / t).write_text(STUB)
        (b / t).chmod(0o755)
    e = dict(os.environ, PATH=f"{b}:{os.environ['PATH']}", FAKE_DISKS=str(tmp_path / "disks.json"))
    return tmp_path, e


def resolve(env, disks, **extra):
    tmp, e = env
    (tmp / "disks.json").write_text(json.dumps(disks))
    e = dict(e, **{k: str(v) for k, v in extra.items()})
    return subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, env=e, timeout=30)


def test_blank_install_disk_only_with_flag_and_exact_serial(env):
    disks = {"/dev/sda": L1_ROOT, "/dev/sdb": {"serial": "drive-scsi1", "size": 128 * G}}
    p = resolve(env, disks, WIN_DISK_ALLOW_BLANK=1)
    assert p.returncode == 0, p.stderr
    assert p.stdout.strip() == "/dev/sdb" and "blank(install)" in p.stderr
    p = resolve(env, disks)  # without the flag a blank disk is never "Windows"
    assert p.returncode == 93
    disks["/dev/sdb"]["serial"] = "drive-scsi2"
    assert resolve(env, disks, WIN_DISK_ALLOW_BLANK=1).returncode == 90


def test_blank_flag_does_not_bypass_refusals(env):
    mounted = {"serial": "drive-scsi1", "size": 128 * G, "pttype": "gpt",
               "parts": [{"name": "sdb1", "fstype": "xfs", "mount": "/data"}]}
    p = resolve(env, {"/dev/sda": L1_ROOT, "/dev/sdb": mounted}, WIN_DISK_ALLOW_BLANK=1)
    assert p.returncode == 90 and "REFUSE /dev/sdb: has mounted" in p.stderr
    ext4 = {"serial": "drive-scsi1", "size": 128 * G, "pttype": "gpt", "parts": [{"name": "sdb1", "fstype": "ext4"}]}
    p = resolve(env, {"/dev/sda": L1_ROOT, "/dev/sdb": ext4}, WIN_DISK_ALLOW_BLANK=1)
    assert p.returncode == 90 and "ext4" in p.stderr
    # a disk with a leftover signature (e.g. LVM) is not blank -> no NTFS -> refused at the final check
    sig = {"serial": "drive-scsi1", "size": 128 * G, "signatures": ["LVM2_member"]}
    assert resolve(env, {"/dev/sda": L1_ROOT, "/dev/sdb": sig}, WIN_DISK_ALLOW_BLANK=1).returncode == 93


def test_installed_windows_disk_and_size_window(env):
    win = {"serial": "drive-scsi1", "size": 128 * G, "pttype": "gpt",
           "parts": [{"name": "sdb1", "fstype": "vfat"}, {"name": "sdb3", "fstype": "ntfs", "label": "Windows",
                                                        "uuid": "ABCD"}]}
    p = resolve(env, {"/dev/sda": L1_ROOT, "/dev/sdb": win}, WIN_DISK_MAX_GB=200)
    assert p.returncode == 0 and p.stdout.strip() == "/dev/sdb", p.stderr
