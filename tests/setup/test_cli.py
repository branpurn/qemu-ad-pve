import json
import os
import subprocess

from conftest import REPO
from qad_setup import cli, steps
from qad_setup.manifest import Manifest, vm_marker


def run(stub_env, *args, input_text=None):
    cmd = [str(REPO / "setup.sh"), *args, "--sysroot", str(stub_env["root"]), "--state-dir", str(stub_env["state"])]
    return subprocess.run(cmd, capture_output=True, text=True, input=input_text, env=os.environ.copy(), timeout=60)


def test_normalize_argv():
    assert cli.normalize_argv([]) == ["install"]
    assert cli.normalize_argv(["--dry-run", "verify"]) == ["verify", "--dry-run"]
    assert cli.normalize_argv(["--config", "status", "-y"]) == ["install", "--config", "status", "-y"]
    assert cli.normalize_argv(["--help"]) == ["--help"]
    # top-level --dry-run / -n is `install --dry-run` (docs/SETUP.md; live QA 2026-10-05 reported a mismatch)
    assert cli.normalize_argv(["--dry-run"]) == ["install", "--dry-run"]
    assert cli.normalize_argv(["-n", "-y"]) == ["install", "-n", "-y"]
    assert cli.normalize_argv(["--no-color", "--dry-run", "-y"]) == ["install", "--no-color", "--dry-run", "-y"]


def test_top_level_dry_run_aliases(stub_env):
    for flag in ("--dry-run", "-n"):
        p = run(stub_env, flag, "--yes", "--set", "stage.nvidia_driver=/nonexistent/nv.exe")
        assert p.returncode == 0, p.stderr + p.stdout
        assert "nothing was executed" in p.stdout and "qm create 9201 " in p.stdout
        assert not stub_env["state"].exists()


def test_preflight_accepts_ovs_bridge(stub_env):
    p = run(stub_env, "preflight", "--yes", "--set", "l1.bridge=vmbr1")
    line = [l for l in p.stdout.splitlines() if " Bridge " in f" {l} "]
    assert line and line[0].startswith("PASS") and "vmbr1 (Open vSwitch)" in line[0], p.stdout


def test_preflight_lists_gpus_and_fails_only_on_root(stub_env):
    p = run(stub_env, "preflight", "--yes")
    assert "0000:01:00  NVIDIA Corporation AD103 [GeForce RTX 4080]" in p.stdout
    assert "VM 101 (mapped-gpu) hostpci0(mapping:igpu) RUNNING" in p.stdout
    fails = [l for l in p.stdout.splitlines() if l.startswith("FAIL")]
    expected = [] if os.geteuid() == 0 else ["root"]
    assert [l.split()[1] for l in fails] == expected, p.stdout
    assert p.returncode == (0 if os.geteuid() == 0 else 1)
    assert not stub_env["state"].exists()  # preflight writes nothing


def test_install_dry_run_prints_everything_and_changes_nothing(stub_env):
    p = run(stub_env, "--dry-run", "--yes", "--set", "stage.nvidia_driver=/nonexistent/nv.exe")
    out = p.stdout
    assert p.returncode == 0, p.stderr + out
    assert "auto-selected the only passthrough-ready GPU: 0000:01:00" in out
    assert "qm create 9201 " in out and "--machine q35,viommu=intel" in out
    assert "vfio-pci,host=0000:01:00.0,id=gpu-vga,bus=gpubr,addr=0x1.0,multifunction=on" in out
    assert "--startup down=240" in out and "--onboot 0" in out and "--hostpci" not in out
    assert "write /var/lib/vz/snippets/qad-l1-9201-gpu-guard.pl (mode 0o755" in out
    assert "qm set 9201 --ide0 local:iso/Win10_22H2_English_x64.iso,media=cdrom" in out
    assert "--hookscript local:snippets/qad-l1-9201-gpu-guard.pl" in out
    assert "genisoimage -quiet -output" in out and "qad-l1-9201-seed.iso -volid cidata" in out
    for step in steps.STEP_NAMES:
        assert f"== {step}:" in out
    assert "[L1 <L1-IP>] /root/qemu-ad-pve/setup/l1/qad-l1.sh dkms" in out
    assert "Staging: nvidia_driver" in out  # preflight FAIL for the missing file ...
    assert "a real run would stop here" in p.stderr  # ... reported, dry run continues
    assert "nothing was executed" in out
    assert not stub_env["state"].exists()
    assert not list(stub_env["iso_dir"].glob("qad-*"))


