"""setup.sh entry point: preflight | install (default) | status | verify | uninstall."""
from __future__ import annotations

import argparse
import os
import re
import sys
import time
import uuid
from urllib.parse import unquote
from typing import List, Optional

from . import hostinfo as hi
from . import preflight as pf
from . import steps, ui
from .config import SCHEMA, Config, ConfigError, _check, cross_validate, parse_ini
from .manifest import HostFacts, Manifest, ManifestError, plan_uninstall
from .runner import CommandError, Runner, sha256_file
from .state import State

SUBCOMMANDS = ("preflight", "install", "status", "verify", "uninstall")
VALUE_OPTS = {"--config", "--state-dir", "--redo", "--set", "--sysroot"}
DEFAULT_ROOT = "/var/lib/qemu-ad"


def repo_root() -> str:
    return os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    g = common.add_argument_group("common options")
    g.add_argument("--config", metavar="FILE", help="INI file with answers (see setup/config.example.ini)")
    g.add_argument("--set", action="append", default=[], metavar="SECTION.KEY=VALUE",
                   help="override one setting (repeatable), e.g. --set l1.vmid=9300")
    g.add_argument("-y", "--yes", action="store_true", help="unattended: accept defaults, no questions")
    g.add_argument("-n", "--dry-run", action="store_true",
                   help="print every host change / command instead of executing it")
    g.add_argument("-v", "--verbose", action="store_true", help="show commands and file previews")
    g.add_argument("--no-color", action="store_true", help="disable colours (NO_COLOR is honoured too)")
    g.add_argument("--state-dir", default=DEFAULT_ROOT, help=argparse.SUPPRESS)
    g.add_argument("--sysroot", default="/", help=argparse.SUPPRESS)  # tests: fake /sys, /proc, /etc/pve
    p = argparse.ArgumentParser(
        prog="setup.sh",
        description="One-command setup of the qemu-ad-pve nested stack on a Proxmox VE host: creates an L1 "
                    "Debian 13 VM (patched KVM + qemu-ad-pve) and a Windows L2 that gets the passed-through GPU.",
        epilog="Default subcommand: install. Docs: docs/SETUP.md")
    sub = p.add_subparsers(dest="cmd", metavar="{preflight,install,status,verify,uninstall}")
    sub.add_parser("preflight", parents=[common], help="read-only host checks (PASS/WARN/FAIL table)")
    ins = sub.add_parser("install", parents=[common], help="create L1 + L2 and set everything up (resumable)")
    ins.add_argument("--redo", action="append", default=[], choices=steps.STEP_NAMES, metavar="STEP",
                     help="re-run a finished step (repeatable): " + ", ".join(steps.STEP_NAMES))
    ins.add_argument("--download-proprietary", action="store_true",
                     help="allow the stage.downloads list (e.g. NVIDIA driver) to be downloaded inside L1")
    ins.add_argument("--wipe-l2-disk", action="store_true",
                     help="(l2.source=iso) wipe the setup-created Windows disk (serial drive-scsi1) before reinstalling")
    sub.add_parser("status", parents=[common], help="show what was created and the state of L1/L2")
    sub.add_parser("verify", parents=[common], help="patched KVM in L1, L2 running, GPU Code 0, optional CUDA")
    un = sub.add_parser("uninstall", parents=[common], help="remove exactly what the manifest lists")
    un.add_argument("--force", action="store_true",
                    help="also remove setup files whose content changed (never VMs without our marker)")
    return p


def normalize_argv(argv: List[str]) -> List[str]:
    """Allow options before the subcommand and default to `install`."""
    skip = False
    for i, tok in enumerate(argv):
        if skip:
            skip = False
            continue
        if tok in VALUE_OPTS:
            skip = True
            continue
        if tok in ("-h", "--help") and i == 0:
            return argv
        if tok in SUBCOMMANDS:
            return [tok] + argv[:i] + argv[i + 1:]
    return ["install"] + argv


