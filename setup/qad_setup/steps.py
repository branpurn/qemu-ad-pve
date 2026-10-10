"""Install steps (host side + L1 over SSH). Each step is idempotent; progress is kept in the
state file so `setup.sh install` resumes where it stopped."""
from __future__ import annotations

import hashlib
import json
from urllib.parse import unquote
import os
import re
import shlex
import tempfile
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from . import hostinfo as hi
from . import plan, ui
from .config import Config
from .manifest import Manifest, vm_marker
from .runner import CommandError, Runner, sha256_file
from .state import DONE, FAILED, RUNNING, SKIPPED, State
from .windows import autounattend, random_password

L1_REPO = "/root/qemu-ad-pve"
L1_QAD = f"{L1_REPO}/setup/l1/qad-l1.sh"
PAYLOAD = ["dkms/Makefile", "dkms/dkms.conf", "dkms/fetch-kvm-source.sh", "dkms/patches", "dkms/scripts",
           "dkms/README.md", "scripts/l1-w10", "scripts/qm-native-9200", "scripts/ovmf-identity", "scripts/bare-metal-audit", "patches/optional", "setup/l1", "tests/w10-code43-check.ps1",
           "tests/w10-code43-run.sh", "qemu-ad-pve.sh", "LICENSE"]


class StepError(RuntimeError):
    pass


@dataclass
class Ctx:
    cfg: Config
    runner: Runner
    state: State
    manifest: Manifest
    prompter: ui.Prompter
    repo: str
    state_dir: str
    gpu: Optional[hi.Gpu] = None
    cpu_vendor: str = "amd"
    iso_label: str = ""
    host_qemu_ad: str = ""
    download_proprietary: bool = False
    wipe_l2_disk: bool = False
    extra: Dict[str, str] = field(default_factory=dict)

    # ---------------------------------------------------------------- paths / facts
    @property
    def dry(self) -> bool:
        return self.runner.dry_run

    @property
    def vmid(self) -> str:
        return self.cfg["l1.vmid"]

    @property
    def key(self) -> str:
        return os.path.join(self.state_dir, "ssh", "id_ed25519")

    @property
    def known_hosts(self) -> str:
        return os.path.join(self.state_dir, "ssh", "known_hosts")

    def image_path(self) -> str:
        if self.cfg["l1.debian_image"]:
            return self.cfg["l1.debian_image"]
        name = self.cfg["l1.debian_image_url"].rstrip("/").rsplit("/", 1)[-1]
        return os.path.join(self.state_dir, "cache", name)

    def l1_ip(self) -> str:
        return self.state.facts.get("l1_ip", "<L1-IP>")

    # ---------------------------------------------------------------- ssh into L1
    def _ssh_strict(self) -> str:
        return "yes" if self.state.facts.get("hostkey_pinned") == "yes" else "accept-new"

    def ssh_argv(self, remote: str, ip: Optional[str] = None) -> List[str]:
        return ["ssh", "-i", self.key, "-o", "BatchMode=yes", "-o", f"StrictHostKeyChecking={self._ssh_strict()}",
                "-o", f"UserKnownHostsFile={self.known_hosts}", "-o", "ConnectTimeout=10",
                "-o", "ServerAliveInterval=30", "-o", "LogLevel=ERROR", f"root@{ip or self.l1_ip()}", remote]

    def scp_argv(self, *extra: str) -> List[str]:
        """scp with the same host-key policy as ssh_argv (pinned -> yes, else accept-new)."""
        return ["scp", "-q", "-i", self.key, "-o", "BatchMode=yes",
                "-o", f"UserKnownHostsFile={self.known_hosts}",
                "-o", f"StrictHostKeyChecking={self._ssh_strict()}", *extra]

    def ssh(self, remote: str, desc: str = "", check: bool = True, stream: bool = False,
            input_text: Optional[str] = None, timeout: Optional[int] = None, change: bool = True):
        shown = f"[L1 {self.l1_ip()}] {remote}" + (" <<< (stdin)" if input_text is not None else "")
        return self.runner.run(self.ssh_argv(remote), desc=desc, check=check, stream=stream,
                               input_text=input_text, timeout=timeout, change=change, display=shown)

    def ssh_probe(self, remote: str, timeout: int = 60):
        if self.dry:
            return None
        return self.runner.probe(self.ssh_argv(remote), timeout=timeout)

    def l1(self, step: str, stream: bool = True, check: bool = True, timeout: Optional[int] = None):
        return self.ssh(f"{L1_QAD} {step}", desc=f"in L1: {step}", stream=stream, check=check, timeout=timeout)


# ==================================================================== host steps
def s_host_dirs(c: Ctx) -> str:
    for sub in ("", "ssh", "cache", "logs"):
        d = os.path.join(c.state_dir, sub) if sub else c.state_dir
        created = c.runner.mkdir(d)
        if created and not c.dry:
            c.manifest.add("dir", path=d)
    return c.state_dir


