import pytest

from conftest import REPO
from qad_setup.config import (Config, ConfigError, cross_validate, l2_addresses, norm_slot, parse_downloads,
                              parse_ini)


def test_defaults_are_valid_except_missing_iso():
    cfg = Config()
    assert cfg["l1.vmid"] == "auto"
    assert cfg.int("gpu.mmio64_mb") == 65536
    assert cfg.edition() == "Windows 10 Pro"
    assert cross_validate(cfg) == ["l2.source=iso needs l2.windows_iso (PVE volid like local:iso/Win10.iso or a path)"]


def test_example_config_parses_and_validates():
    cfg = parse_ini((REPO / "setup/config.example.ini").read_text(), "example")
    assert cross_validate(cfg) == []


def test_parse_ini_normalises_and_rejects_unknown():
    cfg = parse_ini("[l1]\nvmid = 9300\nonboot = TRUE\n[gpu]\nslot = 01:00\n")
    assert cfg["l1.vmid"] == "9300" and cfg["l1.onboot"] == "yes"
    assert cfg["gpu.slot"] == "0000:01:00"
    assert {"l1.vmid", "l1.onboot", "gpu.slot"} <= cfg.explicit
    with pytest.raises(ConfigError, match="unknown setting"):
        parse_ini("[l1]\nvmidd = 1\n")
    with pytest.raises(ConfigError, match="inside a"):
        parse_ini("[DEFAULT]\nx = 1\n")


@pytest.mark.parametrize("key,value,msg", [
    ("l1.vmid", "99", "VMID"),
    ("l1.memory_mb", "1024", "minimum"),
    ("l1.memory_mb", "12G", "whole number"),
    ("l2.source", "vhd", "one of"),
    ("l1.ip", "192.168.1.5", "prefix length"),
    ("l1.ip", "fe80::1/64", "IPv4"),
    ("l2.net_cidr", "10.0.0.0/30", "too small"),
    ("l2.image", "relative.qcow2", "absolute"),
    ("gpu.slot", "01:00.0", "no function"),
])
def test_bad_values(key, value, msg):
    with pytest.raises(ConfigError, match=msg):
        Config().set(key, value)


def test_cross_validation():
    cfg = Config({"l2.windows_iso": "local:iso/w.iso", "l1.ip": "10.0.0.5/24", "l1.memory_mb": "8192",
                  "l2.memory_mb": "6144", "l2.cores": "16", "l2.product_key": "abc",
                  "l2.computer_name": "this-name-is-way-too-long", "l2.admin_password": "a<b"})
    problems = "\n".join(cross_validate(cfg))
    for needle in ("l1.gateway", "l1.memory_mb", "l2.cores", "product_key", "computer_name", "admin_password"):
        assert needle in problems


def test_image_source_needs_image():
    cfg = Config({"l2.source": "image"})
    assert any("l2.image" in p for p in cross_validate(cfg))
    cfg.set("l2.image", "/var/lib/vz/images/win.qcow2")
    assert cross_validate(cfg) == []


def test_downloads_parsing():
    sha = "a" * 64
    got = parse_downloads(f"https://example.com/d/driver.exe {sha}; https://x.org/y {sha} y.whl")
    assert got == [("https://example.com/d/driver.exe", sha, "driver.exe"), ("https://x.org/y", sha, "y.whl")]
    for bad in ("http://insecure/x " + sha, "https://x/y deadbeef", "https://x/y " + sha + " ../evil", "onlyurl"):
        with pytest.raises(ConfigError):
            parse_downloads(bad)


def test_secrets_never_written_back():
    cfg = Config({"l2.windows_iso": "local:iso/w.iso", "l2.admin_password": "S3cret!x",
                  "l2.product_key": "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"})
    ini = cfg.to_ini()
    assert "S3cret" not in ini and "AAAAA" not in ini
    assert parse_ini(ini)["l2.windows_iso"] == "local:iso/w.iso"


def test_stage_files_and_l2_addresses():
    cfg = Config({"stage.nvidia_driver": "/root/nv.exe", "stage.extra_files": "/a, /b"})
    assert cfg.stage_files() == [("nvidia_driver", "/root/nv.exe"), ("extra", "/a"), ("extra", "/b")]
    assert l2_addresses("10.254.77.0/24") == ("10.254.77.1", "10.254.77.10", "10.254.77.252", "10.254.77.253")
    assert norm_slot("0000:0E:00") == "0000:0e:00"


@pytest.mark.parametrize("key,val,frag", [
    ("mac_oui", "A4:BF:01", "mac_oui"), ("mac_oui", "01:00:5e", "unicast"), ("mac_oui", "a4:bf", "mac_oui"),
    ("disk_model", "x,y", "disk_model"), ("smbios", "qemu", "smbios"), ("vga", "qxl", "vga"),
    ("gpu_link_speed", "3", "gpu_link_speed"), ("gpu_link_width", "3", "gpu_link_width"),
])
def test_l2_identity_rejects_bad_values(key, val, frag):
    probs = cross_validate(Config({"l2." + key: val, "l2.windows_iso": "local:iso/w.iso"}))
    assert any(frag in p for p in probs), probs


def test_l2_identity_defaults_valid():
    assert cross_validate(Config({"l2.windows_iso": "local:iso/w.iso"})) == []
    assert cross_validate(Config({"l2.windows_iso": "local:iso/w.iso", "l2.mac_oui": "", "l2.disk_model": "",
                                  "l2.smbios": "none", "l2.vga": "none"})) == []


def test_l1_identity_keys_defaults_and_validation():
    c = Config({})
    assert c["l2.smbios_chassis"] == "desktop"
    assert c["l1.smbios"] == "asus-am5" and c.bool("l1.hide_hypervisor")
    with pytest.raises(ConfigError):
        Config({"l1.smbios": "qemu"})


def test_optional_identity_keys_default_on_and_validate():
    base = {"l2.windows_iso": "local:iso/w.iso"}
    c = Config(base)
    assert [c["l2." + k] for k in ("optional_patches", "oem_id", "oem_table_id", "oem_revision",
                                   "ovmf_identity", "ovmf_identity_dir")] == [
        "0001-acpi-omit-waet,0002-acpi-oem-id-table-id-revision,0003-atapi-inquiry-from-model", "ALASKA", "A M I", "0x1072009", "yes", ""]
    assert cross_validate(c) == []
    assert cross_validate(Config(dict(base, **{"l2.optional_patches": "none", "l2.ovmf_identity": "no"}))) == []
    assert any("ovmf_identity" in p for p in cross_validate(Config(dict(base, **{"l2.ovmf_identity": "maybe"}))))
    ok = dict(base, **{"l2.optional_patches": "0001-acpi-omit-waet,0002-acpi-oem-id-table-id-revision",
                       "l2.oem_id": "ALASKA", "l2.oem_table_id": "A M I", "l2.oem_revision": "0x1072009"})
    assert cross_validate(Config(ok)) == []
    for k, v, frag in [("l2.optional_patches", "bad name;rm", "bad patch name"), ("l2.oem_id", "TOOLONGID", "oem_id"),
                       ("l2.oem_table_id", "A,M", "oem_table_id"), ("l2.oem_revision", "1072009", "hex")]:
        probs = cross_validate(Config(dict(ok, **{k: v})))
        assert any(frag in p for p in probs), (k, probs)
