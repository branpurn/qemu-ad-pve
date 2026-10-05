import gzip
import importlib.util
import pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("cnk", ROOT / "tools" / "check-new-kernel.py")
cnk = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cnk)

SAMPLE = b"""Package: proxmox-kernel-7.0.6-2-pve
Version: 7.0.6-2

Package: proxmox-kernel-7.0.6-2-pve-signed
Package: proxmox-kernel-7.0.14-9-pve
Package: proxmox-kernel-7.0.14-20-pve
Package: proxmox-kernel-7.0.14-20-pve-signed-template
Package: proxmox-kernel-helper
Package: proxmox-kernel-7.0.14-100-pve
"""


def test_parse_sorts_numerically_and_ignores_variants():
    assert cnk.parse_packages(SAMPLE) == ["7.0.6-2", "7.0.14-9", "7.0.14-20", "7.0.14-100"]


def test_parse_gzip():
    assert cnk.parse_packages(gzip.compress(SAMPLE))[-1] == "7.0.14-100"


def test_newer_than():
    v = cnk.parse_packages(SAMPLE)
    assert cnk.newer_than(v, "7.0.14-20") == ["7.0.14-100"]
    assert cnk.newer_than(v, "7.0.14-100") == []


def test_cli_exit_codes_and_outputs(tmp_path, capsys):
    pkg = tmp_path / "Packages"
    pkg.write_bytes(SAMPLE)
    out = tmp_path / "gh_out"
    assert cnk.main(["--packages-file", str(pkg), "--baseline", "7.0.14-20", "--github-output", str(out)]) == 10
    assert "new=true" in out.read_text() and "latest=7.0.14-100" in out.read_text()
    assert cnk.main(["--packages-file", str(pkg), "--baseline", "7.0.14-100"]) == 0
    assert "nothing new" in capsys.readouterr().out


def test_upstream():
    assert cnk.upstream("7.0.14-20") == "7.0.14"


def test_baseline_file_is_valid():
    assert cnk.vkey((ROOT / "tools" / "pve-kernel-baseline.txt").read_text().split()[0])