def s_ssh_key(c: Ctx) -> str:
    if os.path.exists(c.key) and os.path.exists(c.key + ".pub"):
        return "exists"
    c.runner.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", f"qemu-ad-pve-setup@{c.vmid}", "-f", c.key],
                 desc="dedicated key for setup.sh -> L1 (never used elsewhere)")
    if not c.dry:
        c.manifest.add("file", path=c.key, sha256=sha256_file(c.key) or "")
        c.manifest.add("file", path=c.key + ".pub", sha256=sha256_file(c.key + ".pub") or "")
    return c.key


def _download(c: Ctx, url: str, dest: str) -> None:
    # Bounded connect/read timeouts: on the live E2E host (2026-10-06) one of cloud.debian.org's mirror
    # addresses dropped SYNs and wget's default (kernel SYN retries, ~2 min per attempt) stalled each
    # download for minutes before it fell over to the next address.
    if os.path.exists("/usr/bin/wget") or c.dry:
        c.runner.run(["wget", "-q", "--timeout=30", "--tries=5", "-O", dest, url], desc="download", timeout=3600)
    else:
        c.runner.run(["curl", "-fsSL", "--connect-timeout", "30", "--retry", "5", "-o", dest, url],
                     desc="download", timeout=3600)


def s_debian_image(c: Ctx) -> str:
    if c.cfg["l1.debian_image"]:
        return f"using {c.cfg['l1.debian_image']}"
    url = c.cfg["l1.debian_image_url"]
    dest = c.image_path()
    name = os.path.basename(dest)
    sums_url = url.rsplit("/", 1)[0] + "/SHA512SUMS"
    sums = dest + ".SHA512SUMS"
    _download(c, sums_url, sums)
    want = None
    if not c.dry:
        for line in open(sums, encoding="utf-8"):
            parts = line.split()
            if len(parts) == 2 and parts[1].lstrip("*") == name:
                want = parts[0]
        if not want:
            raise StepError(f"{name} is not listed in {sums_url}")
    if not c.dry and os.path.exists(dest) and _sha512(dest) == want:
        c.manifest.add("file", path=sums, sha256=sha256_file(sums) or "")
        return f"cached {dest}"
    _download(c, url, dest + ".part")
    if not c.dry:
        got = _sha512(dest + ".part")
        if got != want:
            os.unlink(dest + ".part")
            raise StepError(f"SHA512 mismatch for {url}: got {got}, want {want}")
        os.replace(dest + ".part", dest)
        c.manifest.add("file", path=dest, sha256=sha256_file(dest) or "")
        c.manifest.add("file", path=sums, sha256=sha256_file(sums) or "")
    return f"{dest} (SHA512 verified against {sums_url})"


def _sha512(path: str) -> str:
    import hashlib
    h = hashlib.sha512()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def _storage_path(c: Ctx, volid: str) -> str:
    p = c.runner.probe(["pvesm", "path", volid])
    if p.returncode != 0 or not p.stdout.strip():
        if c.dry:
            return f"<path of {volid}>"
        raise StepError(f"pvesm path {volid} failed: {p.stderr.strip()}")
    return p.stdout.strip()


def s_seed_iso(c: Ctx) -> str:
    volid = f"{c.cfg['l1.iso_storage']}:iso/{plan.seed_volname(c.vmid)}"
    path = _storage_path(c, volid)
    pub = "<generated public key>" if c.dry and not os.path.exists(c.key + ".pub") else open(c.key + ".pub").read()
    host = plan.hostname_for(c.cfg)
    files = {"user-data": plan.user_data(pub, host), "meta-data": plan.meta_data(c.manifest.install_id, host)}
    net = plan.network_config(c.cfg)
    if net:
        files["network-config"] = net
    if c.dry:
        for n, content in files.items():
            c.runner.write_file(f"<tmp>/{n}", content, desc="cloud-init NoCloud seed")
        c.runner.run(["genisoimage", "-quiet", "-output", path, "-volid", "cidata", "-joliet", "-rock", "<tmp>"],
                     desc=f"seed ISO {volid}")
        return volid
    with tempfile.TemporaryDirectory() as tmp:
        for n, content in files.items():
            with open(os.path.join(tmp, n), "w", encoding="utf-8") as fh:
                fh.write(content)
        c.runner.run(["genisoimage", "-quiet", "-output", path + ".tmp", "-volid", "cidata", "-joliet", "-rock"]
                     + [os.path.join(tmp, n) for n in files], desc=f"seed ISO {volid}")
    os.replace(path + ".tmp", path)
    c.manifest.add("volume", volid=volid, path=path, sha256=sha256_file(path) or "")
    c.state.facts["seed_volid"] = volid
    return volid


def s_hookscript(c: Ctx) -> str:
    if c.cfg["l1.hookscript"] != "yes":
        raise _Skip("GPU guard disabled (l1.hookscript=no): nothing stops a hostpci VM from taking the GPU")
    volid = f"{c.cfg['l1.snippets_storage']}:snippets/{plan.hook_volname(c.vmid)}"
    path = _storage_path(c, volid)
    tmpl = open(os.path.join(c.repo, plan.GUARD_TEMPLATE), encoding="utf-8").read()
    digest = c.runner.write_file(path, plan.hookscript(tmpl, c.vmid, c.gpu), mode=0o755,
                                 desc="qm-native-9200 GPU guard: vfio-pci check + qemu-server PCI reservation")
    if not c.dry:
        c.manifest.add("volume", volid=volid, path=path, sha256=digest)
    c.state.facts["hook_volid"] = volid
    return volid


