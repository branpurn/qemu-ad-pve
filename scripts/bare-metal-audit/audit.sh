#!/bin/bash
# shellcheck shell=bash
# Bare-metal appearance audit, driven from L1: `qad-l1.sh audit` (host: `./setup.sh audit`, opt-in, read-only).
# Collects facts in L1 and (over SSH) in the L2, then compares them with the configuration in
# /etc/qemu-ad/setup.env. Sourced by qad-l1.sh (step_audit), which provides W, ENVF, AUD, l2_ssh and l2_scp.
: "${AUD:?run through qad-l1.sh audit}"
T=$(mktemp -d)
bash "$AUD/l1-facts.sh" >"$T/l1.txt" 2>/dev/null || true
: >"$T/l2.txt"
if l2_ssh 'exit 0' >/dev/null 2>&1; then
  l2_ssh 'if not exist C:\qad\audit mkdir C:\qad\audit' >/dev/null 2>&1 || true
  if l2_scp "$AUD/l2-facts.ps1" "$AUD/l2-facts.py" 'C:/qad/audit/' >/dev/null 2>&1; then
    l2_ssh 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\qad\audit\l2-facts.ps1' 2>/dev/null | tr -d '\r' >>"$T/l2.txt" || true
    l2_ssh 'C:\qad\venv\Scripts\python.exe C:\qad\audit\l2-facts.py' 2>/dev/null | tr -d '\r' >>"$T/l2.txt" || true
  fi
else
  echo "AUDIT: L2 not reachable over SSH; only the L1 checks run" >&2
fi
cp "$T/l1.txt" "$W/audit-l1.txt" 2>/dev/null || true; cp "$T/l2.txt" "$W/audit-l2.txt" 2>/dev/null || true
audit_rc=0
python3 "$AUD/evaluate.py" --env "${ENVF:-/etc/qemu-ad/setup.env}" --facts "$T/l1.txt" --facts "$T/l2.txt" || audit_rc=$?
rm -rf "$T"
return "$audit_rc"
