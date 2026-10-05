"""Unit tests for tools/gen-launch.py (run: pytest -q)."""
import importlib.util
import pathlib
import subprocess
import sys

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SAMPLE = (ROOT / "tests" / "data" / "qm-showcmd-9200.txt").read_text()

spec = importlib.util.spec_from_file_location("gen_launch", ROOT / "tools" / "gen-launch.py")
gl = importlib.util.module_from_spec(spec)
sys.modules["gen_launch"] = gl
spec.loader.exec_module(gl)


def build(text=SAMPLE, **kw):
    cfg = gl.Config(**kw)
    binary, opts = gl.parse_cmdline(gl.tokenize(text))
    new, warnings = gl.transform(binary, opts, cfg)
    return new, warnings, cfg


def devices(opts, driver):
    return [o for o in opts if gl.driver_of(o) == driver]


def props(opt):
    return dict(gl.split_props(opt.value))


# ---- parsing helpers -------------------------------------------------------
def test_split_join_roundtrip_with_escaped_comma():
    p = gl.split_props("file=/a,,b/c,format=raw,flag")
    assert p == [("file", "/a,b/c"), ("format", "raw"), ("flag", None)]
    assert gl.join_props(p) == "file=/a,,b/c,format=raw,flag"


def test_tokenize_pretty_output_with_continuations():
    pretty = "/usr/bin/kvm \\\n  -id 1 \\\n  -name 'a b' \\\n  -daemonize\n"
    toks = gl.tokenize(pretty)
    assert toks == ["/usr/bin/kvm", "-id", "1", "-name", "a b", "-daemonize"]
    _, opts = gl.parse_cmdline(toks)
    assert [(o.flag, o.value) for o in opts] == [("-id", "1"), ("-name", "a b"), ("-daemonize", None)]


def test_rejects_non_qemu_input():
    with pytest.raises(gl.GenError):
        gl.parse_cmdline(["echo", "hi"])


# ---- vIOMMU ----------------------------------------------------------------
def test_intel_iommu_is_first_device_with_required_flags():
    opts, _, _ = build()
    devs = [o for o in opts if o.flag == "-device"]
    assert gl.driver_of(devs[0]) == "intel-iommu"
    p = props(devs[0])
    assert p["intremap"] == "on" and p["caching-mode"] == "on"
    assert len(devices(opts, "intel-iommu")) == 1


def test_kernel_irqchip_split_added_when_missing():
    text = SAMPLE.replace(",kernel-irqchip=split", "")
    opts, _, _ = build(text)
    machines = [gl.split_props(o.value) for o in opts if o.flag == "-machine"]
    assert any(("kernel-irqchip", "split") in m for m in machines)


def test_kernel_irqchip_on_is_forced_to_split():
    text = SAMPLE.replace("kernel-irqchip=split", "kernel-irqchip=on")
    opts, _, _ = build(text)
    assert all("kernel-irqchip=on" not in o.value for o in opts if o.flag == "-machine")
    assert not gl.check(opts)


def test_amd_iommu_removed_with_note():
    text = SAMPLE.replace("-device 'intel-iommu,intremap=on,caching-mode=on'",
                          "-device 'amd-iommu,intremap=on,xtsup=on,dma-remap=on'")
    opts, warnings, _ = build(text)
    assert not devices(opts, "amd-iommu")
    assert len(devices(opts, "intel-iommu")) == 1
    assert any("amd-iommu" in w for w in warnings)


def test_iommu_extra_props_and_keep_position():
    opts, _, _ = build(iommu_extra=["device-iotlb=on", "aw-bits=48"], iommu_position="keep")
    io = devices(opts, "intel-iommu")[0]
    assert props(io)["device-iotlb"] == "on" and props(io)["aw-bits"] == "48"
    assert [o for o in opts if o.flag == "-device"][-1] is io  # stayed last, as in qm output


def test_non_q35_machine_rejected():
    with pytest.raises(gl.GenError, match="q35"):
        build(SAMPLE.replace("q35+pve0", "i440fx"))