def s_l1_smbios(c: Ctx) -> str:
    """Raw SMBIOS type 0/3 structures for the L1 (QEMU cannot clear the 'virtual machine' BIOS bit or set
    the chassis type with -smbios fields); they are referenced from the L1 `args:` as -smbios file=..."""
    if c.cfg["l1.smbios"] != "asus-am5":
        raise _Skip("l1.smbios=none: the L1 keeps QEMU's/Proxmox's default DMI (systemd-detect-virt says qemu)")
    d = os.path.join(c.state_dir, "smbios")
    if c.runner.mkdir(d) and not c.dry:
        c.manifest.add("dir", path=d)
    for name, blob in plan.l1_smbios_files(c.vmid).items():
        path = os.path.join(d, name)
        digest = c.runner.write_file(path, blob, desc="L1 SMBIOS structure (raw, QEMU -smbios file=)")
        if not c.dry:
            c.manifest.add("file", path=path, sha256=digest)
    c.state.facts["smbios_dir"] = d
    return d


def _vm_conf(c: Ctx) -> Optional[Dict[str, str]]:
    p = c.runner.probe(["qm", "config", c.vmid])
    if p.returncode != 0:
        return None
    return hi.parse_vm_conf(p.stdout)


def s_vm_create(c: Ctx) -> str:
    seed = c.state.facts.get("seed_volid") or f"{c.cfg['l1.iso_storage']}:iso/{plan.seed_volname(c.vmid)}"
    hook = c.state.facts.get("hook_volid") if c.cfg["l1.hookscript"] == "yes" else None
    cmds = plan.qm_create(c.cfg, c.vmid, c.manifest.install_id, c.gpu, c.image_path(), seed, hook,
                          c.state.facts.get("smbios_dir") or os.path.join(c.state_dir, "smbios"))
    conf = None if c.dry else _vm_conf(c)
    marker = vm_marker(c.manifest.install_id)
    if conf is not None and marker not in unquote(conf.get("description", "")):
        raise StepError(f"VM {c.vmid} exists and was not created by this setup run; refusing to touch it")
    if conf is None:
        c.runner.run(cmds[0], desc="create the L1 VM", timeout=1800)
        if not c.dry:
            c.manifest.add("vm", vmid=c.vmid, marker=marker)
            c.manifest.save()
        conf = {} if c.dry else (_vm_conf(c) or {})
    for cmd in cmds[1:]:
        if cmd[1] == "set":
            disk = cmd[3].lstrip("-")
            if disk in conf:
                ui.info(f"{disk} already configured: {conf[disk]}")
                continue
        c.runner.run(cmd, desc="L1 disk", timeout=7200)
    if not c.dry:
        net0 = (_vm_conf(c) or {}).get("net0", "")
        c.state.facts["l1_mac"] = hi.parse_net0_mac(net0) or ""
    return f"VM {c.vmid}"


def s_vm_start(c: Ctx) -> str:
    st = c.runner.probe(["qm", "status", c.vmid]).stdout
    if "running" in st:
        return "already running"
    if c.gpu and not c.dry:
        running = {v for v, (_, s) in hi.parse_qm_list(c.runner.probe(["qm", "list"]).stdout).items() if s == "running"}
        busy = [r.vmid for r in c.gpu.refs if r.vmid in running and r.vmid != c.vmid]
        if busy:
            raise StepError(f"GPU {c.gpu.slot} is in use by running VM(s) {', '.join(busy)}; shut them down "
                            f"(qm shutdown {busy[0]}) and re-run setup.sh install")
    c.runner.run(["qm", "start", c.vmid, "--timeout", "300"], desc="boot L1 (GPU + Intel vIOMMU)", timeout=400)
    return "started"


def s_l1_ip(c: Ctx) -> str:
    static = c.cfg["l1.ip"].split("/")[0] if c.cfg["l1.ip"] != "dhcp" else ""
    if c.dry:
        ui.info("would poll `qm guest cmd <vmid> network-get-interfaces` (qemu-guest-agent from cloud-init)")
        return static or "<L1-IP>"
    # The guest agent is installed by cloud-init; wait for it even with a static IP, because the
    # SSH host key is read through it below.
    deadline = time.time() + 1200
    mac = c.state.facts.get("l1_mac")
    ip = ""
    while True:
        p = c.runner.probe(["qm", "guest", "cmd", c.vmid, "network-get-interfaces"], timeout=30)
        if p.returncode == 0:
            ips = hi.parse_guest_ifaces(p.stdout, mac)
            ip = static or (ips[0] if ips else "")
            if ip:
                break
        if time.time() > deadline:
            raise StepError("L1 did not report an IP via the guest agent within 20 min (cloud-init still running? "
                            f"check the L1 console: qm terminal {c.vmid})")
        time.sleep(10)
    c.state.facts["l1_ip"] = ip
    # Pin L1's SSH host key, read through the guest agent (no trust-on-first-use).
    p = c.runner.probe(["qm", "guest", "exec", c.vmid, "--", "cat", "/etc/ssh/ssh_host_ed25519_key.pub"], timeout=60)
    try:
        key = json.loads(p.stdout).get("out-data", "").split()
        if len(key) >= 2 and key[0] == "ssh-ed25519":
            c.runner.write_file(c.known_hosts, f"{ip} {key[0]} {key[1]}\n", mode=0o600, desc="pinned L1 host key")
            c.manifest.add("file", path=c.known_hosts, volatile="1")
            c.state.facts["hostkey_pinned"] = "yes"
    except ValueError:
        ui.warn("could not read L1's host key via the guest agent; falling back to accept-new")
    return ip


