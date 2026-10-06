"""Host-side step logic with a fake runner (no PVE needed)."""
import os
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


# ---------------------------------------------------------------- PR #24 unit reuse in L1
import re as _re  # noqa: E402

from conftest import REPO  # noqa: E402


def _install_l2_unit(tmp_path, bdfs):
    src = (REPO / "setup/l1/qad-l1.sh").read_text()
    fn = _re.search(r"^install_l2_unit\(\) \{\n.*?^\}\n", src, _re.S | _re.M).group(0)
    lab = _re.search(r"^LAB_L1_GPU='([^']*)'", src, _re.M).group(1)
    w = tmp_path / "w10"
    w.mkdir()
    etc = tmp_path / "etc"
    (etc / "systemd/system").mkdir(parents=True)
    fn = fn.replace('"/etc/systemd/system/$L2_UNIT"', f'"{etc}/systemd/system/$L2_UNIT"')
    script = f"""set -euo pipefail
REPO={REPO}; W={w}; L2_UNIT=w10-l2.service; LAB_L1_GPU='{lab}'; QAD_GPU_IDS='10de:2704 10de:22bb'
say() {{ echo "$*"; }}
die() {{ echo "DIE $*" >&2; exit 1; }}
gpu_bdfs() {{ printf '%s\\n' {' '.join(bdfs)}; }}
{fn}
install_l2_unit
"""
    p = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=30)
    unit = etc / "systemd/system/w10-l2.service"
    helper = w / "l2-service.sh"
    return p, (unit.read_text() if unit.exists() else ""), (helper.read_text() if helper.exists() else "")


def test_pr24_unit_installed_verbatim_when_bdfs_match(tmp_path):
    p, unit, helper = _install_l2_unit(tmp_path, ["0000:02:01.0", "0000:02:01.1"])
    assert p.returncode == 0, p.stderr
    assert unit == (REPO / "scripts/qm-native-9200/w10-l2.service").read_text()
    assert helper == (REPO / "scripts/qm-native-9200/l2-service.sh").read_text()


def test_pr24_unit_adapted_to_other_bdfs_only(tmp_path):
    p, unit, helper = _install_l2_unit(tmp_path, ["0000:03:01.0", "0000:03:01.1"])
    assert p.returncode == 0, p.stderr
    orig_unit = (REPO / "scripts/qm-native-9200/w10-l2.service").read_text()
    orig_helper = (REPO / "scripts/qm-native-9200/l2-service.sh").read_text()
    assert "ConditionPathExists=/sys/bus/pci/devices/0000:03:01.0" in unit
    code = [l for l in (unit + helper).splitlines() if not l.lstrip().startswith("#")]
    assert not [l for l in code if "02:01" in l]
    assert "for d in 0000:03:01.0 0000:03:01.1; do" in helper
    # nothing else changed
    assert len(unit.splitlines()) == len(orig_unit.splitlines())
    diff = [(a, b) for a, b in zip(orig_helper.splitlines(), helper.splitlines()) if a != b]
    assert len(diff) == 2


# ---------------------------------------------------------------- L2 SSH host-key pinning (qad-l1.sh)
_FAKE_SSH = r'''#!/usr/bin/env python3
import os, sys
a = sys.argv[1:]
opts = dict(a[i + 1].split("=", 1) for i, x in enumerate(a) if x == "-o")
known, policy, key = opts["UserKnownHostsFile"], opts["StrictHostKeyChecking"], os.environ["FAKE_HOSTKEY"]
open(os.environ["FAKE_LOG"], "a").write(policy + "\n")
if os.environ.get("FAKE_DOWN"):
    sys.exit(255)
have = open(known).read().strip() if os.path.exists(known) else ""
if have and have != key:
    sys.exit(255)  # changed host key
if not have:
    if policy != "accept-new":
        sys.exit(255)
    open(known, "w").write(key + "\n")
sys.exit(int(os.environ.get("FAKE_RC", "0")))
'''
_FAKE_KEYGEN = r'''#!/usr/bin/env python3
import hashlib, sys
print("256 SHA256:" + hashlib.sha256(open(sys.argv[-1], "rb").read()).hexdigest()[:20] + " 10.99.0.2 (ED25519)")
'''