# ====================================================================== context
class App:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.root = args.state_dir
        self.setup_dir = os.path.join(self.root, "setup")
        self.manifest_path = os.path.join(self.root, "manifest.json")
        self.state = State.load(os.path.join(self.setup_dir, "state.json"))
        self.manifest = Manifest.load(self.manifest_path)
        self.runner = Runner(dry_run=args.dry_run, verbose=args.verbose)
        self.prompter = ui.Prompter(assume_yes=args.yes)

    # -------------------------------------------------------------- config
    def load_config(self) -> Config:
        saved = os.path.join(self.setup_dir, "config.ini")
        if self.args.config:
            with open(self.args.config, encoding="utf-8") as fh:
                cfg = parse_ini(fh.read(), self.args.config)
            if self.manifest and os.path.exists(saved):
                with open(saved, encoding="utf-8") as fh:
                    old = parse_ini(fh.read(), saved)
                if cfg["l1.vmid"] not in ("auto", old["l1.vmid"]):
                    raise ConfigError(f"an installation already exists (L1 VM {old['l1.vmid']}); run "
                                      "`setup.sh status` or `setup.sh uninstall` first")
                for k in ("l1.vmid", "gpu.slot", "l1.storage", "l1.iso_storage", "l1.snippets_storage",
                          "l1.hookscript"):
                    if cfg.is_auto(k):
                        cfg.set(k, old[k])
        elif os.path.exists(saved):
            with open(saved, encoding="utf-8") as fh:
                cfg = parse_ini(fh.read(), saved)
            ui.info(f"resuming with the saved answers in {saved}")
        else:
            cfg = Config()
        for item in self.args.set:
            if "=" not in item:
                raise ConfigError(f"--set expects section.key=value, got {item!r}")
            k, v = item.split("=", 1)
            cfg.set(k.strip(), v.strip())
        return cfg

    def open_log(self) -> None:
        if not self.args.dry_run:
            self.runner.open_log(os.path.join(self.setup_dir, "logs",
                                              time.strftime(f"{self.args.cmd}-%Y%m%d-%H%M%S.log")))

    def own_vm(self, cfg: Config) -> bool:
        return bool(self.manifest and self.manifest.vm() and self.manifest.vm()["vmid"] == cfg["l1.vmid"])

    def resolve(self, cfg: Config, snap: pf.Snapshot, ask: bool) -> Optional[hi.Gpu]:
        """Fill 'auto' values (GPU picker, VMID, storages) and ask the interactive questions."""
        p = self.prompter if ask else ui.Prompter(assume_yes=True)
        # ---- GPU picker
        gpu = None
        if cfg.is_auto("gpu.slot"):
            usable = [g for g in pf.gpu_candidates(snap)
                      if not any(f.driver not in ("", "vfio-pci") and f.cls.startswith("03") for f in g.functions)]
            ui.heading("GPUs on this host")
            for g in snap.gpus:
                print("  " + pf.describe_gpu(g).replace("\n", "\n  "))
            if len(usable) == 1:
                gpu = usable[0]
                ui.info(f"auto-selected the only passthrough-ready GPU: {gpu.slot} {gpu.name}")
                if ask and p.interactive and not p.assume_yes and len(snap.gpus) > 1:
                    i = p.choose("GPU to pass through", [f"{g.slot} {g.name}" for g in snap.gpus],
                                 snap.gpus.index(gpu))
                    gpu = snap.gpus[i]
            elif snap.gpus and p.interactive and not p.assume_yes:
                default = snap.gpus.index(usable[0]) if usable else 0
                i = p.choose("GPU to pass through", [f"{g.slot} {g.name}" for g in snap.gpus], default)
                gpu = snap.gpus[i]
            if gpu:
                cfg.set("gpu.slot", gpu.slot, explicit=False)
        else:
            gpu = pf.pick_gpu(snap, cfg["gpu.slot"])
            if gpu is None:
                ui.warn(f"gpu.slot {cfg['gpu.slot']} is not a display device on this host")
        # ---- auto values
        if cfg.is_auto("l1.vmid") and snap.nextid:
            cfg.set("l1.vmid", snap.nextid, explicit=False)
        if cfg.is_auto("l1.storage"):
            st = pf.choose_storage(snap.storages.get("images", []))
            if st:
                cfg.set("l1.storage", st, explicit=False)
        if cfg.is_auto("l1.iso_storage"):
            st = pf.choose_storage(snap.storages.get("iso", []), prefer=("local",))
            if st:
                cfg.set("l1.iso_storage", st, explicit=False)
        if cfg.is_auto("l1.snippets_storage"):
            st = pf.choose_storage(snap.storages.get("snippets", []), prefer=("local",))
            if st:
                cfg.set("l1.snippets_storage", st, explicit=False)
        if cfg.is_auto("l1.hookscript"):
            cfg.set("l1.hookscript", "yes", explicit=False)  # preflight FAILs if no snippets storage exists
        if cfg["l2.source"] == "iso" and not cfg["l2.windows_iso"]:
            iso = pick_windows_iso(_list_isos(self.runner, snap), cfg["l2.windows_version"])
            if iso:
                cfg.set("l2.windows_iso", iso, explicit=False)
        # ---- questions
        if ask and p.interactive and not p.assume_yes:
            ui.heading("Settings (Enter keeps the [default]; see docs/SETUP.md for all keys)")
            for key in SCHEMA:
                if not key.prompt or key.fq in cfg.explicit or key.fq == "gpu.slot" or not _relevant(cfg, key.fq):
                    continue
                if self.own_vm(cfg) and key.section == "l1":
                    continue  # L1 already exists: its settings are fixed

                def check(v: str, k=key) -> Optional[str]:
                    try:
                        _check(k, v)
                    except ConfigError as exc:
                        return str(exc)
                    return None
                val = p.ask(key.help, cfg[key.fq], check, secret=key.secret)
                cfg.set(key.fq, val)
        return gpu