def s_l1_ssh(c: Ctx) -> str:
    if c.dry:
        c.ssh("cloud-init status --wait", desc="wait for cloud-init", change=False)
        return "dry"
    deadline = time.time() + 900
    while True:
        p = c.ssh_probe("cloud-init status --wait >/dev/null 2>&1; cloud-init status", timeout=900)
        if p is not None and p.returncode in (0, 2) and "status:" in p.stdout:
            if "error" in p.stdout:
                ui.warn(f"cloud-init reported: {p.stdout.strip()} (continuing; setup only needs SSH + the agent)")
            return p.stdout.strip()
        if time.time() > deadline:
            raise StepError(f"cannot SSH into L1 at {c.l1_ip()}: {(p.stderr if p else '').strip()}")
        time.sleep(10)


def s_l1_push(c: Ctx) -> str:
    """Copy the repo payload into L1 and write /etc/qemu-ad/setup.env."""
    stage_kinds = sorted({k for k, _ in c.cfg.stage_files()})
    env = plan.l1_env(c.cfg, c.manifest.install_id, c.vmid, c.gpu, c.cpu_vendor, c.iso_label, stage_kinds)
    files = [p for p in PAYLOAD if os.path.exists(os.path.join(c.repo, p))]
    tar = ["tar", "-C", c.repo, "--exclude=__pycache__", "--exclude=dkms/src", "--exclude=dkms/build", "-czf", "-"] + files
    remote = f"mkdir -p {L1_REPO} && tar -xzf - -C {L1_REPO} && chmod +x {L1_REPO}/setup/l1/*.sh {L1_REPO}/qemu-ad-pve.sh {L1_REPO}/scripts/ovmf-identity/*.sh {L1_REPO}/scripts/bare-metal-audit/*.sh"
    if c.dry:
        print(f"  {ui.c('DRY', 'magenta')} {shlex.join(tar)} | {shlex.join(c.ssh_argv(remote))}")
    else:
        import subprocess
        t = subprocess.Popen(tar, stdout=subprocess.PIPE)
        s = subprocess.run(c.ssh_argv(remote), stdin=t.stdout, capture_output=True, text=True)
        t.wait()
        if t.returncode or s.returncode:
            raise StepError(f"payload copy failed: {s.stderr.strip()}")
        c.runner.note(f"pushed payload {files}")
    c.ssh("install -d -m 700 /etc/qemu-ad && cat > /etc/qemu-ad/setup.env", desc="L1 settings (no secrets)",
          input_text=env)
    return f"{len(files)} paths -> {L1_REPO}"


def _l1_reboot(c: Ctx) -> None:
    c.ssh("systemctl reboot", desc="reboot L1", check=False)
    if c.dry:
        return
    time.sleep(20)
    deadline = time.time() + 600
    while time.time() < deadline:
        p = c.ssh_probe("systemctl is-system-running --wait >/dev/null 2>&1; uname -r", timeout=300)
        if p is not None and p.returncode == 0:
            return
        time.sleep(10)
    raise StepError("L1 did not come back after reboot within 10 min")


def s_l1_packages(c: Ctx) -> str:
    for _ in range(2):
        p = c.l1("packages", check=False, timeout=3600)
        if p.returncode == 0:
            return "ok"
        if p.returncode == 100:
            ui.info("L1 installed a newer kernel: rebooting L1 into it")
            _l1_reboot(c)
            continue
        raise StepError(f"L1 packages failed (rc={p.returncode}); log: /var/log/qemu-ad-setup/packages.log in L1")
    raise StepError("L1 still wants a reboot after packages")


def s_l1_dkms(c: Ctx) -> str:
    c.l1("dkms", timeout=3600)
    return "kvm-l1 DKMS installed (default from next boot)"


