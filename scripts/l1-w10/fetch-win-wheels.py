#!/usr/bin/env python3
"""Download pinned Windows wheels from PyPI (JSON API, no pip needed) for an offline wheelhouse.

Run on any machine with internet (not the L2). Picks a `py3-none-any` wheel or one matching
--tag (default cp312-cp312-win_amd64), verifies PyPI's sha256, and writes SHA256SUMS-deps.txt.
The CUDA torch wheel itself comes from download.pytorch.org and is staged separately
(e.g. `pip download torch==2.6.0+cu124 --index-url https://download.pytorch.org/whl/cu124
--platform win_amd64 --python-version 3.12 --only-binary=:all: --no-deps`).

Default pins = the dependency set torch 2.6.0+cu124 resolved to on 2026-10-05.

    fetch-win-wheels.py -o wheelhouse
    fetch-win-wheels.py -o wheelhouse numpy==2.3.4
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import urllib.request

DEFAULT_PINS = [
    "filelock==4.0.12", "typing-extensions==4.16.0", "networkx==3.7", "jinja2==3.1.6",
    "fsspec==2026.9.0", "setuptools==84.0.0", "sympy==1.13.1", "mpmath==1.3.0",
    "markupsafe==3.0.4",
]


def pick(files: list[dict], tag: str) -> dict | None:
    whls = [f for f in files if f["filename"].endswith(".whl")]
    for f in whls:
        if tag in f["filename"]:
            return f
    for f in whls:
        if f["filename"].endswith("py3-none-any.whl"):
            return f
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("-o", "--out", default="wheelhouse")
    ap.add_argument("--tag", default="cp312-cp312-win_amd64")
    ap.add_argument("pins", nargs="*", help="name==version (default: torch 2.6.0 deps)")
    a = ap.parse_args()
    pins = a.pins or DEFAULT_PINS
    os.makedirs(a.out, exist_ok=True)
    sums = []
    for pin in pins:
        name, _, ver = pin.partition("==")
        if not ver:
            print(f"pin must be name==version: {pin}", file=sys.stderr)
            return 2
        with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/{ver}/json", timeout=60) as r:
            meta = json.load(r)
        f = pick(meta["urls"], a.tag)
        if f is None:
            print(f"no wheel for {pin} ({a.tag} or py3-none-any)", file=sys.stderr)
            return 1
        with urllib.request.urlopen(f["url"], timeout=300) as r:
            data = r.read()
        digest = hashlib.sha256(data).hexdigest()
        if digest != f["digests"]["sha256"]:
            print(f"sha256 mismatch for {f['filename']}", file=sys.stderr)
            return 1
        with open(os.path.join(a.out, f["filename"]), "wb") as fh:
            fh.write(data)
        sums.append(f"{digest}  {f['filename']}\n")
        print(digest, f["filename"], len(data))
    with open(os.path.join(a.out, "SHA256SUMS-deps.txt"), "w") as fh:
        fh.writelines(sums)
    return 0


if __name__ == "__main__":
    sys.exit(main())