def _relevant(cfg: Config, fq: str) -> bool:
    src = cfg["l2.source"]
    if fq in ("l2.windows_iso", "l2.disk_gb", "l2.autounattend"):
        return src == "iso"
    if fq == "l2.image":
        return src == "image"
    if fq == "l2.product_key":
        return src == "iso" and cfg["l2.autounattend"] == "generate"
    if fq.startswith("l2.") or fq.startswith("stage."):
        return src != "none" or fq == "l2.source"
    return True


# Windows installer ISO names: Win10_22H2_English_x64v1.iso, Win11_24H2_English_x64.iso,
# en-us_windows_10_..._x64_dvd_....iso. Not virtio-win-*.iso (driver ISO; the old r"win" match picked it
# on the live E2E host because it sorts first) and not *unattend*.iso (answer-file ISOs).
_WIN_ISO_RE = re.compile(r"(?:^|[^a-z0-9])win(?:dows)?[ _.-]?(10|11)(?![0-9])", re.I)


def pick_windows_iso(volids: List[str], version: str = "10") -> Optional[str]:
    """Best Windows installer ISO among PVE volids (preferring l2.windows_version), else None."""
    hits = []
    for v in volids:
        name = v.rsplit("/", 1)[-1]
        m = _WIN_ISO_RE.search(name)
        if not m or re.search(r"virtio|unattend", name, re.I):
            continue
        hits.append((m.group(1) != version, v))
    return sorted(hits)[0][1] if hits else None


def _list_isos(runner: Runner, snap: pf.Snapshot) -> List[str]:
    out = []
    for st in snap.storages.get("iso", []):
        p = runner.probe(["pvesm", "list", st.name, "--content", "iso"])
        for line in p.stdout.splitlines()[1:]:
            if line.split():
                out.append(line.split()[0])
    return out


def print_checks(checks: List[pf.Check]) -> None:
    rows = [[c.status, c.name, c.detail + (f"\n      fix: {c.fix}" if c.fix and c.status in ("FAIL", "WARN") else "")]
            for c in checks]
    flat = []
    for r in rows:
        first, *rest = r[2].split("\n")
        flat.append([r[0], r[1], first])
        for extra in rest:
            flat.append(["", "", ui.c(extra.strip(), "dim")])
    print(ui.table(["RESULT", "CHECK", "DETAIL"], flat, colorize_col=0))
    n = {s: sum(1 for c in checks if c.status == s) for s in ("PASS", "WARN", "FAIL")}
    print(f"\n  {ui.status('PASS')} {n['PASS']}   {ui.status('WARN')} {n['WARN']}   {ui.status('FAIL')} {n['FAIL']}")


def dummy_gpu() -> hi.Gpu:
    f0 = hi.PciFunc("0000:XX:00.0", "10de", "XXXX", "0300", "vfio-pci", "N", "<GPU video>")
    f1 = hi.PciFunc("0000:XX:00.1", "10de", "YYYY", "0403", "vfio-pci", "N", "<GPU audio>")
    return hi.Gpu("0000:XX:00", [f0, f1])


