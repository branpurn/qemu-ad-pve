#!/bin/bash
# Tier 1.5: poll /usr/bin/kvm in a tight loop while `install_wrapper` and `uninstall` run (6 rounds) and report how many
# polls saw it missing. A few-ms window between `dpkg-divert --rename` and the final `mv` is a known low-severity finding, so
# by default missing polls are reported as INFO; STRICT_WINDOW=1 turns them into FAIL.
# SAFETY: runs REAL dpkg and rewrites /usr/bin/kvm. Only as root inside a disposable root; see tests/README.md ("Tier 1.5").
# Needs QAD_T15_SANDBOX=1. Env: QAD_SCRIPT, STRICT_WINDOW.
# shellcheck disable=SC2086  # $TMPD comes from mktemp (no whitespace); lock lists are deliberately split
source "$(dirname "${BASH_SOURCE[0]}")/tier15-common.sh"
t15_guard; t15_init
mkdeb 2.0
export PATH=/usr/sbin:/usr/bin
sed '$d' "$QAD_SCRIPT" > "$TMPD/lib.sh"
R(){ env -u WRAPPER_PATH -u VENDOR_PATH -u SIDE_BIN -u LIST_FILE -u LOG_FILE bash -c "source $TMPD/lib.sh; set -euo pipefail; PREFIX=/opt/qemu-ad; $1"; }
dpkg -i "$DEBDIR/pve-qemu-kvm_2.0.deb" >/dev/null 2>&1
mkdir -p /opt/qemu-ad/bin; printf '#!/bin/sh\n' > /opt/qemu-ad/bin/qemu-system-x86_64; chmod +x /opt/qemu-ad/bin/qemu-system-x86_64
cat > $TMPD/watch.py <<'P'
import os,time,sys
miss=0;n=0;t0=None
end=time.time()+float(sys.argv[1])
while time.time()<end:
    n+=1
    if not os.path.exists('/usr/bin/kvm'):
        miss+=1
print(f"polls={n} missing_polls={miss}")
P
chk_window() { # <label> <file>
  local line miss; line=$(cat "$2"); miss=${line##*missing_polls=}
  if [[ -z $line || ! $miss =~ ^[0-9]+$ ]]; then res FAIL "$1: no poll result ($line)"
  elif [[ $miss -eq 0 ]]; then res PASS "$1: $line"
  elif [[ ${STRICT_WINDOW:-} == 1 ]]; then res FAIL "$1: $line"
  else res INFO "$1: $line (known few-ms window)"; fi
}
for round in 1 2 3 4 5 6; do
  python3 "$TMPD/watch.py" 3 > "$TMPD/w.i" & sleep 0.3; R install_wrapper >/dev/null 2>&1; wait; chk_window "install round $round" "$TMPD/w.i"
  python3 "$TMPD/watch.py" 3 > "$TMPD/w.u" & sleep 0.3; R uninstall >/dev/null 2>&1; wait; chk_window "uninstall round $round" "$TMPD/w.u"
done
t15_finish
