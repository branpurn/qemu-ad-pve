import json

from conftest import fix, make_sysroot
from qad_setup import hostinfo as hi


def test_parse_lspci():
    funcs = hi.parse_lspci_nn(fix("lspci-Dnn.txt"))
    gpu = funcs["0000:01:00.0"]
    assert (gpu.vendor, gpu.device, gpu.cls) == ("10de", "2704", "0300")
    assert gpu.name == "NVIDIA Corporation AD103 [GeForce RTX 4080]"
    assert funcs["0000:01:00.1"].cls == "0403"
    # short form without domain
    short = hi.parse_lspci_nn("01:00.0 VGA compatible controller [0300]: NVIDIA Corporation X [10de:2704] (rev a1)")
    assert list(short) == ["0000:01:00.0"]


def test_sysfs_and_find_gpus(tmp_path):
    root = make_sysroot(tmp_path)
    funcs = hi.read_sysfs_pci(str(root))
    assert funcs["0000:01:00.0"].driver == "vfio-pci"
    assert funcs["0000:01:00.0"].iommu_group == "14"
    gpus = hi.find_gpus(funcs, hi.parse_lspci_nn(fix("lspci-Dnn.txt")))
    assert [g.slot for g in gpus] == ["0000:01:00", "0000:0e:00"]
    nv, amd = gpus
    assert [f.bdf for f in nv.functions] == ["0000:01:00.0", "0000:01:00.1"]
    assert nv.foreign_group_members() == [] and nv.groups == ["14"]
    assert len(amd.functions) == 3  # all functions of the slot, incl. the PSP
    assert hi.iommu_enabled(str(root))
    assert hi.nested_enabled(str(root), "amd") is True
    assert list(hi.iter_bridges(str(root))) == ["vmbr0"]


def test_foreign_group_member(tmp_path):
    from conftest import HOST_PCI
    pci = dict(HOST_PCI)
    pci["0000:02:00.0"] = ("0x144d", "0xa80a", "0x010802", "nvme", "14")  # NVMe shares the GPU group
    root = make_sysroot(tmp_path, pci=pci)
    nv = hi.find_gpus(hi.read_sysfs_pci(str(root)))[0]
    assert [f.bdf for f in nv.foreign_group_members()] == ["0000:02:00.0"]


def test_vm_refs_hostpci_mapping_args_and_snapshots(tmp_path):
    root = make_sysroot(tmp_path)
    funcs = hi.read_sysfs_pci(str(root))
    nv, amd = hi.find_gpus(funcs)
    confs = hi.read_vm_confs(str(root))
    mappings = hi.parse_pci_mappings(fix("pci-mapping.cfg"), "pve")
    assert mappings == {"igpu": ["0000:0e:00.0", "0000:0e:00.1"]}
    running = {"101"}
    nv_refs = hi.refs_to_gpu(nv, confs, running, mappings=mappings)
    assert [(r.vmid, r.how, r.running) for r in nv_refs] == [("100", "hostpci0", False), ("9200", "args", False)]
    amd_refs = hi.refs_to_gpu(amd, confs, running, mappings=mappings)
    assert [(r.vmid, r.how, r.running) for r in amd_refs] == [("101", "hostpci0(mapping:igpu)", True)]
    # the [snap1] section of VM 101 references the NVIDIA GPU but is not the active config
    assert "hostpci1" not in confs["101"]


def test_vm_pci_refs_lists_and_host_prefix():
    refs = hi.vm_pci_refs({"hostpci0": "host=0000:01:00.0;0000:01:00.1,pcie=1", "hostpci1": "02:00",
                           "args": "-device vfio-pci,host=03:00.0,id=x"})
    assert ("hostpci0", "0000:01:00", "0") in refs and ("hostpci0", "0000:01:00", "1") in refs
    assert ("hostpci1", "0000:02:00", None) in refs
    assert ("args", "0000:03:00", "0") in refs


