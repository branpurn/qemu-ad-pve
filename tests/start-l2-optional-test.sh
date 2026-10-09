#!/usr/bin/env bash
# Offline check of the optional MACHINE/OVMF_* handling in scripts/l1-w10/start-l2.sh: defaults must stay
# exactly `-machine q35,accel=kvm` and the stock firmware paths; the opt-in vars must be honoured.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
f=$here/scripts/l1-w10/start-l2.sh
bash -n "$f"
blk=$(sed -n '/^MACHINE="q35,accel=kvm"/,/^OVMF_VARS=/p' "$f")
[ -n "$blk" ] || { echo "FAIL: MACHINE block not found"; exit 1; }
run() { env -i bash -c "$1; $blk; printf '%s|%s|%s' \"\$MACHINE\" \"\$OVMF_CODE\" \"\$OVMF_VARS\""; }
got=$(run ':')
[ "$got" = "q35,accel=kvm|/root/l2/OVMF_CODE.fd|/root/w10/VARS.fd" ] || { echo "FAIL default: $got"; exit 1; }
got=$(run "OEM_ID=ALASKA; OEM_TABLE_ID='A M I   '; OEM_REVISION=0x1072009; OVMF_CODE=/opt/x/C.fd")
[ "$got" = "q35,accel=kvm,x-oem-id=ALASKA,x-oem-table-id=A M I   ,x-oem-revision=0x1072009|/opt/x/C.fd|/root/w10/VARS.fd" ] || { echo "FAIL opt-in: $got"; exit 1; }
grep -q -- '-machine "\$MACHINE"' "$f" && grep -q 'file="\$OVMF_CODE"' "$f" && grep -q 'file="\$OVMF_VARS"' "$f" || { echo "FAIL exec line"; exit 1; }
echo "start-l2-optional-test: ok"