def s_l1_qemu_ad(c: Ctx) -> str:
    if not c.dry:
        p = c.ssh_probe(f"{L1_QAD} qemu-ad-check")
        if p is not None and p.returncode == 0:
            return p.stdout.strip().splitlines()[-1]
    mode = c.cfg["l1.qemu_ad"]
    if mode == "copy" or (mode == "auto" and c.host_qemu_ad):
        # Same method as the lab (docs/gpu-phase-patched-kvm-l1.md step 8): read-only tar of the
        # host's /opt/qemu-ad, unpacked in L1. PVE 9 and Debian 13 share the userland.
        tar = ["tar", "-C", "/opt", "-cf", "-", "qemu-ad"]
        remote = "tar -C /opt -xf -"
        if c.dry:
            print(f"  {ui.c('DRY', 'magenta')} {shlex.join(tar)} | {shlex.join(c.ssh_argv(remote))}   # read-only on host")
        else:
            import subprocess
            t = subprocess.Popen(tar, stdout=subprocess.PIPE)
            s = subprocess.run(c.ssh_argv(remote), stdin=t.stdout, capture_output=True, text=True)
            t.wait()
            if t.returncode or s.returncode:
                raise StepError(f"copy of /opt/qemu-ad failed: {s.stderr.strip()}")
    else:
        c.l1("qemu-ad-build", timeout=4 * 3600)
    if c.dry:
        if mode == "copy" or (mode == "auto" and c.host_qemu_ad):
            ui.info("would install (in L1) the Debian packages of any host library the copied binary lacks "
                    "(`qad-l1.sh qemu-ad-libs`, package names from `dpkg -S` on the host)")
        return "dry"
    p = c.ssh_probe(f"{L1_QAD} qemu-ad-check")
    missing = _missing_libs(p.stdout if p else "")
    if missing and (mode == "copy" or (mode == "auto" and c.host_qemu_ad)):
        # The host binary links against PVE's library set (live E2E 2026-10-06: libgcrypt.so.20 and
        # libiscsi.so.7 were absent from a fresh Debian 13 L1). PVE 9 and Debian 13 share the archive,
        # so the host's own package names are the right ones to install in L1.
        pkgs = host_lib_packages(c, missing)
        ui.info(f"copied binary lacks {' '.join(missing)}: installing {' '.join(pkgs)} in L1")
        c.l1("qemu-ad-libs " + " ".join(pkgs), timeout=1800)
        p = c.ssh_probe(f"{L1_QAD} qemu-ad-check")
    if p is None or p.returncode != 0:
        raise StepError(f"qemu-ad-pve in L1 not usable: {_check_detail(p.stdout if p else '')}")
    return p.stdout.strip().splitlines()[-1]


def _check_detail(out: str) -> str:
    """The useful part of a qad-l1.sh check's output, without its '=== qad-l1.sh <step> <date>' banner.

    The state file keeps only the first line of a failure; live E2E 2026-10-06 recorded just the banner
    ('not usable: === qad-l1.sh qemu-ad-check ...') and hid 'QEMU_AD=libs-missing ...'.
    """
    lines = [l.strip() for l in out.splitlines() if l.strip() and not l.startswith("=== ")]
    return "; ".join(lines) or "(no output)"


def _missing_libs(check_out: str) -> List[str]:
    """Library sonames from `qad-l1.sh qemu-ad-check` output ('QEMU_AD=libs-missing a.so.1 b.so.2')."""
    m = re.search(r"^QEMU_AD=libs-missing (.+)$", check_out, re.M)
    return sorted(set(m.group(1).split())) if m else []


_PKG_RE = re.compile(r"^[a-z0-9][a-z0-9.+-]+$")


def host_lib_packages(c: Ctx, libs: List[str]) -> List[str]:
    """Map sonames to the Debian packages that ship them on this (PVE = Debian) host, via `dpkg -S`."""
    pkgs = set()
    for lib in libs:
        if not re.match(r"^[A-Za-z0-9_.+-]+$", lib):
            raise StepError(f"unexpected library name {lib!r}")
        p = c.runner.probe(["dpkg", "-S", f"*/{lib}"])
        found = ""
        for line in p.stdout.splitlines():
            owners, _, path = line.partition(": ")
            if path.strip().endswith("/" + lib):
                found = owners.split(",")[0].strip().split(":")[0]
                break
        if not found or not _PKG_RE.match(found):
            raise StepError(f"the copied qemu-ad binary needs {lib}, which no host package provides; "
                            "use l1.qemu_ad=build")
        pkgs.add(found)
    return sorted(pkgs)


def s_l1_vfio(c: Ctx) -> str:
    c.l1("vfio", timeout=600)
    return "vfio-pci ids=" + ",".join(f.ids for f in c.gpu.functions)


def s_l1_optional_qemu(c: Ctx) -> str:
    """DEFAULT ON (l2.optional_patches=none opts out): build the optional-patch QEMU into /opt/qemu-ad-optpatch inside L1 (never touches /opt/qemu-ad)."""
    pats = plan.optional_patches(c.cfg)
    if not pats:
        raise _Skip("l2.optional_patches=none: the L2 keeps using /opt/qemu-ad")
    if not c.dry:
        p = c.ssh_probe(f"{L1_QAD} qemu-optpatch-check")
        if p is not None and p.returncode == 0 and all(x in p.stdout for x in pats):
            return p.stdout.strip().splitlines()[-1]
    c.l1("qemu-optpatch-build", timeout=4 * 3600)
    if c.dry:
        return "dry"
    p = c.ssh_probe(f"{L1_QAD} qemu-optpatch-check")
    if p is None or p.returncode != 0:
        raise StepError(f"optional-patch QEMU in L1 not usable: {_check_detail(p.stdout if p else '')}")
    return p.stdout.strip().splitlines()[-1]