def _pin_env(tmp_path):
    src = (REPO / "setup/l1/qad-l1.sh").read_text()
    fns = "".join(_re.search(rf"^{n}\(\) \{{.*?^\}}\n", src, _re.S | _re.M).group(0)
                  for n in ("l2_strict", "l2_forget_hostkey", "l2_pin_hostkey", "l2_ssh"))
    b = tmp_path / "bin"
    b.mkdir()
    for name, body in (("ssh", _FAKE_SSH), ("ssh-keygen", _FAKE_KEYGEN)):
        (b / name).write_text(body)
        (b / name).chmod(0o755)
    w = tmp_path / "w10"
    w.mkdir()
    pre = (f"set -euo pipefail\nW={w}; QAD_ADMIN_USER=qad; QAD_L2_IP=10.99.0.2\n"
           "L2_KNOWN=$W/l2_known_hosts\nL2_PIN=$W/l2_hostkey.pinned\n" + fns)
    log = tmp_path / "ssh.log"

    def run(cmd, **env):
        e = dict(os.environ, PATH=f"{b}:{os.environ['PATH']}", FAKE_LOG=str(log),
                 FAKE_HOSTKEY="10.99.0.2 ssh-ed25519 AAAAkeyA")
        e.update(env)
        return subprocess.run(["bash", "-c", pre + cmd], capture_output=True, text=True, env=e, timeout=30)
    return run, w, log


def test_l2_hostkey_pinned_after_first_connect_then_strict(tmp_path):
    run, w, log = _pin_env(tmp_path)
    p = run("l2_ssh 'exit 0' || echo rc=$?", FAKE_DOWN="1")  # L2 still booting: nothing pinned
    assert "rc=255" in p.stdout and not (w / "l2_hostkey.pinned").exists()
    p = run("l2_ssh 'exit 0'; l2_strict")
    assert p.returncode == 0, p.stderr
    assert p.stdout.strip() == "yes" and "L2 host key pinned: SHA256:" in p.stderr
    pin = (w / "l2_hostkey.pinned").read_text()
    assert pin.startswith("256 SHA256:") and oct((w / "l2_hostkey.pinned").stat().st_mode)[-3:] == "600"
    p = run("l2_ssh 'exit 3' || echo rc=$?", FAKE_RC="3")  # remote command rc is passed through
    assert "rc=3" in p.stdout
    assert log.read_text().split() == ["accept-new", "accept-new", "yes"]
    # a changed key (same IP, new key) is refused once pinned
    p = run("l2_ssh 'exit 0' || echo rc=$?", FAKE_HOSTKEY="10.99.0.2 ssh-ed25519 AAAAkeyB")
    assert "rc=255" in p.stdout and (w / "l2_hostkey.pinned").read_text() == pin
    # a hand-edited known_hosts that no longer matches the pin is refused before ssh runs
    (w / "l2_known_hosts").write_text("10.99.0.2 ssh-ed25519 AAAAkeyB\n")
    p = run("l2_ssh 'exit 0' || echo rc=$?", FAKE_HOSTKEY="10.99.0.2 ssh-ed25519 AAAAkeyB")
    assert "rc=255" in p.stdout and "no longer matches the pinned key" in p.stderr
    # reinstall/wipe forgets the key -> next first connect pins the new one
    p = run("l2_forget_hostkey; l2_strict; l2_ssh 'exit 0'; l2_strict", FAKE_HOSTKEY="10.99.0.2 ssh-ed25519 AAAAkeyB")
    assert p.stdout.split() == ["accept-new", "yes"], p.stderr
    assert (w / "l2_hostkey.pinned").read_text() != pin


