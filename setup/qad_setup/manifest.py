"""Manifest of everything the setup created on the PVE host, and uninstall planning.

The manifest (/var/lib/qemu-ad/manifest.json) is the *only* source for `uninstall`:
nothing that is not listed there is ever removed. Planning is pure (facts are passed
in) so it is unit-tested; execution lives in cli.py.

Entry kinds:
  vm      {"vmid", "marker"}            the L1 VM (and with it its disks: root, EFI, Windows)
  volume  {"volid", "path", "sha256"}   a file inside a PVE storage (cloud-init seed ISO, hookscript)
  file    {"path", "sha256"}            a plain host file under /var/lib/qemu-ad/setup
  dir     {"path"}                      a directory we created (removed only if empty)
"""
from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, List, Optional

MANIFEST_PATH = "/var/lib/qemu-ad/manifest.json"
SAFE_PREFIXES = ("/var/lib/qemu-ad/",)
FORMAT = 1


class ManifestError(RuntimeError):
    pass


@dataclass
class Manifest:
    install_id: str
    entries: List[Dict[str, str]] = field(default_factory=list)
    created: str = ""
    path: str = MANIFEST_PATH

    # -------------------------------------------------------------- persistence
    @classmethod
    def load(cls, path: str = MANIFEST_PATH) -> Optional["Manifest"]:
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except FileNotFoundError:
            return None
        except (OSError, ValueError) as exc:
            raise ManifestError(f"cannot read {path}: {exc}") from None
        if data.get("format") != FORMAT:
            raise ManifestError(f"{path}: unknown manifest format {data.get('format')!r}")
        return cls(install_id=data["install_id"], entries=list(data.get("entries", [])),
                   created=data.get("created", ""), path=path)

    def to_json(self) -> str:
        return json.dumps({"format": FORMAT, "install_id": self.install_id, "created": self.created,
                           "entries": self.entries}, indent=2, sort_keys=True) + "\n"

    def save(self) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(self.to_json())
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    # -------------------------------------------------------------- recording
    def add(self, kind: str, **fields: str) -> Dict[str, str]:
        if kind not in ("vm", "volume", "file", "dir"):
            raise ManifestError(f"unknown entry kind {kind!r}")
        key = _identity(kind, fields)
        for e in self.entries:
            if _identity(e["kind"], e) == key:
                e.update({k: str(v) for k, v in fields.items()})
                return e
        entry = {"kind": kind, "added": time.strftime("%Y-%m-%dT%H:%M:%S%z"), **{k: str(v) for k, v in fields.items()}}
        if kind in ("file", "dir") and not (entry["path"].startswith(SAFE_PREFIXES)
                                            or entry["path"] + "/" in SAFE_PREFIXES):
            raise ManifestError(f"refusing to record {entry['path']}: host files must live under {SAFE_PREFIXES}")
        self.entries.append(entry)
        return entry

    def has(self, kind: str, **fields: str) -> bool:
        key = _identity(kind, fields)
        return any(_identity(e["kind"], e) == key for e in self.entries)

    def vm(self) -> Optional[Dict[str, str]]:
        return next((e for e in self.entries if e["kind"] == "vm"), None)


def _identity(kind: str, fields: Dict[str, str]) -> str:
    if kind == "vm":
        return f"vm:{fields['vmid']}"
    if kind == "volume":
        return f"volume:{fields['volid']}"
    return f"{kind}:{fields['path']}"


def vm_marker(install_id: str) -> str:
    return f"qemu-ad-pve-setup:{install_id}"


# ------------------------------------------------------------------ uninstall planning
@dataclass
class Action:
    kind: str  # run | rm | rmdir | skip
    target: str
    argv: List[str] = field(default_factory=list)
    reason: str = ""

    def describe(self) -> str:
        if self.kind == "run":
            return " ".join(self.argv)
        if self.kind == "rm":
            return f"rm -f {self.target}"
        if self.kind == "rmdir":
            return f"rmdir {self.target}  (only if empty)"
        return f"SKIP {self.target}: {self.reason}"


@dataclass
class HostFacts:
    """What uninstall needs to know about the host (collected live, or faked in tests)."""
    vm_status: Callable[[str], Optional[str]]  # vmid -> "running"/"stopped"/None (absent)
    vm_description: Callable[[str], str]  # vmid -> description text of the VM config
    file_sha256: Callable[[str], Optional[str]]  # path -> sha256 or None if missing
    volume_exists: Callable[[str], bool]


def plan_uninstall(m: Manifest, facts: HostFacts, force: bool = False,
                   shutdown_timeout: int = 300) -> List[Action]:
    """Ordered actions that remove exactly what the manifest lists.

    Safety rules:
      * a VM is destroyed only if its config still carries our marker (the VMID may have
        been reused by someone else) - not even --force overrides this;
      * a file is removed only if its sha256 still matches what we wrote (else skipped,
        unless force);
      * directories are removed last, deepest first, and only when empty.
    """
    actions: List[Action] = []
    marker = vm_marker(m.install_id)
    for e in m.entries:
        if e["kind"] != "vm":
            continue
        vmid = e["vmid"]
        status = facts.vm_status(vmid)
        if status is None:
            actions.append(Action("skip", f"VM {vmid}", reason="does not exist any more"))
            continue
        if marker not in facts.vm_description(vmid):
            actions.append(Action("skip", f"VM {vmid}",
                                  reason=f"its description lacks the marker {marker!r}; not ours, not touched"))
            continue
        if status == "running":
            actions.append(Action("run", f"VM {vmid}", ["qm", "shutdown", vmid, "--timeout", str(shutdown_timeout),
                                                        "--forceStop", "1"], "clean ACPI shutdown (L2 first)"))
        actions.append(Action("run", f"VM {vmid}", ["qm", "destroy", vmid, "--purge", "1",
                                                    "--destroy-unreferenced-disks", "1"],
                              "removes the VM config and ALL its disks (incl. the Windows disk)"))
    for e in m.entries:
        if e["kind"] == "volume":
            volid = e["volid"]
            if not facts.volume_exists(volid):
                actions.append(Action("skip", volid, reason="already gone"))
                continue
            want = e.get("sha256")
            have = facts.file_sha256(e["path"]) if e.get("path") else None
            if want and have and want != have and not force:
                actions.append(Action("skip", volid, reason="content changed since setup wrote it (use --force)"))
                continue
            actions.append(Action("run", volid, ["pvesm", "free", volid], "setup-created storage file"))
    for e in m.entries:
        if e["kind"] == "file":
            path = e["path"]
            have = facts.file_sha256(path)
            if have is None:
                actions.append(Action("skip", path, reason="already gone"))
                continue
            want = e.get("sha256")
            if want and want != have and not force:
                actions.append(Action("skip", path, reason="content changed since setup wrote it (use --force)"))
                continue
            actions.append(Action("rm", path))
    dirs = sorted((e["path"] for e in m.entries if e["kind"] == "dir"), key=lambda p: p.count("/"), reverse=True)
    for d in dirs:
        actions.append(Action("rmdir", d))
    return actions