def s_l1_ovmf_identity(c: Ctx) -> str:
    """DEFAULT ON (l2.ovmf_identity=no opts out): build OVMF in L1, or with l2.ovmf_identity_dir install a prebuilt OVMF_CODE (scripts/ovmf-identity) into L1 at a NEW path; never replaces
    /root/l2/OVMF_CODE.fd or the persistent VARS.fd (the Windows boot entry lives there)."""
    d = c.cfg["l2.ovmf_identity_dir"]
    if not d:
        if c.cfg["l2.ovmf_identity"] != "yes":
            raise _Skip("l2.ovmf_identity=no: the L2 keeps Debian's OVMF")
        # default: build it inside L1 (apt build-deps + edk2 source; L1 is disposable, the PVE host stays stock)
        if not c.dry:
            p = c.ssh_probe(f"{L1_QAD} ovmf-check")
            if p is not None and p.returncode == 0:
                return p.stdout.strip().splitlines()[-1]
        c.l1("ovmf-build", timeout=2 * 3600)
        if c.dry:
            return "dry"
        p = c.ssh_probe(f"{L1_QAD} ovmf-check")
        if p is None or p.returncode != 0:
            raise StepError(f"rebuilt OVMF in L1 not usable: {_check_detail(p.stdout if p else '')}")
        return p.stdout.strip().splitlines()[-1]
    src = os.path.join(d, "OVMF_CODE_4M.fd")
    if c.dry:
        print(f"  {ui.c('DRY', 'magenta')} {src} -> L1:/opt/ovmf-identity/OVMF_CODE.fd (sha256-checked, new path)")
        return "dry"
    if not os.path.isfile(src):
        raise StepError(f"{src} not found (build it with scripts/ovmf-identity/build-ovmf-identity.sh in a scratch VM)")
    with open(src, "rb") as fh:
        blob = fh.read()
    if not 1 << 20 <= len(blob) <= 8 << 20:
        raise StepError(f"{src}: {len(blob)} bytes is not a plausible OVMF_CODE_4M.fd")
    digest = hashlib.sha256(blob).hexdigest()
    import subprocess
    remote = ("install -d -m 755 /opt/ovmf-identity && cat > /opt/ovmf-identity/OVMF_CODE.fd.tmp && "
              f"echo '{digest}  /opt/ovmf-identity/OVMF_CODE.fd.tmp' | sha256sum -c --quiet && "
              "chmod 644 /opt/ovmf-identity/OVMF_CODE.fd.tmp && "
              "mv -f /opt/ovmf-identity/OVMF_CODE.fd.tmp /opt/ovmf-identity/OVMF_CODE.fd")
    r = subprocess.run(c.ssh_argv(remote), input=blob, capture_output=True)
    if r.returncode:
        raise StepError(f"copy of the OVMF image to L1 failed: {r.stderr.decode(errors='replace').strip()}")
    return f"/opt/ovmf-identity/OVMF_CODE.fd sha256 {digest[:12]}"


def s_l1_scripts(c: Ctx) -> str:
    c.l1("scripts", timeout=600)
    return "/root/w10 + w10-l2.service (qm-native-9200 unit, not enabled yet)"


def s_l1_reboot(c: Ctx) -> str:
    _l1_reboot(c)
    p = c.l1("check-kvm", stream=True, check=False, timeout=120)
    if c.dry:
        return "dry"
    if p.returncode != 0:
        raise StepError("after reboot the patched KVM / vfio-pci / DMAR check failed (see above)")
    return "patched KVM is the boot default; GPU on vfio-pci in L1"


