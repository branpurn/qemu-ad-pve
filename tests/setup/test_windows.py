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
    assert "Windows 11 Pro N" in xml
    # no key -> empty <Key/> (a missing <ProductKey> stops Setup: live E2E 2026-10-06)
    pk = next(parse(xml).iter("{urn:schemas-microsoft-com:unattend}ProductKey"))
    assert pk.find("u:Key", NS) is not None and not (pk.find("u:Key", NS).text or "")


def test_random_password():
    pws = {random_password() for _ in range(20)}
    assert len(pws) == 20
    for pw in pws:
        assert len(pw) == 16 and not set(pw) & set("<>&\"'")


def test_firstlogon_fixes_host_key_owner_before_starting_sshd():
    """Live E2E 2026-10-06: `ssh-keygen -A` from the admin session leaves the private host keys owned
    by the user; sshd (LocalSystem) then refuses to start. The keys must be re-owned before Start-Service
    and success must only be reported when the service is actually running."""
    from pathlib import Path
    ps1 = (Path(__file__).resolve().parents[2] / "setup/l1/windows/firstlogon.ps1").read_text()
    fix = ps1.index("/setowner '*S-1-5-32-544'")
    assert ps1.index("ssh-keygen.exe') -A") < fix < ps1.index("Start-Service sshd")
    assert "/remove:g" in ps1 and "/inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F'" in ps1
    ok = ps1.index("Write-Output 'sshd running, key-only access for L1'")
    assert "if ($sshdUp)" in ps1[ps1.index("Start-Service sshd"):ok]
