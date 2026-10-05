import pytest

from qad_setup.manifest import HostFacts, Manifest, ManifestError, plan_uninstall, vm_marker


def facts(status=None, desc="", files=None, vols=()):
    files = files or {}
    return HostFacts(vm_status=lambda v: (status or {}).get(v), vm_description=lambda v: desc,
                     file_sha256=lambda p: files.get(p), volume_exists=lambda v: v in vols)


def manifest(tmp_path):
    m = Manifest(install_id="abc123", path=str(tmp_path / "manifest.json"))
    m.add("vm", vmid="9201", marker=vm_marker("abc123"))
    m.add("volume", volid="local:iso/qad-l1-9201-seed.iso", path="/var/lib/vz/template/iso/qad-l1-9201-seed.iso",
          sha256="s1")
    m.add("dir", path="/var/lib/qemu-ad/setup")
    m.add("dir", path="/var/lib/qemu-ad/setup/ssh")
    m.add("file", path="/var/lib/qemu-ad/setup/ssh/id_ed25519", sha256="k1")
    m.add("file", path="/var/lib/qemu-ad/setup/state.json")
    return m


def test_roundtrip_and_restrictions(tmp_path):
    m = manifest(tmp_path)
    m.add("file", path="/var/lib/qemu-ad/setup/ssh/id_ed25519", sha256="k2")  # update, not duplicate
    m.save()
    m2 = Manifest.load(m.path)
    assert m2.install_id == "abc123" and len(m2.entries) == 6
    assert m2.vm()["vmid"] == "9201"
    assert (tmp_path / "manifest.json").stat().st_mode & 0o777 == 0o600
    with pytest.raises(ManifestError):
        m.add("file", path="/etc/passwd")
    with pytest.raises(ManifestError):
        m.add("dir", path="/usr/local/x")
    assert Manifest.load(str(tmp_path / "missing.json")) is None


def test_full_uninstall_running_vm(tmp_path):
    m = manifest(tmp_path)
    f = facts({"9201": "running"}, "qemu-ad-pve-setup:abc123 L1",
              {"/var/lib/vz/template/iso/qad-l1-9201-seed.iso": "s1", "/var/lib/qemu-ad/setup/ssh/id_ed25519": "k1",
               "/var/lib/qemu-ad/setup/state.json": "whatever"}, {"local:iso/qad-l1-9201-seed.iso"})
    acts = plan_uninstall(m, f, shutdown_timeout=120)
    desc = [a.describe() for a in acts]
    assert desc[0] == "qm shutdown 9201 --timeout 120 --forceStop 1"
    assert desc[1] == "qm destroy 9201 --purge 1 --destroy-unreferenced-disks 1"
    assert desc[2] == "pvesm free local:iso/qad-l1-9201-seed.iso"
    assert "rm -f /var/lib/qemu-ad/setup/ssh/id_ed25519" in desc
    assert "rm -f /var/lib/qemu-ad/setup/state.json" in desc  # no sha recorded: volatile
    assert desc[-2:] == ["rmdir /var/lib/qemu-ad/setup/ssh  (only if empty)", "rmdir /var/lib/qemu-ad/setup  (only if empty)"]


def test_vm_without_marker_is_never_touched(tmp_path):
    m = manifest(tmp_path)
    for force in (False, True):
        acts = plan_uninstall(m, facts({"9201": "stopped"}, "someone else's VM"), force=force)
        assert acts[0].kind == "skip" and "marker" in acts[0].reason
        assert not any(a.argv[:2] == ["qm", "destroy"] for a in acts)


def test_changed_files_skipped_unless_force_and_gone_vm(tmp_path):
    m = manifest(tmp_path)
    files = {"/var/lib/vz/template/iso/qad-l1-9201-seed.iso": "CHANGED", "/var/lib/qemu-ad/setup/ssh/id_ed25519": "X"}
    f = facts({}, "", files, {"local:iso/qad-l1-9201-seed.iso"})
    acts = plan_uninstall(m, f)
    assert acts[0].kind == "skip" and "does not exist" in acts[0].reason
    skipped = {a.target for a in acts if a.kind == "skip"}
    assert {"local:iso/qad-l1-9201-seed.iso", "/var/lib/qemu-ad/setup/ssh/id_ed25519"} <= skipped
    forced = plan_uninstall(m, f, force=True)
    assert any(a.argv == ["pvesm", "free", "local:iso/qad-l1-9201-seed.iso"] for a in forced)
    assert any(a.kind == "rm" and a.target.endswith("id_ed25519") for a in forced)
