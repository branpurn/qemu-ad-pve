import xml.etree.ElementTree as ET

from qad_setup.config import Config
from qad_setup.windows import autounattend, random_password

NS = {"u": "urn:schemas-microsoft-com:unattend"}


def parse(xml):
    return ET.fromstring(xml.split("\n", 1)[1])  # drop the XML declaration line for fromstring


def test_win10_unattend_wellformed_and_escaped():
    c = Config({"l2.windows_iso": "local:iso/w.iso", "l2.timezone": "W. Europe Standard Time"})
    xml = autounattend(c, "p&ss<word>", "aaaaa-bbbbb-ccccc-ddddd-eeeee")
    root = parse(xml)
    passes = [s.get("pass") for s in root.findall("u:settings", NS)]
    assert passes == ["windowsPE", "specialize", "oobeSystem"]
    assert "p&amp;ss&lt;word&gt;" in xml
    vals = [e.text for e in root.iter("{urn:schemas-microsoft-com:unattend}Value")]
    assert "Windows 10 Pro" in vals and "p&ss<word>" in vals
    assert [e.text for e in root.iter("{urn:schemas-microsoft-com:unattend}Key")][-1] == \
        "AAAAA-BBBBB-CCCCC-DDDDD-EEEEE"
    assert "LabConfig" not in xml
    cmd = next(root.iter("{urn:schemas-microsoft-com:unattend}CommandLine")).text
    assert "\\qad\\firstlogon.ps1" in cmd and "ExecutionPolicy Bypass" in cmd
    assert next(root.iter("{urn:schemas-microsoft-com:unattend}TimeZone")).text == "W. Europe Standard Time"


def test_win11_bypass_and_no_key():
    c = Config({"l2.windows_iso": "x:iso/w.iso", "l2.windows_version": "11", "l2.windows_edition": "Windows 11 Pro N"})
    xml = autounattend(c, "pw", "")
    parse(xml)
    assert "BypassTPMCheck" in xml and "BypassSecureBootCheck" in xml
    assert "<ProductKey>" not in xml and "Windows 11 Pro N" in xml


def test_random_password():
    pws = {random_password() for _ in range(20)}
    assert len(pws) == 20
    for pw in pws:
        assert len(pw) == 16 and not set(pw) & set("<>&\"'")