def test_l2_hostkey_reset_on_install_and_wipe_and_used_by_verify():
    src = (REPO / "setup/l1/qad-l1.sh").read_text()
    for step in ("step_l2_install", "step_l2_wipe"):
        body = _re.search(rf"^{step}\(\) \{{.*?^\}}\n", src, _re.S | _re.M).group(0)
        assert "l2_forget_hostkey" in body, step
    verify = _re.search(r"^step_verify\(\) \{.*?^\}\n", src, _re.S | _re.M).group(0)
    assert 'W10_KNOWN_HOSTS="$L2_KNOWN" W10_STRICT_HOST_KEY="$(l2_strict)"' in verify
    assert verify.index("l2_ssh 'exit 0'") < verify.index("w10-code43-run.sh")
    run_sh = (REPO / "tests/w10-code43-run.sh").read_text()
    assert '"UserKnownHostsFile=${W10_KNOWN_HOSTS}"' in run_sh
    assert '"StrictHostKeyChecking=${W10_STRICT_HOST_KEY:-yes}"' in run_sh


def test_missing_libs_and_host_packages(tmp_path):
    # Live E2E 2026-10-06: the copied host /opt/qemu-ad needed libgcrypt.so.20 + libiscsi.so.7 in a fresh L1.
    out = "=== qad-l1.sh qemu-ad-check 2026-10-06T12:47:41+00:00\nQEMU_AD=libs-missing libiscsi.so.7 libgcrypt.so.20 \n"
    assert steps._missing_libs(out) == ["libgcrypt.so.20", "libiscsi.so.7"]
    assert steps._missing_libs("QEMU_AD=QEMU emulator version 10.2.2\n") == []
    c = ctx(tmp_path, {"dpkg -S */libgcrypt.so.20": (0, "libgcrypt20:amd64: /usr/lib/x86_64-linux-gnu/libgcrypt.so.20\n"),
                       "dpkg -S */libiscsi.so.7": (0, "libiscsi7:amd64: /usr/lib/x86_64-linux-gnu/libiscsi.so.7\n")})
    assert steps.host_lib_packages(c, ["libgcrypt.so.20", "libiscsi.so.7"]) == ["libgcrypt20", "libiscsi7"]
    with pytest.raises(steps.StepError, match="no host package"):
        steps.host_lib_packages(c, ["libnothere.so.1"])
    with pytest.raises(steps.StepError, match="unexpected library"):
        steps.host_lib_packages(c, ["x; rm -rf /"])


def test_l1_qemu_ad_installs_missing_libs_after_copy(tmp_path, monkeypatch):
    c = ctx(tmp_path, {"dpkg -S */libgcrypt.so.20": (0, "libgcrypt20:amd64: /usr/lib/x86_64-linux-gnu/libgcrypt.so.20\n")})
    c.cfg.set("l1.qemu_ad", "copy")
    checks = iter([subprocess.CompletedProcess([], 1, "QEMU_AD=libs-missing libgcrypt.so.20\n", ""),
                   subprocess.CompletedProcess([], 1, "QEMU_AD=libs-missing libgcrypt.so.20\n", ""),
                   subprocess.CompletedProcess([], 0, "QEMU_AD=QEMU emulator version 10.2.2\n", "")])
    monkeypatch.setattr(steps.Ctx, "ssh_probe", lambda self, remote, timeout=60: next(checks))

    class P:
        returncode = 0
        stdout = None

        def __init__(self, *a, **k):
            pass

        def wait(self):
            return 0
    monkeypatch.setattr("subprocess.Popen", P)
    monkeypatch.setattr("subprocess.run", lambda *a, **k: subprocess.CompletedProcess([], 0, "", ""))
    assert steps.s_l1_qemu_ad(c) == "QEMU_AD=QEMU emulator version 10.2.2"
    assert any("qad-l1.sh qemu-ad-libs libgcrypt20" in " ".join(a) for a in c.runner.ran)
