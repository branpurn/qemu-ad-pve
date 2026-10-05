#!/usr/bin/env python3
"""check-new-kernel.py - report Proxmox kernel releases newer than a baseline.

Read-only and public: downloads the Packages index of the Proxmox VE apt
repository (default suite: trixie / pve-no-subscription) and lists
`proxmox-kernel-<X.Y.Z>-<N>-pve` packages. It does not install anything and
does not touch any Proxmox host; it only talks to download.proxmox.com.

    tools/check-new-kernel.py                      # baseline from tools/pve-kernel-baseline.txt
    tools/check-new-kernel.py --suite pvetest --baseline 7.0.14-20
    tools/check-new-kernel.py --packages-file Packages.gz   # offline (tests)

Exit status: 0 = nothing new, 10 = new version(s) found, 1 = error.
With --github-output FILE it appends `new=true|false`, `latest=<ver>` and
`list=<comma list>` for GitHub Actions.
"""
from __future__ import annotations

import argparse
import gzip
import io
import pathlib
import re
import sys
import urllib.request

BASE = "http://download.proxmox.com/debian/pve/dists"
PKG_RE = re.compile(r"^Package: proxmox-kernel-(\d+\.\d+\.\d+-\d+)-pve$", re.M)
HERE = pathlib.Path(__file__).resolve().parent


def vkey(v: str) -> tuple[int, ...]:
    return tuple(int(x) for x in re.split(r"[.-]", v))


def parse_packages(data: bytes) -> list[str]:
    """Return sorted unique kernel versions ('7.0.14-20') from a Packages(.gz) blob."""
    if data[:2] == b"\x1f\x8b":
        data = gzip.GzipFile(fileobj=io.BytesIO(data)).read()
    text = data.decode("utf-8", "replace")
    return sorted(set(PKG_RE.findall(text)), key=vkey)


def newer_than(versions: list[str], baseline: str) -> list[str]:
    return [v for v in versions if vkey(v) > vkey(baseline)]


def fetch(distro: str, suite: str) -> bytes:
    url = f"{BASE}/{distro}/{suite}/binary-amd64/Packages.gz"
    req = urllib.request.Request(url, headers={"User-Agent": "separate-kvm-feasibility/kernel-watch"})
    with urllib.request.urlopen(req, timeout=60) as resp:  # noqa: S310 (fixed https/http host)
        return resp.read()


def upstream(v: str) -> str:
    """'7.0.14-20' -> '7.0.14' (the version to give dkms/fetch-kvm-source.sh; Proxmox adds patches)."""
    return v.rsplit("-", 1)[0]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--distro", default="trixie")
    ap.add_argument("--suite", default="pve-no-subscription")
    ap.add_argument("--baseline", help="newest version already handled (default: tools/pve-kernel-baseline.txt)")
    ap.add_argument("--packages-file", help="read this Packages(.gz) instead of downloading")
    ap.add_argument("--github-output", help="append step outputs to this file")
    args = ap.parse_args(argv)

    baseline = args.baseline or (HERE / "pve-kernel-baseline.txt").read_text().split()[0]
    if not re.fullmatch(r"\d+\.\d+\.\d+-\d+", baseline):
        print(f"bad baseline {baseline!r}", file=sys.stderr)
        return 1
    try:
        data = pathlib.Path(args.packages_file).read_bytes() if args.packages_file else fetch(args.distro, args.suite)
        versions = parse_packages(data)
    except OSError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if not versions:
        print("error: no proxmox-kernel-*-pve packages found in the index", file=sys.stderr)
        return 1
    new = newer_than(versions, baseline)
    print(f"suite {args.distro}/{args.suite}: newest {versions[-1]}, baseline {baseline}")
    if new:
        print("NEW proxmox-kernel versions: " + ", ".join(new))
        print(f"upstream base of newest: {upstream(new[-1])} "
              "(Proxmox kernels are Ubuntu-derived and carry extra patches; a mainline tag is only an approximation)")
    else:
        print("nothing new")
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as fh:
            fh.write(f"new={'true' if new else 'false'}\n")
            fh.write(f"latest={versions[-1]}\n")
            fh.write(f"list={','.join(new)}\n")
    return 10 if new else 0


if __name__ == "__main__":
    sys.exit(main())
