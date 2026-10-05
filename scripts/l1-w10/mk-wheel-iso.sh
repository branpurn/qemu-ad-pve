#!/bin/bash
# Build a read-only "wheel disk" ISO inside L1 for an offline Windows L2 started with
# /root/w10/start-l2.sh (qemu-ad-pve has no SLIRP / -netdev user, so the L2 cannot pip from
# the internet). Attach the ISO as a CD-ROM via start-l2.sh's EXTRA hook.
#
# Usage: mk-wheel-iso.sh <wheelhouse-dir> [extra-file ...]
#   <wheelhouse-dir>  *.whl (+ optional SHA256SUMS* files, verified before packing)
#   extra-file        copied to the ISO root (e.g. install-offline.cmd, pytorch-offline-bench.py)
#   OUT=...           output path (default /root/w10/wheels.iso)
#
# Staging happens next to OUT (not in /tmp, which is tmpfs on L1 and a multi-GB wheel would
# eat RAM). Needs genisoimage. Files up to 4 GiB fit in one ISO9660 extent; Windows reads the
# Joliet names (torch wheel names are < 64 chars, -joliet-long allows up to 103).
set -euo pipefail
WH=${1:?usage: mk-wheel-iso.sh <wheelhouse-dir> [extra-file ...]}
shift
OUT=${OUT:-/root/w10/wheels.iso}
command -v genisoimage >/dev/null || { echo "genisoimage not found" >&2; exit 2; }
compgen -G "$WH/*.whl" >/dev/null || { echo "no .whl files in $WH" >&2; exit 3; }

STAGE=$(mktemp -d "$(dirname "$OUT")/wheelstage.XXXXXX")
trap 'rm -rf "$STAGE" "$OUT.tmp"' EXIT
mkdir "$STAGE/wheelhouse"
cp -- "$WH"/*.whl "$STAGE/wheelhouse/"
for s in "$WH"/SHA256SUMS*; do
  if [ -e "$s" ]; then cp -- "$s" "$STAGE/wheelhouse/"; fi
done
(
  cd "$STAGE/wheelhouse"
  for s in SHA256SUMS*; do
    if [ -e "$s" ]; then sha256sum -c "$s"; fi
  done
)
for f in "$@"; do cp -- "$f" "$STAGE/"; done

genisoimage -quiet -o "$OUT.tmp" -V WHEELS -J -joliet-long -R -iso-level 3 "$STAGE"
mv -- "$OUT.tmp" "$OUT"
sha256sum -- "$OUT"
cat <<MSG
Attach to the L2 (start-l2.sh splits EXTRA on spaces, so no spaces in the path):
  EXTRA="-drive file=$OUT,format=raw,if=none,id=whl,media=cdrom,readonly=on -device ide-cd,drive=whl,bus=ide.2" /root/w10/start-l2.sh
MSG
