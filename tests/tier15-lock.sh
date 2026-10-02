#!/bin/bash
# Tier 1.5: run `uninstall` while another process holds the dpkg locks (as fcntl locks, the way dpkg takes them).
# Acceptable outcomes: (a) uninstall succeeds: /usr/bin/kvm is the vendor file again and the divert is gone, or
# (b) uninstall fails: the wrapper is byte-identical and the divert is intact. /usr/bin/kvm must stay executable.
# SAFETY: runs REAL dpkg and rewrites /usr/bin/kvm. Only as root inside a disposable root; see tests/README.md ("Tier 1.5").
# Needs QAD_T15_SANDBOX=1. Env: QAD_SCRIPT. STRICT_WINDOW=1 also FAILs if kvm was seen missing (known few-ms window).
# shellcheck disable=SC2086  # $TMPD comes from mktemp (no whitespace); lock lists are deliberately split
source "$(dirname "${BASH_SOURCE[0]}")/tier15-common.sh"
t15_guard; t15_init
mkdeb 2.0
export PATH=/usr/sbin:/usr/bin
sed '$d' "$QAD_SCRIPT" > "$TMPD/lib.sh"
R(){ env -u WRAPPER_PATH -u VENDOR_PATH -u SIDE_BIN -u LIST_FILE -u LOG_FILE bash -c "source $TMPD/lib.sh; set -euo pipefail; PREFIX=/opt/qemu-ad; $1"; }
dpkg -i "$DEBDIR/pve-qemu-kvm_2.0.deb" >/dev/null 2>&1
mkdir -p /opt/qemu-ad/bin; printf '#!/bin/sh\n' > /opt/qemu-ad/bin/qemu-system-x86_64; chmod +x /opt/qemu-ad/bin/qemu-system-x86_64
holder() { local f; for f in "$@"; do fcntl_hold "$f" 12 & done; sleep 0.3; echo held; wait; }
for L in "/var/lib/dpkg/lock-frontend" "/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock" "/var/lib/dpkg/lock"; do
  dpkg-divert --list /usr/bin/kvm | grep -q . || R install_wrapper >/dev/null 2>&1
  W=$(sha256sum /usr/bin/kvm|cut -c1-12)
  # shellcheck disable=SC2086  # $L is deliberately a space-separated list of lock files
  holder $L > "$TMPD/h.out" & sleep 1.5; cat "$TMPD/h.out"
  ( while :; do [[ -x /usr/bin/kvm ]] || { echo MISSING; break; }; sleep 0.02; done ) > "$TMPD/w.out" & wp=$!
  R uninstall > "$TMPD/u.out" 2>&1; rc=$?
  kill $wp 2>/dev/null; wait $wp 2>/dev/null
  missing=$(cat "$TMPD/w.out"); nd=$(dpkg-divert --list /usr/bin/kvm | wc -l)
  hash_same=n; [[ $(sha256sum /usr/bin/kvm | cut -c1-12) == "$W" ]] && hash_same=y
  info="uninstall rc=$rc kvm_exec=$([[ -x /usr/bin/kvm ]] && echo y || echo n) wrapper_hash_same=$hash_same divert_lines=$nd missing_seen=${missing:-no} last: $(tail -1 "$TMPD/u.out")"
  if [[ ! -x /usr/bin/kvm ]]; then res FAIL "lock[$L]: /usr/bin/kvm not executable afterwards: $info"
  elif [[ $rc -eq 0 && $nd -eq 0 && $hash_same == n ]]; then res PASS "lock[$L]: uninstall succeeded (dpkg-divert does not take the dpkg lock): $info"
  elif [[ $rc -ne 0 && $nd -ge 1 && $hash_same == y ]]; then res PASS "lock[$L]: uninstall failed cleanly, wrapper restored, divert intact: $info"
  else res FAIL "lock[$L]: inconsistent state after uninstall: $info"; fi
  if [[ -n $missing ]]; then
    if [[ ${STRICT_WINDOW:-} == 1 ]]; then res FAIL "lock[$L]: /usr/bin/kvm was seen missing"; else res INFO "lock[$L]: /usr/bin/kvm was seen missing (known few-ms window; STRICT_WINDOW=1 makes this a FAIL)"; fi
  fi
  wait
done
t15_finish
