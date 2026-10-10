"""scripts/bare-metal-audit: the evaluator against the setup defaults (facts = the live phase-E/F/G result)."""
import importlib.util
import os
import subprocess

from qad_setup import config, plan
from qad_setup.hostinfo import Gpu, PciFunc

ROOT = os.path.join(os.path.dirname(__file__), "..", "..")
AUD = os.path.join(ROOT, "scripts", "bare-metal-audit")
spec = importlib.util.spec_from_file_location("bm_evaluate", os.path.join(AUD, "evaluate.py"))
ev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ev)


def default_env(**sets):
    cfg = config.parse_ini("")
    for k, v in sets.items():
        cfg.set(k.replace("__", "."), v)
    gpu = Gpu("0000:02:00", [PciFunc("0000:02:00.0", "10de", "2704", "0300", "vfio-pci", "13"),
                              PciFunc("0000:02:00.1", "10de", "22bb", "0403", "vfio-pci", "13")])
    text = plan.l1_env(cfg, "iid", "9320", gpu, "amd")
    path = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"bm-env-{os.getpid()}.txt")
    open(path, "w").write(text)
    env = ev.parse_env(path)
    os.unlink(path)
    return env


def good_facts(env):
    s = ev.smbios_fields(default_env()["QAD_L2_SMBIOS"])
    f = {
        "l1.detect_virt": "none", "l1.cpuinfo_hypervisor_flag": "0", "l1.dmi.sys_vendor": "ASUS",
        "l1.dmi.chassis_type": "3", "l1.dmi.bios_vendor": "American Megatrends Inc.", "l1.kvm_dev": "present", "l1.qemu_optpatches": "0001-acpi-omit-waet,0002-acpi-oem-id-table-id-revision,0003-atapi-inquiry-from-model",
        "cs.manufacturer": "ASUS", "cs.model": "System Product Name", "cs.hypervisor_present": "False",
        "bios.manufacturer": s[0]["vendor"], "bios.version": s[0]["version"], "bios.date": s[0]["date"],
        "board.manufacturer": s[2]["manufacturer"], "board.product": s[2]["product"],
        "enclosure.manufacturer": "ASUSTeK COMPUTER INC.", "enclosure.chassis_types": "3",
        "cpu.name": s[4]["version"], "cpu.socket": "AM5 0",
        "dimm.0.manufacturer": s[17]["manufacturer"], "dimm.0.part": s[17]["part"],
        "disk.0.model": env["QAD_L2_DISK_MODEL"], "disk.0.firmware": env["QAD_L2_DISK_FW"],
        "nic.0.mac": env["QAD_L2_MAC"].upper().replace(":", "-"),
        "video.0.name": "NVIDIA GeForce RTX 4080", "video.0.code": "0", "systeminfo.hypervisor_lines": "0",
        "cdrom.0.name": env["QAD_L2_CDROM_MODEL"], "cdrom.0.media": "False",
        "residue.unattend": "", "residue.staging": "", "cpuid.hypervisor_bit": "0", "cpuid.leaf40000000": "0x0,0x0,0x0,0x0",
        "acpi.tables": "MCFG,FACP,APIC,HPET,BGRT",
        "reg.SystemBiosVersion": "ALASKA - 1072009 ; 1654 ; American Megatrends International, LLC. - 5001B",
    }
    for i, t in enumerate(f["acpi.tables"].split(",")):
        f[f"acpi.{i}"] = f"{t}|ALASKA|A M I|0x1072009"
    return f


def test_smbios_blob_parsing_handles_double_comma():
    env = default_env()
    s = ev.smbios_fields(env["QAD_L2_SMBIOS"])
    assert s[4]["manufacturer"] == "Advanced Micro Devices, Inc."
    assert s[0]["vendor"] == "American Megatrends Inc." and s[17]["part"] == "KF560C40-16"


def test_defaults_expect_everything_hidden_and_good_facts_pass():
    env = default_env()
    assert env["QAD_L1_BARE_METAL"] == "1" and "-hypervisor" in env["QAD_L2_CPU"]
    r = ev.evaluate(env, good_facts(env))
    assert not r.failed, [x for x in r.rows if x[0] == "FAIL"]
    names = " ".join(x[1] for x in r.rows)
    for need in ("systemd-detect-virt", "WAET", "OEM id", "SMBIOS 3 chassis type", "NIC MAC", "disk model", "SystemBiosVersion"):
        assert need in names, need