def s_l2_stage(c: Ctx) -> str:
    if c.cfg["l2.source"] == "none":
        raise _Skip("l2.source=none")
    c.ssh("rm -rf /root/qad-stage/in && install -d -m 700 /root/qad-stage/in", desc="staging dir in L1")
    for kind, path in c.cfg.stage_files():
        dest = f"/root/qad-stage/in/{kind}/"
        c.ssh(f"install -d -m 700 {dest}", desc=f"staging {kind}")
        src = [os.path.join(path, f) for f in sorted(os.listdir(path))] if os.path.isdir(path) and not c.dry else [path]
        c.runner.run(c.scp_argv("-r", *src, f"root@{c.l1_ip()}:{dest}"),
                     desc=f"copy {kind} into L1 (host file only read)", timeout=7200)
    if c.download_proprietary and c.cfg.downloads():
        lines = "".join(f"{u} {s} {n}\n" for u, s, n in c.cfg.downloads())
        c.ssh("cat > /root/qad-stage/downloads.txt", desc="--download-proprietary list (downloaded in L1)",
              input_text=lines)
    else:
        c.ssh("rm -f /root/qad-stage/downloads.txt", desc="no downloads")
    au = c.cfg["l2.autounattend"]
    c.ssh("rm -f /root/qad-stage/autounattend.xml", desc="reset autounattend")
    if c.cfg["l2.source"] == "iso" and au == "generate":
        pw, pk = c.cfg["l2.admin_password"], c.cfg["l2.product_key"]
        # Register known secrets before any probe so -v / log redaction cannot leak them.
        c.runner.secrets += [s for s in (pw, pk) if s]
        if not c.dry:  # resume: reuse what an earlier run stored in L1
            p = c.ssh_probe("cat /etc/qemu-ad/l2-secrets 2>/dev/null || true")
            old = parse_secrets(p.stdout if p else "")
            if not pw and old.get("QAD_ADMIN_PASSWORD"):
                pw = old["QAD_ADMIN_PASSWORD"]
                c.runner.secrets.append(pw)
            if not pk and old.get("QAD_PRODUCT_KEY"):
                pk = old["QAD_PRODUCT_KEY"]
                c.runner.secrets.append(pk)
        generated = not pw
        pw = pw or random_password()
        if pw not in c.runner.secrets:
            c.runner.secrets.append(pw)
        c.ssh("umask 077 && cat > /etc/qemu-ad/l2-secrets", desc="L2 admin password/key (root-only, L1)",
              input_text=plan.secrets_env(pw, pk))
        c.ssh("umask 077 && cat > /root/qad-stage/autounattend.xml", desc="generated autounattend.xml",
              input_text=autounattend(c.cfg, pw, pk))
        if generated and not c.dry:
            c.extra["admin_password"] = pw
    elif c.cfg["l2.source"] == "iso" and au.startswith("/"):
        c.runner.run(c.scp_argv(au, f"root@{c.l1_ip()}:/root/qad-stage/autounattend.xml"),
                     desc="your autounattend.xml")
    c.l1("stage", timeout=7200)
    return "stage.iso" + (" + autounattend.iso" if au != "none" and c.cfg["l2.source"] == "iso" else "")


def s_l2_install(c: Ctx) -> str:
    if c.cfg["l2.source"] == "none":
        raise _Skip("l2.source=none")
    if c.wipe_l2_disk:
        if c.cfg["l2.source"] != "iso":
            raise StepError("--wipe-l2-disk only makes sense for l2.source=iso (it would erase the imported image)")
        c.l1("l2-wipe", timeout=300)
    c.l1("l2-install", timeout=300)
    if c.dry:
        ui.info("would poll `qad-l1.sh l2-install-status` every 30 s until DONE")
        return "dry"
    vnc = c.cfg["l2.vnc"]
    if vnc != "none":
        port = 5900 + int(vnc.rsplit(":", 1)[1])
        ui.info(f"watch the install: ssh -i {c.key} -L {port}:{vnc.rsplit(':', 1)[0]}:{port} root@{c.l1_ip()} "
                f"then a VNC viewer on localhost:{port}")
    if c.cfg["l2.autounattend"] == "none" and c.cfg["l2.source"] == "iso":
        ui.warn("interactive install: finish Windows Setup over VNC, optionally run D:\\qad\\firstlogon.ps1 "
                "(QADSTAGE CD) as Administrator, then shut Windows down.")
    deadline = time.time() + c.cfg.int("l2.install_timeout_min") * 60 + 120
    last = ""
    while time.time() < deadline:
        p = c.ssh_probe(f"{L1_QAD} l2-install-status")
        out = p.stdout if p else ""
        st = (re.search(r"^INSTALL_STATE=(\w+)", out, re.M) or [None, "?"])[1]
        tail = "; ".join(l.split("=", 1)[1] for l in out.splitlines() if l.startswith("INSTALL_LOG="))
        if tail != last:
            ui.info(f"[{time.strftime('%H:%M')}] {st}: {tail}")
            last = tail
        if st == "DONE":
            return "Windows created, OVMF VARS template built without the GPU"
        if st == "FAILED":
            raise StepError("L2 creation failed; see /var/log/qemu-ad-setup/l2-create.log in L1")
        time.sleep(30)
    raise StepError("timed out waiting for the L2 creation (it may still run in L1; re-run setup.sh install)")


def s_l2_enable(c: Ctx) -> str:
    if c.cfg["l2.source"] == "none":
        raise _Skip("l2.source=none")
    c.l1("l2-enable", timeout=300)
    return "w10-l2.service (qm-native-9200) enabled + started (GPU)"


def s_verify(c: Ctx) -> str:
    if c.cfg["l2.source"] == "none":
        p = c.l1("check-kvm", check=False)
        if not c.dry and p.returncode != 0:
            raise StepError("check-kvm failed")
        return "L1 checks only (no L2)"
    if c.dry:
        c.l1("verify", check=False)
        return "dry"
    deadline = time.time() + 900  # first GPU boot may install the NVIDIA driver and reboot once
    while True:
        p = c.ssh_probe(f"{L1_QAD} verify", timeout=900)
        out = p.stdout if p else ""
        if p is not None and p.returncode == 0:
            c.extra["verify"] = out
            return "PASS"
        if time.time() > deadline:
            c.extra["verify"] = out
            raise StepError("verify did not pass within 15 min (run `setup.sh verify` later; see docs/SETUP.md)")
        ui.info("verify not passing yet (L2 still booting / installing the driver?) - retrying in 60 s")
        time.sleep(60)