# ====================================================================== commands
def cmd_preflight(app: App, ask: bool = True):
    cfg = app.load_config()
    ui.heading("Collecting host facts (read-only)")
    snap = pf.collect(cfg, app.runner, app.args.sysroot)
    gpu = app.resolve(cfg, snap, ask)
    vmid = None if cfg.is_auto("l1.vmid") else cfg["l1.vmid"]
    problems = cross_validate(cfg)
    snap = pf.collect(cfg, app.runner, app.args.sysroot)  # re-read with the resolved/answered paths
    if not cfg.is_auto("gpu.slot"):
        gpu = pf.pick_gpu(snap, cfg["gpu.slot"])
    checks = pf.evaluate(cfg, snap, vmid, gpu, own_vm=app.own_vm(cfg))
    for msg in problems:
        checks.append(pf.Check("Config", "FAIL", msg, "Fix the setting (--config / --set / prompt)."))
    ui.heading("Preflight")
    print_checks(checks)
    return cfg, snap, gpu, checks


def planned_changes(cfg: Config, gpu: hi.Gpu, app: App) -> List[str]:
    vmid = cfg["l1.vmid"]
    out = [f"create VM {vmid} '{cfg['l1.name']}' on {cfg['l1.storage']}: {cfg['l1.memory_mb']} MiB, "
           f"{cfg['l1.cores']} cores, disk {cfg['l1.disk_gb']}G, q35 + Intel vIOMMU, GPU {gpu.slot} "
           f"({len(gpu.functions)} functions) via args: (pcie-pci-bridge)"]
    if cfg["l2.source"] == "iso":
        out.append(f"  + Windows disk scsi1 {cfg['l2.disk_gb']}G on {cfg['l1.storage']} and the Windows ISO "
                   f"{cfg['l2.windows_iso']} attached read-only as ide0")
    elif cfg["l2.source"] == "image":
        out.append(f"  + Windows disk scsi1 imported (copied) from {cfg['l2.image']}")
    out.append(f"cloud-init seed ISO {cfg['l1.iso_storage']}:iso/qad-l1-{vmid}-seed.iso")
    if cfg["l1.hookscript"] == "yes":
        out.append(f"GPU-guard hookscript (qm-native-9200) {cfg['l1.snippets_storage']}:snippets/qad-l1-{vmid}-gpu-guard.pl")
    if not cfg["l1.debian_image"]:
        out.append(f"Debian 13 cloud image cache in {app.setup_dir}/cache/ (~400 MiB)")
    out.append(f"{app.manifest_path} and {app.setup_dir}/ (state, config without secrets, logs, SSH key)")
    out.append("Nothing else on the host: no packages, kernel, modprobe, /usr or /etc/pve/storage changes.")
    return out


def cmd_install(app: App) -> int:
    args = app.args
    if not args.dry_run and os.geteuid() != 0:
        ui.error("install must run as root on the PVE host (try --dry-run to preview)")
        return 2
    cfg, snap, gpu, checks = cmd_preflight(app, ask=True)
    if pf.failed(checks):
        if not args.dry_run:
            ui.error("preflight failed: fix the FAIL rows above and re-run (nothing was changed)")
            return 1
        ui.warn("preflight has FAIL rows: a real run would stop here; continuing because of --dry-run")
    if gpu is None:
        gpu = dummy_gpu()
        ui.warn("no GPU selected; using a placeholder in the dry-run output")
    ui.heading("Planned host changes")
    for line in planned_changes(cfg, gpu, app):
        print(f"  - {line}")
    if not args.dry_run and not app.prompter.confirm("Proceed?", default=False):
        ui.warn("aborted; nothing was changed (unattended runs need --yes)")
        return 1
    # ---- persistent bookkeeping (real runs only)
    if app.manifest is None:
        app.manifest = Manifest(install_id=uuid.uuid4().hex[:12], created=time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                                path=app.manifest_path)
    if not args.dry_run:
        new_root = app.runner.mkdir(app.root, mode=0o755)
        app.runner.mkdir(app.setup_dir)
        if new_root:
            app.manifest.add("dir", path=app.root)
        app.manifest.add("dir", path=app.setup_dir)
        app.open_log()
        saved = os.path.join(app.setup_dir, "config.ini")
        app.runner.write_file(saved, cfg.to_ini(), mode=0o600, desc="answers (no secrets)")
        for p in (saved, app.state.path):
            app.manifest.add("file", path=p)
        if app.runner.log_path:
            app.manifest.add("file", path=app.runner.log_path)
        app.manifest.save()
        app.runner.secrets += [cfg["l2.admin_password"], cfg["l2.product_key"]]
    ctx = steps.Ctx(cfg=cfg, runner=app.runner, state=app.state, manifest=app.manifest, prompter=app.prompter,
                    repo=repo_root(), state_dir=app.setup_dir, gpu=gpu, cpu_vendor=snap.cpu_vendor,
                    host_qemu_ad=snap.host_qemu_ad, download_proprietary=getattr(args, "download_proprietary", False),
                    wipe_l2_disk=getattr(args, "wipe_l2_disk", False))
    if cfg["l2.source"] == "iso" and snap.iso_path:
        ctx.iso_label = app.runner.probe(["blkid", "-p", "-s", "LABEL", "-o", "value", snap.iso_path]).stdout.strip()
    ok = steps.run_steps(ctx, redo=getattr(args, "redo", []))
    if not args.dry_run:
        for p in [os.path.join(app.setup_dir, "logs", f) for f in os.listdir(os.path.join(app.setup_dir, "logs"))] \
                if os.path.isdir(os.path.join(app.setup_dir, "logs")) else []:
            app.manifest.add("file", path=p)
        app.manifest.save()
    ui.heading("Summary")
    print(ui.table(["STEP", "STATUS", "DETAIL"], steps.summary_rows(app.state) if not args.dry_run else
                   [[n, "DRY", d] for n, d, _ in steps.STEPS], colorize_col=1))
    if args.dry_run:
        print(f"\n  {len(app.runner.changes)} host/L1 changes listed above; nothing was executed.")
        return 0
    if "admin_password" in ctx.extra:
        print(f"\n  Windows admin: {cfg['l2.admin_user']} / {ui.c(ctx.extra['admin_password'], 'bold')}"
              "  (shown once; also root-only in L1:/etc/qemu-ad/l2-secrets)")
    ip = app.state.facts.get("l1_ip")
    if ip:
        print(f"  L1: ssh -i {ctx.key} root@{ip}    VM {cfg['l1.vmid']}: qm start|shutdown {cfg['l1.vmid']}")
    if app.runner.log_path:
        print(f"  log: {app.runner.log_path}")
    if not ok:
        print("\n  " + ui.c("Not finished.", "red") + " Fix the error above and re-run `./setup.sh install` "
              "(finished steps are skipped). `--redo STEP` re-runs one.")
        return 1
    print("\n  " + ui.c("Done.", "green") + " `./setup.sh verify` re-checks; `./setup.sh uninstall` removes it all.")
    return 0


