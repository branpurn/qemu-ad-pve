"""The default L1 hides the hypervisor (systemd-detect-virt = none); the DKMS guard must not block setup."""
import os

HERE = os.path.dirname(__file__)


def test_qad_l1_bypasses_vm_guard_of_l1_dkms():
    s = open(os.path.join(HERE, "..", "..", "setup", "l1", "qad-l1.sh")).read()
    line = [x for x in s.splitlines() if "l1-dkms.sh" in x and "install" in x and not x.lstrip().startswith("#")]
    assert line and "KVM_L1_FORCE=i-know-this-is-not-the-pve-host" in line[0]
    assert "/etc/pve" in s and "pveversion" in s  # qad-l1.sh keeps its own PVE-host refusal
