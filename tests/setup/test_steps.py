"""Host-side step logic with a fake runner (no PVE needed)."""
import subprocess

import pytest

from conftest import make_sysroot
from qad_setup import hostinfo as hi
from qad_setup import steps, ui
from qad_setup.config import Config
from qad_setup.manifest import Manifest
from qad_setup.state import State


class FakeRunner:
    dry_run = False

    def __init__(self, probes):
        self.probes = probes
        self.ran = []
        self.secrets = []

    def probe(self, argv, timeout=60, input_text=None):
        for prefix, (rc, out) in self.probes.items():
            if " ".join(argv).startswith(prefix):
                return subprocess.CompletedProcess(argv, rc, out, "")
        return subprocess.CompletedProcess(argv, 1, "", "unexpected")

    def run(self, argv, **kw):
        self.ran.append(list(argv))
        return subprocess.CompletedProcess(argv, 0, "", "")

    def note(self, text):
        pass


def ctx(tmp_path, probes):
    gpu = hi.find_gpus(hi.read_sysfs_pci(str(make_sysroot(tmp_path / "r"))))[0]
    cfg = Config({"l1.vmid": "9201", "l1.storage": "local-lvm", "l1.iso_storage": "local",
                  "l2.windows_iso": "local:iso/w.iso", "l1.hookscript": "no"})
    m = Manifest(install_id="abc123", path=str(tmp_path / "m.json"))
    return steps.Ctx(cfg=cfg, runner=FakeRunner(probes), state=State(str(tmp_path / "s.json")), manifest=m,
                     prompter=ui.Prompter(True), repo=".", state_dir=str(tmp_path), gpu=gpu)


def test_vm_create_refuses_foreign_vm(tmp_path):
    c = ctx(tmp_path, {"qm config 9201": (0, "name: other\ndescription: production db\n")})
    with pytest.raises(steps.StepError, match="not created by this setup"):
        steps.s_vm_create(c)
    assert c.runner.ran == []


def test_vm_create_resumes_without_duplicating_disks(tmp_path):
    conf = ("description: qemu-ad-pve-setup%3Aabc123 L1\nscsi1: local-lvm:vm-9201-disk-2,size=128G\n"
            "net0: virtio=BC:24:11:00:00:01,bridge=vmbr0\n")
    c = ctx(tmp_path, {"qm config 9201": (0, conf)})
    steps.s_vm_create(c)
    ran = [" ".join(a) for a in c.runner.ran]
    assert not any(r.startswith("qm create") for r in ran)
    assert not any("--scsi1" in r for r in ran)  # already there: a second qm set would allocate another disk
    assert any("--ide0 local:iso/w.iso,media=cdrom" in r for r in ran)
    assert c.state.facts["l1_mac"] == "BC:24:11:00:00:01"


def test_vm_start_refuses_when_gpu_busy(tmp_path):
    c = ctx(tmp_path, {"qm status 9201": (0, "status: stopped\n"),
                       "qm list": (0, "VMID NAME STATUS\n100 win-gpu running\n")})
    c.gpu.refs = [hi.VmRef("100", "hostpci0", True)]
    with pytest.raises(steps.StepError, match="qm shutdown 100"):
        steps.s_vm_start(c)
    assert c.runner.ran == []


def test_run_steps_resumes_and_records_failure(tmp_path, monkeypatch):
    c = ctx(tmp_path, {})
    calls = []

    def ok(name):
        def f(_c):
            calls.append(name)
            return name
        return f

    def boom(_c):
        calls.append("boom")
        raise steps.StepError("nope")

    fake = [("a", "A", ok("a")), ("b", "B", boom), ("c", "C", ok("c"))]
    monkeypatch.setattr(steps, "STEPS", fake)
    assert steps.run_steps(c) is False
    assert calls == ["a", "boom"]
    assert c.state.status("a") == "done" and c.state.status("b") == "failed"
    fake[1] = ("b", "B", ok("b"))
    calls.clear()
    assert steps.run_steps(c) is True
    assert calls == ["b", "c"]  # a is not redone
    calls.clear()
    steps.run_steps(c, redo=["a"])
    assert calls == ["a"]