def test_small_parsers():
    assert hi.parse_qm_list(fix("qm-list.txt"))["101"] == ("mapped-gpu", "running")
    st = {s.name: s for s in hi.parse_pvesm_status(fix("pvesm-images.txt"))}
    assert st["local-lvm"].active and not st["tank"].active
    assert round(st["local-lvm"].avail_gib) == 748
    assert hi.parse_meminfo(fix("meminfo.txt"))["MemAvailable"] == 40000000
    assert hi.parse_cpu_vendor(fix("cpuinfo.txt")) == "amd"
    assert "svm" in hi.parse_cpu_flags(fix("cpuinfo.txt"))
    assert hi.parse_pveversion(fix("pveversion.txt")) == (9, 2, 3)
    assert hi.parse_nextid('"9201"\n') == "9201" and hi.parse_nextid("") is None
    assert hi.parse_net0_mac("virtio=BC:24:11:12:34:56,bridge=vmbr0") == "BC:24:11:12:34:56"


def test_guest_ifaces_prefers_mac_and_skips_lo_link_local():
    text = fix("guest-ifaces.json")
    assert hi.parse_guest_ifaces(text, "BC:24:11:12:34:56") == ["192.168.1.77", "10.254.77.1"]
    assert hi.parse_guest_ifaces(json.dumps({"result": json.loads(text)})) == ["10.254.77.1", "192.168.1.77"]
    assert hi.parse_guest_ifaces("not json") == []


# ---------------------------------------------------------------- bridges incl. Open vSwitch (live QA: vmbr1 is OVS)
def test_bridge_parsers():
    assert hi.parse_ovs_list_br("vmbr1\n\nvmbr2\n") == ["vmbr1", "vmbr2"]
    assert hi.parse_ip_link_names(fix("ip-o-link.txt")) == ["lo", "eno1", "ovs-system", "vmbr0", "vmbr1",
                                                            "vmbr0.10", "fwbr9200i0"]
    assert hi.parse_interfaces_bridges(fix("interfaces-ovs.txt")) == {"vmbr0": "linux", "vmbr1": "ovs", "vmbr9": "ovs"}
    # bridge_ports (underscore form), OVS wins over a stray bridge-ports, comments ignored, auto ends a stanza
    txt = ("iface br1 inet manual\n  bridge_ports none\n"
           "iface vmbr5 inet manual\n  ovs_type OVSBridge\n  bridge-ports x\n"
           "iface vmbr6 inet manual\n  # ovs_type OVSBridge\n"
           "auto vmbr7\n  ovs_type OVSBridge\n")
    assert hi.parse_interfaces_bridges(txt) == {"br1": "linux", "vmbr5": "ovs"}


def test_detect_bridges_linux_and_ovs(tmp_path):
    root = make_sysroot(tmp_path)
    kinds, down = hi.detect_bridges(str(root), "vmbr1\n", fix("ip-o-link.txt"))
    assert kinds == {"vmbr0": "linux", "vmbr1": "ovs"} and down == ["vmbr9"]
    # ovs-vsctl missing/failed: still found via ovs_type OVSBridge + the netdev in sysfs
    assert hi.detect_bridges(str(root), "", "") == ({"vmbr0": "linux", "vmbr1": "ovs"}, ["vmbr9"])
    # netdev only visible in `ip link` (no sysfs entry, e.g. other sysroot)
    (root / "sys/class/net/vmbr1").rmdir()
    assert hi.detect_bridges(str(root), "", fix("ip-o-link.txt"))[0] == {"vmbr0": "linux", "vmbr1": "ovs"}
    assert hi.detect_bridges(str(root), "", "") == ({"vmbr0": "linux"}, ["vmbr1", "vmbr9"])
    # firewall/tap helper bridges are never offered
    (root / "sys/class/net/fwbr9200i0/bridge").mkdir(parents=True)
    assert "fwbr9200i0" not in hi.detect_bridges(str(root))[0]