# ---- GPU topology ------------------------------------------------------------
def test_both_gpu_functions_behind_bridge_on_qm_root_port():
    opts, _, _ = build()
    bridges = devices(opts, "pcie-pci-bridge")
    assert len(bridges) == 1
    b = props(bridges[0])
    assert b["bus"] == "ich9-pcie-port-1"  # qm's own root port is reused (as in PR #4)
    vfio = devices(opts, "vfio-pci")
    assert [props(v)["host"] for v in vfio] == ["0000:02:00.0", "0000:02:00.1"]
    assert {props(v)["bus"] for v in vfio} == {b["id"]}
    assert props(vfio[0])["addr"] == "0x1.0" and props(vfio[0])["multifunction"] == "on"
    assert props(vfio[1])["addr"] == "0x1.1"
    # bridge precedes its children
    order = [o for o in opts if o.flag == "-device"]
    assert order.index(bridges[0]) < order.index(vfio[0])


def test_gpu_ids_preserved():
    opts, _, _ = build()
    assert [props(v)["id"] for v in devices(opts, "vfio-pci")] == ["hostpci0.0", "hostpci0.1"]


def test_own_root_port_with_pref64_reserve():
    opts, _, _ = build(pref64_reserve="32G")
    rp = devices(opts, "pcie-root-port")
    assert len(rp) == 1 and props(rp[0])["pref64-reserve"] == "32G" and props(rp[0])["bus"] == "pcie.0"
    assert props(devices(opts, "pcie-pci-bridge")[0])["bus"] == props(rp[0])["id"]


def test_root_bus_parent_gets_dedicated_root_port():
    text = SAMPLE.replace("bus=ich9-pcie-port-1", "bus=pcie.0")
    opts, _, _ = build(text)
    assert len(devices(opts, "pcie-root-port")) == 1
    assert not gl.check(opts)


def test_single_function_gpu_rejected_by_default():
    text = SAMPLE.replace(
        " -device 'vfio-pci,host=0000:02:00.1,id=hostpci0.1,bus=ich9-pcie-port-1,addr=0x0.1'", "")
    with pytest.raises(gl.GenError, match="Both GPU functions"):
        build(text)
    opts, _, _ = build(text, allow_single_function=True)
    assert len(devices(opts, "vfio-pci")) == 1


def test_no_gpu_is_an_error():
    text = SAMPLE.replace("vfio-pci", "e1000e")
    with pytest.raises(gl.GenError, match="passthrough is a required"):
        build(text)


def test_gpu_selector_leaves_other_vfio_devices_alone():
    extra = " -device 'vfio-pci,host=0000:05:00.0,id=hostpci1,bus=pcie.0,addr=0x1c'"
    opts, _, _ = build(SAMPLE + extra, gpu=["02:00"])
    other = [v for v in devices(opts, "vfio-pci") if props(v)["host"] == "0000:05:00.0"]
    assert other and props(other[0])["bus"] == "pcie.0"


def test_short_bdf_without_domain_is_normalised():
    text = SAMPLE.replace("host=0000:02:00", "host=02:00")
    opts, _, _ = build(text)
    assert len(devices(opts, "pcie-pci-bridge")) == 1


# ---- large BAR / 64-bit MMIO ---------------------------------------------------
def test_large_mmio64_aperture_default():
    opts, _, _ = build()
    fw = [o.value for o in opts if o.flag == "-fw_cfg"]
    assert fw == ["name=opt/ovmf/X-PciMmio64Mb,string=65536"]


def test_existing_fw_cfg_not_duplicated_but_too_small_fails_check():
    text = SAMPLE + " -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=2048"
    opts, _, cfg = build(text)
    assert len([o for o in opts if o.flag == "-fw_cfg"]) == 1
    assert any("need >=" in p for p in gl.check(opts, cfg))


def test_mmio_off_fails_generation_unless_allowed():
    with pytest.raises(gl.GenError, match="X-PciMmio64Mb"):
        gl.generate(SAMPLE, gl.Config(mmio64_mb=0))
    script, warnings = gl.generate(SAMPLE, gl.Config(mmio64_mb=0, allow_small_mmio=True))
    assert "X-PciMmio64Mb" not in script and any("NOT configured" in w for w in warnings)