def _need_install(app: App) -> Optional[int]:
    if app.manifest is None:
        ui.warn(f"no installation recorded ({app.manifest_path} missing)")
        return 1
    return None


def _ctx_for(app: App) -> steps.Ctx:
    cfg = app.load_config()
    return steps.Ctx(cfg=cfg, runner=app.runner, state=app.state, manifest=app.manifest, prompter=app.prompter,
                     repo=repo_root(), state_dir=app.setup_dir)


def cmd_status(app: App) -> int:
    if (rc := _need_install(app)) is not None:
        return rc
    m = app.manifest
    ui.heading(f"Installation {m.install_id} (created {m.created})")
    print(ui.table(["KIND", "WHAT"], [[e["kind"], e.get("vmid") or e.get("volid") or e.get("path", "")]
                                      for e in m.entries]))
    ui.heading("Install steps")
    print(ui.table(["STEP", "STATUS", "DETAIL"], steps.summary_rows(app.state), colorize_col=1))
    vm = m.vm()
    if vm:
        st = app.runner.probe(["qm", "status", vm["vmid"]]).stdout.strip() or "absent"
        ui.heading(f"L1 VM {vm['vmid']}: {st}")
        if "running" in st and app.state.facts.get("l1_ip"):
            ctx = _ctx_for(app)
            p = ctx.ssh_probe(f"{steps.L1_QAD} status", timeout=60)
            print((p.stdout if p else "").rstrip() or ui.c("  (L1 not reachable over SSH)", "yellow"))
    return 0


def cmd_verify(app: App) -> int:
    if (rc := _need_install(app)) is not None:
        return rc
    ctx = _ctx_for(app)
    app.open_log()
    if "l1_ip" not in app.state.facts:
        ui.error("L1 address unknown (install did not get that far)")
        return 1
    ui.heading(f"verify via L1 {ctx.l1_ip()}")
    if app.args.dry_run:
        ctx.l1("verify", check=False)
        return 0
    p = ctx.ssh_probe(f"{steps.L1_QAD} verify", timeout=900)
    out = p.stdout if p else ""
    rows = []
    for line in out.splitlines():
        if "=" in line and re.match(r"^[A-Z0-9_]+=", line):
            k, v = line.split("=", 1)
            st = "PASS" if v in ("PASS", "0", "ok") else ("FAIL" if v.startswith("FAIL") else "INFO")
            if k == "GPU_CODE":
                st = "PASS" if v.split(" ")[0] == "0" else "FAIL"
            rows.append([st, k, v])
    print(ui.table(["RESULT", "CHECK", "VALUE"], rows, colorize_col=0) if rows else out)
    return 0 if p is not None and p.returncode == 0 else 1


