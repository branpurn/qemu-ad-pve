"""autounattend.xml generator for the Windows L2 (pure; unit-tested for well-formedness).

UNTESTED against a real Windows Setup run in this project. The structure follows Microsoft's
unattend reference (windowsPE / specialize / oobeSystem passes) for an amd64 UEFI install
onto the only disk the L2 has (AHCI, DiskID 0).
"""
from __future__ import annotations

import secrets
import string
from xml.sax.saxutils import escape

from .config import Config

NS = ('xmlns="urn:schemas-microsoft-com:unattend" '
      'xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State"')
COMP = ('processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" '
        'versionScope="nonSxS"')


def random_password(n: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits + "-_.+"
    while True:
        pw = "".join(secrets.choice(alphabet) for _ in range(n))
        if any(c.isdigit() for c in pw) and any(c.isupper() for c in pw) and any(c.islower() for c in pw):
            return pw


def _cmd(order: int, path: str, tag: str = "RunSynchronousCommand") -> str:
    return (f'<{tag} wcm:action="add"><Order>{order}</Order><Path>{escape(path)}</Path></{tag}>')


def autounattend(cfg: Config, admin_password: str, product_key: str = "") -> str:
    loc = escape(cfg["l2.locale"])
    user = escape(cfg["l2.admin_user"])
    pw = escape(admin_password)
    edition = escape(cfg.edition())
    intl_pe = (f'<component name="Microsoft-Windows-International-Core-WinPE" {COMP}>'
               f'<SetupUILanguage><UILanguage>{loc}</UILanguage></SetupUILanguage>'
               f'<InputLocale>{loc}</InputLocale><SystemLocale>{loc}</SystemLocale>'
               f'<UILanguage>{loc}</UILanguage><UserLocale>{loc}</UserLocale></component>')
    bypass = ""
    if cfg["l2.windows_version"] == "11":
        # The L2 has no vTPM and no Secure Boot (Debian OVMF_CODE_4M, not .secboot).
        cmds = [_cmd(i + 1, f"reg add HKLM\\SYSTEM\\Setup\\LabConfig /v {v} /t REG_DWORD /d 1 /f")
                for i, v in enumerate(("BypassTPMCheck", "BypassSecureBootCheck", "BypassRAMCheck"))]
        bypass = "<RunSynchronous>" + "".join(cmds) + "</RunSynchronous>"
    # No key: an EMPTY <Key/> is still required. Without any <ProductKey> element, Setup from the
    # retail multi-edition Win10 22H2 ISO stops at "Windows cannot read the <ProductKey> setting from
    # the unattend answer file" (live E2E 2026-10-06). The edition comes from /IMAGE/NAME below;
    # Windows is then installed unactivated.
    key = (f"<ProductKey><Key>{escape(product_key.upper())}</Key>"
           "<WillShowUI>OnError</WillShowUI></ProductKey>")
    disk = ('<DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>'
            '<CreatePartitions>'
            '<CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>260</Size></CreatePartition>'
            '<CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>'
            '<CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend>'
            '</CreatePartition></CreatePartitions><ModifyPartitions>'
            '<ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format>'
            '<Label>System</Label></ModifyPartition>'
            '<ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>'
            '<ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format>'
            '<Label>Windows</Label><Letter>C</Letter></ModifyPartition>'
            '</ModifyPartitions></Disk></DiskConfiguration>')
    image = ('<ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/NAME</Key>'
             f'<Value>{edition}</Value></MetaData></InstallFrom>'
             '<InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo></OSImage></ImageInstall>')
    setup = (f'<component name="Microsoft-Windows-Setup" {COMP}>{bypass}{disk}{image}'
             f'<UserData><AcceptEula>true</AcceptEula>{key}</UserData></component>')
    specialize = (f'<component name="Microsoft-Windows-Shell-Setup" {COMP}>'
                  f'<ComputerName>{escape(cfg["l2.computer_name"])}</ComputerName>'
                  f'<TimeZone>{escape(cfg["l2.timezone"])}</TimeZone></component>'
                  f'<component name="Microsoft-Windows-Deployment" {COMP}><RunSynchronous>'
                  + _cmd(1, "reg add HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\OOBE /v BypassNRO "
                            "/t REG_DWORD /d 1 /f")
                  + "</RunSynchronous></component>")
    firstlogon = ("cmd /c for %d in (D E F G H I J K L M N O P Q R S T U V W X Y Z) do @if exist "
                  "%d:\\qad\\firstlogon.ps1 powershell -NoProfile -ExecutionPolicy Bypass -File "
                  "%d:\\qad\\firstlogon.ps1")
    oobe = (f'<component name="Microsoft-Windows-International-Core" {COMP}>'
            f'<InputLocale>{loc}</InputLocale><SystemLocale>{loc}</SystemLocale>'
            f'<UILanguage>{loc}</UILanguage><UserLocale>{loc}</UserLocale></component>'
            f'<component name="Microsoft-Windows-Shell-Setup" {COMP}>'
            '<OOBE><HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>'
            '<HideOnlineAccountScreens>true</HideOnlineAccountScreens>'
            '<HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>'
            '<HideLocalAccountScreen>true</HideLocalAccountScreen><ProtectYourPC>3</ProtectYourPC></OOBE>'
            '<UserAccounts><LocalAccounts><LocalAccount wcm:action="add">'
            f'<Name>{user}</Name><DisplayName>{user}</DisplayName><Group>Administrators</Group>'
            f'<Password><Value>{pw}</Value><PlainText>true</PlainText></Password>'
            '</LocalAccount></LocalAccounts></UserAccounts>'
            f'<AutoLogon><Enabled>true</Enabled><Username>{user}</Username><LogonCount>1</LogonCount>'
            f'<Password><Value>{pw}</Value><PlainText>true</PlainText></Password></AutoLogon>'
            '<FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order>'
            f'<CommandLine>{escape(firstlogon)}</CommandLine>'
            '<Description>qemu-ad-pve first logon</Description><RequiresUserInput>false</RequiresUserInput>'
            '</SynchronousCommand></FirstLogonCommands></component>')
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            f'<!-- Generated by qemu-ad-pve setup.sh. Contains the L2 admin password: deleted from L1 after Setup. -->\n'
            f'<unattend {NS}>\n'
            f'<settings pass="windowsPE">{intl_pe}{setup}</settings>\n'
            f'<settings pass="specialize">{specialize}</settings>\n'
            f'<settings pass="oobeSystem">{oobe}</settings>\n'
            '</unattend>\n')