def test_non_host_cpu_warns_about_phys_bits():
    _, warnings, _ = build(SAMPLE.replace("-cpu host,", "-cpu EPYC,"))
    assert any("physical-address" in w for w in warnings)


# ---- alternate binary --------------------------------------------------------------
def test_alt_binary_drops_id_and_pve_suffix():
    opts, _, cfg = build(qemu_bin="/opt/qemu-ad/bin/qemu-system-x86_64")
    assert not any(o.flag == "-id" for o in opts)
    assert any(o.flag == "-machine" and "type=q35," in o.value + "," for o in opts)
    assert not any("+pve" in (o.value or "") for o in opts)
    script, _ = gl.generate(SAMPLE, cfg)
    assert "QEMU_BIN=${QEMU_BIN:-/opt/qemu-ad/bin/qemu-system-x86_64}" in script
    assert 'exec -a /usr/bin/kvm "$QEMU_BIN"' in script


def test_stock_binary_keeps_id_and_pve_suffix():
    script, _ = gl.generate(SAMPLE, gl.Config())
    assert "-id 9200" in script and "q35+pve0" in script
    assert "QEMU_BIN=${QEMU_BIN:-/usr/bin/kvm}" in script


def test_qemu_share_emitted_as_L():
    script, _ = gl.generate(SAMPLE, gl.Config(qemu_bin="/opt/q/bin/qemu-system-x86_64",
                                              qemu_share="/opt/q/usr/share/kvm"))
    assert "  -L /opt/q/usr/share/kvm \\" in script


# ---- virtio -> AHCI/e1000e -------------------------------------------------------------
def test_no_virtio_converts_disk_and_nic():
    opts, _, _ = build(no_virtio=True)
    assert not devices(opts, "virtio-scsi-pci") and not devices(opts, "virtio-net-pci")
    assert not any(o.flag == "-object" for o in opts)
    ahci = devices(opts, "ahci")[0]
    hd = devices(opts, "ide-hd")[0]
    assert props(ahci)["bus"] == "pci.3" and props(hd)["bus"] == f"{props(ahci)['id']}.0"
    assert props(hd)["bootindex"] == "100" and props(hd)["drive"] == "drive-scsi0"
    nic = devices(opts, "e1000e")[0]
    assert props(nic)["mac"] == "BC:24:11:00:92:00" and "rx_queue_size" not in props(nic)
    net = [o for o in opts if o.flag == "-netdev"][0]
    assert "vhost" not in net.value


# ---- end to end ------------------------------------------------------------------------
def test_generated_script_is_valid_bash(tmp_path):
    script, _ = gl.generate(SAMPLE, gl.Config(no_virtio=True, qemu_bin="/opt/q/bin/qemu"))
    f = tmp_path / "launch.sh"
    f.write_text(script)
    assert subprocess.run(["bash", "-n", str(f)]).returncode == 0
    assert script.startswith("#!/usr/bin/env bash\n")


def test_cli_stdin_to_stdout():
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "gen-launch.py"), "-"],
                       input=SAMPLE, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert "intel-iommu,intremap=on,caching-mode=on" in r.stdout
    assert "pcie-pci-bridge" in r.stdout


def test_cli_error_exit_code():
    r = subprocess.run([sys.executable, str(ROOT / "tools" / "gen-launch.py"), "-"],
                       input="nonsense", capture_output=True, text=True)
    assert r.returncode == 1 and "error" in r.stderr


def test_idempotent_on_own_topology():
    """Feeding a generated command line back in must not stack bridges."""
    script, _ = gl.generate(SAMPLE, gl.Config())
    # re-extract the exec line as showcmd-like text
    body = script.split('"$QEMU_BIN" \\\n', 1)[1]
    again, _ = gl.generate("/usr/bin/kvm " + body, gl.Config())
    assert again.count("-device pcie-pci-bridge") == 1
    assert again.count("-device intel-iommu") == 1