def cmd_uninstall(app: App) -> int:
    args = app.args
    if (rc := _need_install(app)) is not None:
        return rc
    if not args.dry_run and os.geteuid() != 0:
        ui.error("uninstall must run as root")
        return 2
    r = app.runner
    m = app.manifest

    def vm_status(vmid: str) -> Optional[str]:
        p = r.probe(["qm", "status", vmid])
        if p.returncode != 0:
            return None
        return "running" if "running" in p.stdout else "stopped"

    def vm_desc(vmid: str) -> str:
        conf = hi.parse_vm_conf(r.probe(["qm", "config", vmid]).stdout)
        return unquote(conf.get("description", ""))

    def vol_exists(volid: str) -> bool:
        return r.probe(["pvesm", "path", volid]).returncode == 0 and any(
            e.get("volid") == volid and os.path.exists(e.get("path", "")) for e in m.entries)

    facts = HostFacts(vm_status, vm_desc, sha256_file, vol_exists)
    cfg_timeout = 240
    try:
        cfg_timeout = app.load_config().int("l1.shutdown_timeout")
    except (ConfigError, OSError):
        pass
    actions = plan_uninstall(m, facts, force=getattr(args, "force", False), shutdown_timeout=cfg_timeout)
    ui.heading(f"Uninstall plan for installation {m.install_id}")
    for a in actions:
        line = a.describe() + (f"   # {a.reason}" if a.reason and a.kind != "skip" else "")
        print(f"  {ui.c('-', 'cyan') if a.kind != 'skip' else ui.c('~', 'yellow')} {line}")
    print("  - finally: remove the manifest and setup state")
    if args.dry_run:
        print("\n  (dry run: nothing removed)")
        return 0
    vm = m.vm()
    if vm and not args.yes:
        if not app.prompter.interactive:
            ui.error("refusing to uninstall non-interactively without --yes")
            return 1
        typed = app.prompter.ask(f"This DESTROYS VM {vm['vmid']} and its disks (incl. Windows). Type the VMID "
                                 "to confirm", "")
        if typed != vm["vmid"]:
            ui.warn("not confirmed; nothing removed")
            return 1
    failures = 0
    for a in actions:
        try:
            if a.kind == "run":
                r.run(a.argv, desc=a.reason, timeout=cfg_timeout + 120, stream=True)
            elif a.kind == "rm":
                os.unlink(a.target)
                print(f"  removed {a.target}")
            elif a.kind == "rmdir":
                continue  # after the manifest itself is gone (below)
            else:
                ui.warn(a.describe())
        except (CommandError, OSError) as exc:
            failures += 1
            ui.error(f"{a.describe()}: {exc}")
    if failures:
        ui.error(f"{failures} action(s) failed; manifest kept so you can re-run `setup.sh uninstall`")
        return 1
    for p in (app.manifest_path, app.state.path):
        if os.path.exists(p):
            os.unlink(p)
    # directories that only held the manifest/state can go now (still: only ones we created, only if empty)
    for d in sorted((e["path"] for e in m.entries if e["kind"] == "dir"), key=lambda x: x.count("/"), reverse=True):
        try:
            os.rmdir(d)
            print(f"  removed {d}/")
        except FileNotFoundError:
            pass
        except OSError as exc:
            ui.warn(f"kept {d}/: {exc.strerror} (files not created by setup.sh are never deleted)")
    print("\n  " + ui.c("Uninstalled.", "green") + " Host is back to its pre-setup state (see skipped items above).")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    argv = normalize_argv(list(sys.argv[1:] if argv is None else argv))
    args = build_parser().parse_args(argv)
    if args.no_color:
        ui.set_color(False)
    try:
        app = App(args)
        if args.cmd == "preflight":
            _, _, _, checks = cmd_preflight(app, ask=False)  # read-only, no questions
            return 1 if pf.failed(checks) else 0
        return {"install": cmd_install, "status": cmd_status, "verify": cmd_verify,
                "uninstall": cmd_uninstall}[args.cmd](app)
    except (ConfigError, ManifestError) as exc:
        ui.error(str(exc))
        return 2
    except KeyboardInterrupt:
        ui.warn("interrupted")
        return 130
