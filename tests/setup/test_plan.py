import base64
import shlex

from conftest import REPO, make_sysroot
from qad_setup import hostinfo as hi
from qad_setup import plan
from qad_setup.config import Config


def gpu(tmp_path):
    return hi.find_gpus(hi.read_sysfs_pci(str(make_sysroot(tmp_path))))[0]


def test_l1_args_topology_matches_pr24(tmp_path):
    a = plan.l1_args(gpu(tmp_path), 65536)
    # identical shape to samples/qm-native-9200/9200.conf.active-final (only the host BDFs differ)
    assert a == ("-device pcie-pci-bridge,id=gpubr,bus=ich9-pcie-port-1,addr=0x0 "
                 "-device vfio-pci,host=0000:01:00.0,id=gpu-vga,bus=gpubr,addr=0x1.0,multifunction=on "
                 "-device vfio-pci,host=0000:01:00.1,id=gpu-audio,bus=gpubr,addr=0x1.1 "
                 "-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536")
    sample = (REPO / "samples/qm-native-9200/9200.conf.active-final").read_text()
    lab = next(l for l in sample.splitlines() if l.startswith("args: "))[6:]
    assert a.replace("0000:01:00", "0000:02:00") == lab
    assert "intel-iommu" not in a and "hostpci" not in a


def test_qm_create_iso(tmp_path):
    c = Config({"l1.storage": "local-lvm", "l2.windows_iso": "local:iso/w.iso", "l1.disk_gb": "64"})
    cmds = plan.qm_create(c, "9201", "abc", gpu(tmp_path), "/img.qcow2", "local:iso/seed.iso", "local:snippets/h.sh")
    create = cmds[0]
    opts = dict(zip(create[3::2], create[4::2]))
    assert create[:3] == ["qm", "create", "9201"]
    assert opts["--machine"] == "q35,viommu=intel"
    assert opts["--efidisk0"] == "local-lvm:1,efitype=4m,pre-enrolled-keys=0"
    assert opts["--scsi0"].startswith("local-lvm:0,import-from=/img.qcow2")
    assert opts["--hookscript"] == "local:snippets/h.sh"
    assert opts["--balloon"] == "0" and opts["--scsihw"] == "virtio-scsi-single"
    assert opts["--description"].startswith("qemu-ad-pve-setup:abc")
    assert cmds[1] == ["qm", "disk", "resize", "9201", "scsi0", "64G"]
    assert cmds[2] == ["qm", "set", "9201", "--scsi1", "local-lvm:128,discard=on,ssd=1"]
    assert cmds[3] == ["qm", "set", "9201", "--ide0", "local:iso/w.iso,media=cdrom"]


def test_qm_create_image_and_none(tmp_path):
    g = gpu(tmp_path)
    c = Config({"l1.storage": "st", "l2.source": "image", "l2.image": "/w.qcow2"})
    cmds = plan.qm_create(c, "9300", "x", g, "/i", "local:iso/s.iso", None)
    assert "--hookscript" not in cmds[0]
    assert cmds[2] == ["qm", "set", "9300", "--scsi1", "st:0,import-from=/w.qcow2,discard=on,ssd=1"]
    c = Config({"l1.storage": "st", "l2.source": "none"})
    assert len(plan.qm_create(c, "9300", "x", g, "/i", "s", None)) == 2


def test_cloud_init():
    ud = plan.user_data("ssh-ed25519 AAAA test", "qad-l1")
    assert ud.startswith("#cloud-config\n") and "ssh-ed25519 AAAA test" in ud and "qemu-guest-agent" in ud
    assert "ssh_pwauth: false" in ud
    assert plan.network_config(Config()) is None
    nc = plan.network_config(Config({"l1.ip": "192.168.1.50/24", "l1.gateway": "192.168.1.1"}))
    assert "addresses: [192.168.1.50/24]" in nc and "via: 192.168.1.1" in nc and "addresses: [192.168.1.1]" in nc


def test_l1_env_is_shell_safe(tmp_path):
    c = Config({"l2.windows_iso": "local:iso/w.iso", "l2.timezone": "W. Europe Standard Time"})
    env = plan.l1_env(c, "abc", "9201", gpu(tmp_path), "amd", "CCCOMA X64", ["nvidia_driver"])
    vals = {}
    for line in env.splitlines():
        if line and not line.startswith("#"):
            k, v = line.split("=", 1)
            vals[k] = shlex.split(v)[0] if shlex.split(v) else ""
    assert vals["QAD_GPU_IDS"] == "10de:2704 10de:22bb"
    assert vals["QAD_TIMEZONE"] == "W. Europe Standard Time"
    assert vals["QAD_WIN_ISO_LABEL"] == "CCCOMA X64"
    assert vals["QAD_L2_IP"] == "10.254.77.10"
    assert vals["QAD_L2_DISK_GB"] == "128"
    assert vals["QAD_L2_MEM"] == "6144" and vals["QAD_L2_SMP"] == "4"
    assert "PASSWORD" not in env


