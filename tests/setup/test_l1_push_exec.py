"""l1_push must make the in-L1 build scripts executable (git may store them 0644)."""
import os

HERE = os.path.dirname(__file__)


def test_push_chmods_build_scripts():
    s = open(os.path.join(HERE, "..", "..", "setup", "qad_setup", "steps.py")).read()
    line = [x for x in s.splitlines() if "tar -xzf - -C" in x][0]
    for need in ("setup/l1/*.sh", "/qemu-ad-pve.sh", "scripts/ovmf-identity/*.sh"):
        assert need in line, need
