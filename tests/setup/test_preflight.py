from conftest import fix, make_sysroot
from qad_setup import hostinfo as hi
from qad_setup import preflight as pf
from qad_setup.config import Config


def snapshot(tmp_path, running=("101",), **kw):
    root = make_sysroot(tmp_path, **kw)
    s = pf.Snapshot(pveversion=fix("pveversion.txt"), is_root=True, cpu_vendor="amd",
                    cpu_flags={"svm"}, nested=True, iommu=True)
    funcs = hi.read_sysfs_pci(str(root))
    s.gpus = hi.find_gpus(funcs, hi.parse_lspci_nn(fix("lspci-Dnn.txt")))
    s.vm_list = {"100": ("win-gpu", "stopped"), "101": ("mapped-gpu", "running" if "101" in running else "stopped"),
                 "9200": ("nested-l1", "running" if "9200" in running else "stopped")}
    confs = hi.read_vm_confs(str(root))
    s.vm_mem_mb = {v: int(c["memory"]) for v, c in confs.items()}
    maps = hi.parse_pci_mappings(fix("pci-mapping.cfg"), "pve")
    run = {v for v, (_, st) in s.vm_list.items() if st == "running"}
    for g in s.gpus:
        g.refs = hi.refs_to_gpu(g, confs, run, mappings=maps)
    s.storages = {"images": hi.parse_pvesm_status(fix("pvesm-images.txt")),
                  "iso": hi.parse_pvesm_status(fix("pvesm-iso.txt")),
                  "snippets": hi.parse_pvesm_status(fix("pvesm-snippets.txt"))}
    s.meminfo = hi.parse_meminfo(fix("meminfo.txt"))
    s.nextid = "9201"
    s.bridges = ["vmbr0"]
    s.tools = {t: True for t in pf.TOOLS}
    s.iso_path = "/var/lib/vz/template/iso/win.iso"
    s.paths = {s.iso_path: 6 * 1024 ** 3}
    return s


def cfg(**over):
    c = Config({"l2.windows_iso": "local:iso/win.iso", "l1.storage": "local-lvm", "l1.iso_storage": "local",
                "l1.snippets_storage": "local", "l1.hookscript": "yes", "l1.vmid": "9201"})
    for k, v in over.items():
        c.set(k.replace("__", "."), v)
    return c


def by_name(checks):
    return {c.name: c for c in checks}


def test_happy_path(tmp_path):
    s = snapshot(tmp_path)
    gpu = pf.pick_gpu(s, "0000:01:00")
    checks = by_name(pf.evaluate(cfg(), s, "9201", gpu))
    assert not pf.failed(list(checks.values())), [c for c in checks.values() if c.status == "FAIL"]
    assert checks["GPU IOMMU group"].status == "PASS"
    assert checks["GPU in use"].status == "WARN"  # stopped VMs 100 and 9200 reference it
    assert checks["GPU host driver"].status == "WARN"  # audio on snd_hda_intel, rebound by the hookscript
    assert checks["NVIDIA driver"].status == "WARN"


def test_gpu_in_use_by_running_vm_fails_and_ram_hint(tmp_path):
    s = snapshot(tmp_path, running=("9200",))
    s.meminfo["MemAvailable"] = 6000 * 1024
    checks = by_name(pf.evaluate(cfg(), s, "9201", pf.pick_gpu(s, "0000:01:00")))
    assert checks["GPU in use"].status == "FAIL"
    assert "qm shutdown 9200" in checks["GPU in use"].fix
    assert checks["Host RAM"].status == "WARN"  # enough once 9200 (12 GiB) stops


def test_display_function_on_host_driver_fails(tmp_path):
    s = snapshot(tmp_path)
    checks = by_name(pf.evaluate(cfg(gpu__slot="0000:0e:00"), s, "9201", pf.pick_gpu(s, "0000:0e:00")))
    assert checks["GPU host driver"].status == "FAIL"
    assert checks["GPU in use"].status == "FAIL"  # VM 101 runs with it via a resource mapping


def test_vmid_taken_storage_missing_iso_missing(tmp_path):
    s = snapshot(tmp_path)
    s.paths = {}
    c = cfg(l1__storage="tank", l1__iso_storage="nope")
    checks = by_name(pf.evaluate(c, s, "9200", pf.pick_gpu(s, "0000:01:00")))
    assert checks["VMID"].status == "FAIL" and "9201" in checks["VMID"].fix
    assert checks["Disk storage"].status == "FAIL"
    assert checks["Seed ISO storage"].status == "FAIL"
    assert checks["Windows ISO"].status == "FAIL"


def test_no_hookscript_needs_vfio_bound_gpu(tmp_path):
    s = snapshot(tmp_path)
    c = cfg(l1__hookscript="no")
    checks = by_name(pf.evaluate(c, s, "9201", pf.pick_gpu(s, "0000:01:00")))
    assert checks["Hookscript"].status == "FAIL" and "snippets" in checks["Hookscript"].fix
    for f in pf.pick_gpu(s, "0000:01:00").functions:
        f.driver = "vfio-pci"
    checks = by_name(pf.evaluate(c, s, "9201", pf.pick_gpu(s, "0000:01:00")))
    assert checks["Hookscript"].status == "WARN"


def test_host_prereqs_fail(tmp_path):
    s = snapshot(tmp_path)
    s.pveversion = "pve-manager/8.0.4/abc"
    s.is_root = False
    s.nested = False
    s.iommu = False
    s.tools["genisoimage"] = False
    checks = by_name(pf.evaluate(cfg(), s, "9201", pf.pick_gpu(s, "0000:01:00")))
    for name in ("Proxmox VE", "root", "Nested virtualization", "Host IOMMU", "Host tools"):
        assert checks[name].status == "FAIL", name
    assert "does not change host modules" in checks["Nested virtualization"].fix


def test_resume_own_vm(tmp_path):
    s = snapshot(tmp_path, running=())
    s.vm_list["9201"] = ("qad-l1", "running")
    gpu = pf.pick_gpu(s, "0000:01:00")
    gpu.refs.append(hi.VmRef("9201", "args", True))
    checks = by_name(pf.evaluate(cfg(), s, "9201", gpu, own_vm=True))
    assert checks["VMID"].status == "PASS"
    assert checks["GPU in use"].status == "WARN"  # only the stopped others; our own running L1 is fine
    assert checks["Host RAM"].status == "PASS"


def test_helpers(tmp_path):
    s = snapshot(tmp_path)
    assert [g.slot for g in pf.gpu_candidates(s)] == ["0000:01:00", "0000:0e:00"]
    text = pf.describe_gpu(pf.pick_gpu(s, "0000:01:00"))
    assert "group 14" in text and "VM 100 (win-gpu) hostpci0 stopped" in text
    assert pf.choose_storage(s.storages["images"]) == "local-lvm"
    assert pf.choose_storage(s.storages["iso"], prefer=("local",)) == "local"
    assert pf.choose_storage([]) is None
    assert pf.needed_gib(cfg(), s) > 175