def test_secrets_env_and_mac():
    assert plan.secrets_env("a'b", "aaaaa-bbbbb-ccccc-ddddd-eeeee") == (
        "QAD_ADMIN_PASSWORD='a'\"'\"'b'\nQAD_PRODUCT_KEY=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\n")
    assert plan.l2_mac("9201") == plan.l2_mac("9201") and plan.l2_mac("9201").startswith("52:54:00:")


def test_pr24_guard_rendering(tmp_path):
    tmpl = (REPO / plan.GUARD_TEMPLATE).read_text()
    out = plan.hookscript(tmpl, "9301", gpu(tmp_path))
    assert out.startswith("#!/usr/bin/perl\n# Rendered by setup.sh from scripts/qm-native-9200/9200-gpu-guard.pl")
    assert "my @ids = ('0000:01:00.0', '0000:01:00.1');" in out
    assert "if ($vmid // '') ne '9301';" in out
    assert "0000:02:00" not in out.split("use PVE::QemuServer::PCI;", 1)[1]
    # the guard logic itself is untouched
    for needle in ("reserve_pci_usage(\\@ids, $vmid, 90)", "remove_pci_reservation($vmid, \\@ids)",
                   "if $drv !~ m{/vfio-pci$};", "vm_running_locally($vmid)"):
        assert needle in out, needle
    body = lambda t: [l for l in t.splitlines() if not l.startswith("#")]  # noqa: E731
    changed = [(a, b) for a, b in zip(body(tmpl), body(out)) if a != b]
    assert len(body(tmpl)) == len(body(out)) and all(("9200" in a) or ("02:00" in a) for a, _ in changed)


def test_guard_rendering_fails_loudly_on_changed_template(tmp_path):
    import pytest
    with pytest.raises(plan.TemplateError):
        plan.hookscript("#!/usr/bin/perl\nmy @ids = ('x');\n", "9301", gpu(tmp_path))


def test_scp_argv_matches_ssh_hostkey_policy(tmp_path):
    """Custom autounattend scp must pin host keys the same way ssh does (QA: was missing StrictHostKeyChecking)."""
    from qad_setup import steps
    from qad_setup.config import Config
    from qad_setup.manifest import Manifest
    from qad_setup.state import State
    from qad_setup import ui

    class R:
        dry_run = False
        secrets = []

    gpu = hi.find_gpus(hi.read_sysfs_pci(str(make_sysroot(tmp_path))))[0]
    cfg = Config({"l1.vmid": "9201"})
    c = steps.Ctx(cfg=cfg, runner=R(), state=State(str(tmp_path / "s.json")),
                  manifest=Manifest(install_id="x", path=str(tmp_path / "m.json")),
                  prompter=ui.Prompter(True), repo=".", state_dir=str(tmp_path), gpu=gpu)
    c.state.facts["l1_ip"] = "10.0.0.2"
    # unpinned: accept-new
    scp = c.scp_argv("/tmp/au.xml", "root@10.0.0.2:/root/qad-stage/autounattend.xml")
    assert scp[:2] == ["scp", "-q"]
    assert "StrictHostKeyChecking=accept-new" in scp
    assert f"UserKnownHostsFile={c.known_hosts}" in " ".join(scp)
    # pinned: yes
    c.state.facts["hostkey_pinned"] = "yes"
    scp2 = c.scp_argv("/tmp/au.xml", "root@10.0.0.2:/x")
    assert "StrictHostKeyChecking=yes" in scp2
    assert c.ssh_argv("true")[c.ssh_argv("true").index("-o") + 1].startswith("BatchMode")
    ssh = c.ssh_argv("true")
    assert "StrictHostKeyChecking=yes" in ssh