def test_install_refuses_without_root_or_confirmation(stub_env):
    p = run(stub_env, "install", input_text="")
    if os.geteuid() != 0:
        assert p.returncode == 2 and "must run as root" in p.stderr
    assert not stub_env["state"].exists()


def test_status_verify_uninstall_without_install(stub_env):
    for sub in ("status", "verify", "uninstall"):
        p = run(stub_env, sub)
        assert p.returncode == 1 and "no installation recorded" in p.stderr


def test_uninstall_dry_run_plan(stub_env):
    state = stub_env["state"]
    m = Manifest(install_id="abc123", path=str(state / "manifest.json"))
    m.add("vm", vmid="9201", marker=vm_marker("abc123"))
    m.add("dir", path="/var/lib/qemu-ad/setup")
    m.save()
    p = run(stub_env, "uninstall", "--dry-run")
    assert p.returncode == 0, p.stderr
    # stub `qm config` fails -> description unknown -> VM 9201 is NOT destroyed
    assert "SKIP VM 9201" in p.stdout and "qm destroy" not in p.stdout
    assert "dry run: nothing removed" in p.stdout
    assert json.loads((state / "manifest.json").read_text())["install_id"] == "abc123"


def test_parse_secrets():
    assert steps.parse_secrets("QAD_ADMIN_PASSWORD='a'\"'\"'b'\nQAD_PRODUCT_KEY=''\n") == {
        "QAD_ADMIN_PASSWORD": "a'b", "QAD_PRODUCT_KEY": ""}


def test_python39_syntax():
    # PVE 8 ships python 3.11, PVE 9 3.13; keep 3.9 syntax so older nodes still get a clear preflight.
    import ast
    for f in (REPO / "setup/qad_setup").glob("*.py"):
        ast.parse(f.read_text(), feature_version=(3, 9))


def test_pick_windows_iso_skips_virtio_and_unattend():
    # Volids as listed on the live E2E host (2026-10-06): virtio-win sorts before Win10 and was auto-picked.
    vols = ["iso_images:iso/debian-13.6.0-amd64-DVD-1.iso", "iso_images:iso/virtio-win-0.1.285.iso",
            "iso_images:iso/w10bm-unattend.iso", "iso_images:iso/Win10_22H2_English_x64v1.iso",
            "iso_images:iso/Win11_24H2_English_x64.iso", "local:iso/virtio-win-0.1.285.iso"]
    assert cli.pick_windows_iso(vols) == "iso_images:iso/Win10_22H2_English_x64v1.iso"
    assert cli.pick_windows_iso(vols, "11") == "iso_images:iso/Win11_24H2_English_x64.iso"
    assert cli.pick_windows_iso(["local:iso/en-us_windows_10_business_editions_22h2_x64_dvd.iso"]) \
        == "local:iso/en-us_windows_10_business_editions_22h2_x64_dvd.iso"
    assert cli.pick_windows_iso(["local:iso/virtio-win.iso", "local:iso/windows-unattend.iso"]) is None
    assert cli.pick_windows_iso([]) is None


def test_verify_log_is_recorded_for_uninstall(stub_env, monkeypatch):
    # live E2E 2026-10-06: verify-*.log (and setup/logs/) were not in the manifest -> left behind by uninstall
    from qad_setup import manifest as manifest_mod
    state = stub_env["state"]
    monkeypatch.setattr(manifest_mod, "SAFE_PREFIXES", (str(state) + "/",))
    m = Manifest(install_id="abc123", path=str(state / "manifest.json"))
    m.add("dir", path=str(state / "setup"))
    m.save()
    rc = cli.main(["verify", "--sysroot", str(stub_env["root"]), "--state-dir", str(state)])
    assert rc == 1  # no L1 address recorded
    got = {(e["kind"], e["path"]) for e in json.loads((state / "manifest.json").read_text())["entries"]}
    assert ("dir", str(state / "setup" / "logs")) in got
    logs = [p for k, p in got if k == "file" and p.startswith(str(state / "setup" / "logs" / "verify-"))]
    assert len(logs) == 1 and os.path.exists(logs[0])
