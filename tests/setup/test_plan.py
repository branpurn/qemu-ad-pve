import shlex

from conftest import make_sysroot
from qad_setup import hostinfo as hi
from qad_setup import plan
from qad_setup.config import Config


def gpu(tmp_path):
    return hi.find_gpus(hi.read_sysfs_pci(str(make_sysroot(tmp_path))))[0]


def test_l1_args_topology(tmp_path):
    a = plan.l1_args(gpu(tmp_path), 65536)
    assert a.startswith("-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536 ")
    assert "-device pcie-pci-bridge,id=gpubr,bus=ich9-pcie-port-1,addr=0x0" in a
    assert "vfio-pci,host=0000:01:00.0,id=qadgpu0,bus=gpubr,addr=0x1.0,multifunction=on" in a
    assert "vfio-pci,host=0000:01:00.1,id=qadgpu1,bus=gpubr,addr=0x1.1" in a
    assert "hostpci" not in a


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
    assert "PASSWORD" not in env


def test_secrets_env_and_hookscript(tmp_path):
    assert plan.secrets_env("a'b", "aaaaa-bbbbb-ccccc-ddddd-eeeee") == (
        "QAD_ADMIN_PASSWORD='a'\"'\"'b'\nQAD_PRODUCT_KEY=AAAAA-BBBBB-CCCCC-DDDDD-EEEEE\n")
    tmpl = "V=@QAD_VMID@ S=@QAD_GPU_SLOT@ F='@QAD_GPU_FUNCS@'"
    assert plan.hookscript(tmpl, "9201", gpu(tmp_path)) == "V=9201 S=0000:01:00 F='0000:01:00.0 0000:01:00.1'"
    assert plan.l2_mac("9201") == plan.l2_mac("9201") and plan.l2_mac("9201").startswith("52:54:00:")