def test_l2_identity_helpers():
    assert plan.l2_mac("9201", "a4:bf:01").startswith("a4:bf:01:")
    assert plan.l2_mac("9201", "") .startswith("52:54:00:")
    s1 = plan.l2_disk_serial("9201")
    assert s1 == plan.l2_disk_serial("9201") and s1.startswith("S5GXNX0T") and len(s1) == 15
    assert plan.l2_disk_serial("9201", "ABC123") == "ABC123"
    assert plan.l2_smbios("none", "9201") == ""
    lines = plan.l2_smbios("asus-am5", "9201").split("|")
    assert [x.split(",")[0] for x in lines] == ["type=0", "type=1", "type=2", "type=3", "type=4", "type=17"]
    assert "{" not in "".join(lines) and "QEMU" not in "".join(lines).upper()


def test_l2_chassis_desktop_default_and_opt_out(tmp_path):
    t3 = plan.l2_chassis_bin("9201")
    assert t3[0] == 3 and t3[1] == 0x15 and t3[5] == 3 and t3.endswith(b"\0\0")
    strs = t3[0x15:].split(b"\0")[:4]
    assert strs[0] == b"ASUSTeK COMPUTER INC." and strs[2].startswith(b"CS") and b"Default" not in b"".join(strs)
    assert plan.l2_chassis_bin("9201") == t3 and plan.l2_chassis_bin("9202") != t3
    lines = plan.l2_smbios("asus-am5", "9201", "/root/w10").split("|")
    assert lines[3] == "file=/root/w10/smbios-type3.bin" and len(lines) == 6
    assert plan.l2_smbios("asus-am5", "9201").split("|")[3].startswith("type=3,")
    for d in ("desktop", "none"):
        (tmp_path / d).mkdir()
    for chassis, want in (("desktop", True), ("none", False)):
        c = Config({"l2.windows_iso": "local:iso/w.iso", "l2.smbios_chassis": chassis})
        env = plan.l1_env(c, "abc", "9201", gpu(tmp_path / chassis), "amd", "CCCOMA X64", [])
        vals = {k: (shlex.split(v) or [""])[0] for k, v in (l.split("=", 1) for l in env.splitlines()
                                                           if l and not l.startswith("#"))}
        assert bool(vals["QAD_L2_CHASSIS_B64"]) is want
        assert ("file=/root/w10/smbios-type3.bin" in vals["QAD_L2_SMBIOS"]) is want
        if want:
            assert base64.b64decode(vals["QAD_L2_CHASSIS_B64"]) == t3


def test_l1_env_carries_l2_identity(tmp_path):
    c = Config({"l2.windows_iso": "local:iso/w.iso"})
    env = plan.l1_env(c, "abc", "9201", gpu(tmp_path), "amd", "CCCOMA X64", [])
    vals = {}
    for line in env.splitlines():
        if line and not line.startswith("#"):
            k, v = line.split("=", 1)
            vals[k] = shlex.split(v)[0] if shlex.split(v) else ""
    assert vals["QAD_L2_CPU"] == "host,-hypervisor,kvm=off"
    assert vals["QAD_L2_MAC"].startswith("a4:bf:01:")
    assert vals["QAD_L2_DISK_MODEL"] == "Samsung SSD 980 PRO 1TB" and vals["QAD_L2_DISK_SERIAL"]
    assert vals["QAD_L2_SMBIOS"].count("|") == 5 and vals["QAD_L2_VGA"] == "std"


def test_l1_smbios_structures_are_valid_and_not_a_vm():
    t0 = plan.smbios_type0_bin()
    assert t0[0] == 0 and t0[1] == 0x18
    assert t0[0x13] & 0x10 == 0  # BIOS characteristics extension byte 2 bit 4 = "virtual machine": clear
    strings = t0[0x18:].split(b"\0")
    assert strings[:3] == [b"American Megatrends Inc.", b"1654", b"01/12/2024"] and t0.endswith(b"\0\0")
    t3 = plan.smbios_type3_bin()
    assert t3[0] == 3 and t3[1] == 0x15 and t3[5] == 3  # chassis type 3 = Desktop
    assert t3[0x15:].count(b"\0") == 5 and t3.endswith(b"\0\0")
    assert set(plan.l1_smbios_files("9300")) == {"qad-l1-9300-smbios-type0.bin", "qad-l1-9300-smbios-type3.bin"}