def test_each_regression_is_a_fail():
    env = default_env()
    for key, val, label in [
        ("cpuid.hypervisor_bit", "1", "CPUID leaf1"),
        ("cs.hypervisor_present", "True", "HypervisorPresent"),
        ("acpi.tables", "MCFG,WAET", "WAET"),
        ("acpi.1", "FACP|BOCHS|BXPC|0x1", "OEM"),
        ("enclosure.chassis_types", "1", "chassis type"),
        ("nic.0.mac", "52-54-00-AA-BB-CC", "MAC"),
        ("disk.0.model", "QEMU HARDDISK", "disk model"),
        ("reg.SystemBiosVersion", "BOCHS - 1 ; 1654 ; EDK II", "SystemBiosVersion"),
        ("l1.detect_virt", "qemu", "systemd-detect-virt"),
        ("video.0.code", "43", "GPU problem code"),
        ("cdrom.0.name", "ASUS ASUS DVD-ROM", "optical drive model"),
        ("cdrom.0.media", "True", "staging ISO detached"),
        ("residue.unattend", "C:\\Windows\\Panther\\unattend.xml", "Answer-file residue"),
        ("residue.staging", "nvidia,firstlogon.ps1", "Staging residue"),
    ]:
        f = good_facts(env)
        f[key] = val
        r = ev.evaluate(env, f)
        assert any(x[0] == "FAIL" and label in x[1] for x in r.rows), (key, r.rows)


def test_opt_outs_are_not_failures():
    env = default_env(l2__optional_patches="none", l2__ovmf_identity="no", l2__smbios="none", l1__smbios="none")
    f = good_facts(env)
    f.update({"acpi.tables": "MCFG,FACP,WAET", "reg.SystemBiosVersion": "BOCHS - 1 ; EDK II", "cs.manufacturer": "QEMU",
              "cs.model": "Standard PC", "l1.detect_virt": "qemu", "l1.dmi.sys_vendor": "QEMU"})
    r = ev.evaluate(env, f)
    assert not r.failed, [x for x in r.rows if x[0] == "FAIL"]


def test_cdrom_model_is_info_when_qemu_lacks_patch_0003():
    env = default_env()
    f = good_facts(env)
    f.update({"l1.qemu_optpatches": "0001-acpi-omit-waet,0002-acpi-oem-id-table-id-revision", "cdrom.0.name": "ASUS ASUS DVD-ROM"})
    r = ev.evaluate(env, f)
    assert not r.failed
    assert any(x[0] == "INFO" and "optical drive model" in x[1] for x in r.rows)


def test_residue_opt_out_is_info():
    env = default_env(l2__cleanup_unattend="no", l2__cleanup_staging="no")
    f = good_facts(env)
    f.update({"residue.unattend": "C:\\Windows\\Panther\\unattend.xml", "residue.staging": "nvidia"})
    r = ev.evaluate(env, f)
    assert not r.failed
    assert [x[0] for x in r.rows if "residue" in x[1]] == ["INFO", "INFO"]


def test_l2_unreachable_is_skip_not_pass_or_fail():
    env = default_env()
    r = ev.evaluate(env, {"l1.detect_virt": "none", "l1.cpuinfo_hypervisor_flag": "0", "l1.dmi.sys_vendor": "ASUS",
                          "l1.dmi.chassis_type": "3", "l1.dmi.bios_vendor": "American Megatrends Inc.", "l1.kvm_dev": "present"})
    assert any(x[0] == "SKIP" for x in r.rows) and not r.failed


def test_scripts_syntax_and_wiring():
    for sh in ("audit.sh", "l1-facts.sh"):
        assert subprocess.run(["bash", "-n", os.path.join(AUD, sh)]).returncode == 0
    l1 = open(os.path.join(ROOT, "setup", "l1", "qad-l1.sh")).read()
    assert "audit) step_audit ;;" in l1 and "l2_scp()" in l1
    steps = open(os.path.join(ROOT, "setup", "qad_setup", "steps.py")).read()
    assert "scripts/bare-metal-audit" in steps
    assert "scripts/bare-metal-audit/*.sh" in steps