def s_l2_finalize(c: Ctx) -> str:
    """Post-verify cleanup in the L2 (qad-l1.sh finalize: hygiene, ... then verify again)."""
    if c.cfg["l2.source"] == "none":
        raise _Skip("l2.source=none")
    if not (c.cfg.bool("l2.cleanup_unattend") or c.cfg.bool("l2.cleanup_staging")):
        raise _Skip("all post-install cleanups opted out")
    c.l1("finalize", timeout=1500)  # raises CommandError when a cleanup or the re-verify fails
    if c.dry:
        return "dry"
    return "residue removed (unattend/Panther, staging), verify PASS"


class _Skip(Exception):
    pass


def parse_secrets(text: str) -> Dict[str, str]:
    """Parse the shell-quoted KEY=VALUE lines written by plan.secrets_env()."""
    out: Dict[str, str] = {}
    for m in re.finditer(r"^(QAD_\w+)=(.*)$", text, re.M):
        try:
            vals = shlex.split(m.group(2))
        except ValueError:
            continue
        out[m.group(1)] = vals[0] if vals else ""
    return out


STEPS: List[tuple] = [
    ("host_dirs", "state dir /var/lib/qemu-ad/setup", s_host_dirs),
    ("ssh_key", "SSH key for L1", s_ssh_key),
    ("debian_image", "Debian 13 cloud image", s_debian_image),
    ("seed_iso", "cloud-init seed ISO", s_seed_iso),
    ("hookscript", "GPU-guard hookscript (qm-native-9200)", s_hookscript),
    ("l1_smbios", "L1 SMBIOS structures (bare-metal look)", s_l1_smbios),
    ("vm_create", "create L1 VM", s_vm_create),
    ("vm_start", "start L1", s_vm_start),
    ("l1_ip", "L1 address + host key", s_l1_ip),
    ("l1_ssh", "SSH + cloud-init", s_l1_ssh),
    ("l1_push", "copy repo payload to L1", s_l1_push),
    ("l1_packages", "L1 packages + kernel", s_l1_packages),
    ("l1_dkms", "patched KVM (DKMS)", s_l1_dkms),
    ("l1_qemu_ad", "qemu-ad-pve binary in L1", s_l1_qemu_ad),
    ("l1_vfio", "vfio-pci for the GPU in L1", s_l1_vfio),
    ("l1_optional_qemu", "optional-patch QEMU built in L1 (default on)", s_l1_optional_qemu),
    ("l1_ovmf_identity", "rebuilt OVMF identity built in L1 (default on)", s_l1_ovmf_identity),
    ("l1_scripts", "L2 scripts + w10-l2.service", s_l1_scripts),
    ("l1_reboot", "reboot L1, prove defaults", s_l1_reboot),
    ("l2_stage", "staging ISO (+ autounattend)", s_l2_stage),
    ("l2_install", "create Windows L2 (no GPU)", s_l2_install),
    ("l2_enable", "start L2 with GPU (autostart)", s_l2_enable),
    ("verify", "verify (KVM, L2, GPU Code 0)", s_verify),
    ("l2_finalize", "post-verify cleanup of install residue in the L2", s_l2_finalize),
]
STEP_NAMES = [s[0] for s in STEPS]


def run_steps(c: Ctx, redo: Optional[List[str]] = None, only_until: Optional[str] = None) -> bool:
    redo = redo or []
    for name in redo:
        c.state.reset(name)
    ok = True
    for name, desc, fn in STEPS:
        if c.state.is_done(name) and name not in redo:
            ui.info(f"{ui.status('done')} {name}: {c.state.steps[name].get('detail', '')}")
            continue
        ui.heading(f"{name}: {desc}")
        if not c.dry:
            c.state.mark(name, RUNNING)
        try:
            detail = fn(c)
            if not c.dry:
                c.state.mark(name, DONE, str(detail))
                c.manifest.save()
            ui.info(f"{ui.status('done' if not c.dry else 'DRY')} {detail}")
        except _Skip as exc:
            if not c.dry:
                c.state.mark(name, SKIPPED, str(exc))
            ui.info(f"{ui.status('skipped')} {exc}")
        except (StepError, CommandError, OSError) as exc:
            if not c.dry:
                c.state.mark(name, FAILED, str(exc).splitlines()[0][:300])
                c.manifest.save()
            ui.error(f"{name} failed: {exc}")
            ok = False
            break
        except KeyboardInterrupt:
            if not c.dry:
                c.state.mark(name, FAILED, "interrupted")
                c.manifest.save()
            ui.warn("interrupted; re-run `setup.sh install` to resume")
            ok = False
            break
        if only_until and name == only_until:
            break
    return ok


def summary_rows(state: State) -> List[List[str]]:
    rows = []
    for name, desc, _ in STEPS:
        st = state.steps.get(name, {})
        rows.append([name, st.get("status", "pending"), st.get("detail", desc)[:110]])
    return rows