def test_l1_smbios_args_and_smbios1():
    a = plan.l1_smbios_args("9300", "/var/lib/qemu-ad/setup/smbios")
    assert a[0] == "file=/var/lib/qemu-ad/setup/smbios/qad-l1-9300-smbios-type0.bin"
    assert a[2] == "file=/var/lib/qemu-ad/setup/smbios/qad-l1-9300-smbios-type3.bin"
    assert a[1].startswith("type=2,manufacturer=ASUSTeK COMPUTER INC.,product=ROG STRIX X670E-E GAMING WIFI")
    assert a[3].startswith("type=4,") and "AMD Ryzen 9 7950X" in a[3] and a[4].startswith("type=17,")
    assert not any(x.startswith("type=1,") for x in a)  # type 1 is qm --smbios1
    l2 = plan.l2_smbios("asus-am5", "9300")
    assert l2 != "|".join(a) and a == plan.l1_smbios_args("9300", "/var/lib/qemu-ad/setup/smbios")
    s1 = plan.l1_smbios1("9300", "abc")
    assert s1.endswith(",base64=1") and s1 == plan.l1_smbios1("9300", "abc") and s1 != plan.l1_smbios1("9301", "abc")
    assert "manufacturer=QVNVUw==" in s1


def test_qm_create_l1_identity_defaults(tmp_path):
    g = gpu(tmp_path)
    c = Config({"l1.storage": "st", "l2.source": "none"})
    cmds = plan.qm_create(c, "9300", "x", g, "/i", "s", None, "/var/lib/qemu-ad/setup/smbios")
    o = dict(zip(cmds[0][3::2], cmds[0][4::2]))
    assert o["--cpu"] == "host,hidden=1" and o["--smbios1"].startswith("uuid=")
    parts = shlex.split(o["--args"])
    assert "-cpu" in parts and parts[parts.index("-cpu") + 1] == "host,-hypervisor,kvm=off"
    assert parts.count("-smbios") == 5 and any(p.startswith("file=") for p in parts)
    assert "type=4,sock_pfx=AM5,manufacturer=Advanced Micro Devices,, Inc.,version=AMD Ryzen 9 7950X 16-Core Processor," \
        "max-speed=5700,current-speed=4500,serial=Unknown,asset=Unknown,part=Unknown" in parts


def test_qm_create_l1_identity_off_and_no_dir_keeps_old_shape(tmp_path):
    g = gpu(tmp_path)
    c = Config({"l1.storage": "st", "l2.source": "none", "l1.smbios": "none", "l1.hide_hypervisor": "no"})
    o = dict(zip(*[iter(plan.qm_create(c, "9300", "x", g, "/i", "s", None, "/d")[0][3:])] * 2))
    assert o["--cpu"] == "host" and "--smbios1" not in o and o["--args"] == plan.l1_args(g, 65536)
    c = Config({"l1.storage": "st", "l2.source": "none"})  # defaults but no smbios dir (old callers): no -smbios
    o = dict(zip(*[iter(plan.qm_create(c, "9300", "x", g, "/i", "s", None)[0][3:])] * 2))
    assert "-smbios" not in o["--args"]


def test_l1_env_optional_identity_defaults_on_and_opt_out(tmp_path):
    g = gpu(tmp_path)

    def vals(extra):
        c = Config(dict({"l2.windows_iso": "local:iso/w.iso"}, **extra))
        env = plan.l1_env(c, "abc", "9201", g, "amd", "CCCOMA X64", [])
        out = {}
        for line in env.splitlines():
            if line and not line.startswith("#"):
                k, v = line.split("=", 1)
                out[k] = shlex.split(v)[0] if shlex.split(v) else ""
        return out
    d = vals({})
    assert d["QAD_L2_OPTIONAL_PATCHES"] == "0001-acpi-omit-waet,0002-acpi-oem-id-table-id-revision"
    assert [d[k] for k in ("QAD_L2_OEM_ID", "QAD_L2_OEM_TABLE_ID", "QAD_L2_OEM_REVISION")] == ["ALASKA", "A M I", "0x1072009"]
    assert d["QAD_L2_OVMF_IDENTITY"] == "1" and d["QAD_L2_OVMF_BUILD"] == "1"
    n = vals({"l2.optional_patches": "none", "l2.ovmf_identity": "no"})
    assert n["QAD_L2_OPTIONAL_PATCHES"] == "" and n["QAD_L2_OVMF_IDENTITY"] == "0" and n["QAD_L2_OVMF_BUILD"] == "0"
    o = vals({"l2.optional_patches": "0001-acpi-omit-waet 0002-acpi-oem-id-table-id-revision,0001-acpi-omit-waet",
              "l2.oem_table_id": "A M I", "l2.ovmf_identity_dir": "/root/ovmf"})
    assert o["QAD_L2_OPTIONAL_PATCHES"] == "0001-acpi-omit-waet,0002-acpi-oem-id-table-id-revision"
    assert o["QAD_L2_OEM_TABLE_ID"] == "A M I" and o["QAD_L2_OVMF_IDENTITY"] == "1"
