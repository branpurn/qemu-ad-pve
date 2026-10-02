#!/bin/bash
# qemu-ad-breakglass.sh - standalone, idempotent back-out of what qemu-ad-pve.sh installs.
#
# Use it when `qemu-ad-pve.sh uninstall` cannot be used (the script or its repo is gone, the divert
# is half-applied, pve-qemu-kvm was removed while diverted, ...). It does not need qemu-ad-pve.sh.
#
# DRY-RUN IS THE DEFAULT. Nothing is changed, created or written (no log file, no pre-state) unless you
# pass --apply. A dry run only reads the system and prints what an --apply run would do.
#
# What --apply does (every step is a no-op if already done):
#   1. Optional, and only on a dedicated TEST node: destroys the VMs listed in QAD_BREAKGLASS_VMIDS. This needs ALL of:
#        - the --destroy-vms flag AND a non-empty QAD_BREAKGLASS_VMIDS (either one alone is refused);
#        - QAD_PROTECTED_VMIDS (space-separated VMIDs, or the word `none`); refuses on any overlap;
#        - QAD_BREAKGLASS_TEST_HOSTNAME equal to this node's `hostname`, `qm list` readable, the node not in a
#          cluster, and EVERY VM on the node named in one of the two lists (an unlisted VM refuses the run);
#        - a typed confirmation (see below) that only a person at a terminal can give.
#      Each VM must be provably `stopped` (status read successfully) right before `qm destroy`; any `qm` error
#      stops the run with exit 1 and the kvm wrapper is not touched. A VM with PVE's own `protection` flag is NOT
#      destroyed unless you ALSO pass --clear-vm-protection (that flag is never implied by anything else).
#   2. Restores the real kvm binary: removes qemu-ad-pve's dpkg divert and puts the vendor file (VENDOR_PATH)
#      back over the wrapper (WRAPPER_PATH). If the vendor file is missing it reinstalls pve-qemu-kvm via apt;
#      as a last resort it symlinks WRAPPER_PATH to the packaged qemu-system-x86_64 next to it.
#      A divert that is not ours is left alone.
#   3. Only if step 2 left a real kvm binary: removes the VMID list, the wrapper log, the side-QEMU prefix and
#      the build tree (use --keep-build to keep the prefix and sources). The prefix is only deleted if it looks like
#      ours (contains bin/qemu-system-x86_64 or .qemu-ad-configure-flags, or is empty).
#   4. Verifies the end state and prints a PASS/FAIL report. Exit 0 only if everything passes.
# It never reboots, never touches a VM that is not in QAD_BREAKGLASS_VMIDS, never touches PCI devices, and
# refuses to write to a block or character device (or anything under /dev, /proc, /sys).
#
# Typed confirmation (--apply with --destroy-vms): the script prints a phrase that contains a fresh random token,
#   destroy <vmids> on <hostname> <token>
# and reads your answer from the controlling terminal (/dev/tty). It refuses to run when stdin is not a terminal,
# so `yes | ...`, `< /dev/null` and cron/ssh-without-tty cannot answer it. A wrong answer exits 2 before any change.
#
# Usage: qemu-ad-breakglass.sh [--apply] [--keep-build] [--capture-prestate [--force-prestate]] [--verify]
#                              [--destroy-vms [--clear-vm-protection]]
#   (no option)         dry run: print the plan and the CURRENT state report; change nothing; exit 0
#   --apply             actually make the changes (root required)
#   --dry-run           same as the default; refused together with --apply
#   --keep-build        keep PREFIX and the sources under SRC_ROOT
#   --destroy-vms       allow step 1 (see above). Without it a set QAD_BREAKGLASS_VMIDS is an error, not a hint.
#   --clear-vm-protection  with --destroy-vms only: also clear a destroy-target's PVE `protection` flag
#   --capture-prestate  write a read-only snapshot of VM status/config and package/divert state to
#                       $STATE_DIR/pre-state, then exit (needs --apply to write; refuses to overwrite an
#                       existing one unless --force-prestate; FAILS, writing nothing, if any `qm` call fails).
#                       If it exists, the verifier compares the protected VMs' status and PIDs with it.
#   --verify            only run the end-state report (read-only); exit 1 if any check fails
#   -h, --help          this text
#
# Environment (same names and defaults as qemu-ad-pve.sh):
#   PREFIX (/opt/qemu-ad)  SRC_ROOT (/opt/src)  QEMU_VER (10.2.2)  LIST_FILE (/etc/qemu-ad/vms)
#   WRAPPER_PATH (/usr/bin/kvm)  VENDOR_PATH (/usr/bin/kvm.pve)  LOG_FILE (/var/log/qemu-ad-wrapper.log)
#   DPKG_LOCK (/var/lib/dpkg/lock-frontend)  PVE_QEMU_CONF_DIR (/etc/pve/qemu-server)
# Break-glass only:
#   QAD_BREAKGLASS_VMIDS     VMIDs to destroy (default: none). Digits only, space separated. Needs --destroy-vms.
#   QAD_PROTECTED_VMIDS      VMIDs that must never be touched, or `none`. Required when QAD_BREAKGLASS_VMIDS is set.
#   QAD_BREAKGLASS_TEST_HOSTNAME  must equal `hostname` when destroying VMs (declares "this is a test node").
#   QAD_BREAKGLASS_STATE_DIR run log, saved VM configs, pre-state (default /var/lib/qemu-ad-breakglass).
#   QAD_PID_DIR              where qemu-server keeps <vmid>.pid (default /var/run/qemu-server).
#   QAD_BREAKGLASS_POLL_SECS seconds between the 30 checks that a stopped VM is really down (default 2).
#   QAD_BREAKGLASS_SANDBOX   test hook: an absolute directory. Allows --apply without root, but then EVERY path
#                            above (after resolving symlinks) must lie inside it. Use it for rehearsals only.
#   QAD_BREAKGLASS_TTY, QAD_BREAKGLASS_NONCE   test hooks, honoured ONLY together with QAD_BREAKGLASS_SANDBOX
#                            (and QAD_BREAKGLASS_TTY must be inside it): read the typed answer from that file / fix the token.
#
# The same allow-lists as `qemu-ad-pve.sh uninstall --purge` apply (outside a sandbox): PREFIX is a canonical
# directory below /opt, /srv or /usr/local (not a standard /usr/local subdirectory); LIST_FILE is a file below
# /etc/qemu-ad or /var/lib/qemu-ad. Paths may only contain letters, digits and . _ / + @ : - ; none of WRAPPER_PATH,
# VENDOR_PATH, LIST_FILE, LOG_FILE or the state dir may lie inside PREFIX or SRC_ROOT.
#
# Not undone: apt build dependencies (harmless) and VMs' own configs (qm config lines such as
# `cpu:`/`args:` that you set for the patch). Pre-state files may contain VM configs: the directory is mode 700.
set -u
set -f   # no pathname expansion anywhere; the few intended globs go through glob() below
export LC_ALL=C

PREFIX="${PREFIX:-/opt/qemu-ad}"
SRC_ROOT="${SRC_ROOT:-/opt/src}"
QEMU_VER="${QEMU_VER:-10.2.2}"
LIST_FILE="${LIST_FILE:-/etc/qemu-ad/vms}"
WRAPPER_PATH="${WRAPPER_PATH:-/usr/bin/kvm}"
VENDOR_PATH="${VENDOR_PATH:-/usr/bin/kvm.pve}"
LOG_FILE="${LOG_FILE:-/var/log/qemu-ad-wrapper.log}"
DPKG_LOCK="${DPKG_LOCK:-/var/lib/dpkg/lock-frontend}"
PVE_QEMU_CONF_DIR="${PVE_QEMU_CONF_DIR:-/etc/pve/qemu-server}"
VMIDS="${QAD_BREAKGLASS_VMIDS:-}"
PROTECTED="${QAD_PROTECTED_VMIDS:-}"
TEST_HOST="${QAD_BREAKGLASS_TEST_HOSTNAME:-}"
STATE_DIR="${QAD_BREAKGLASS_STATE_DIR:-/var/lib/qemu-ad-breakglass}"
PID_DIR="${QAD_PID_DIR:-/var/run/qemu-server}"
SANDBOX="${QAD_BREAKGLASS_SANDBOX:-}"
POLL="${QAD_BREAKGLASS_POLL_SECS:-2}"
[[ $POLL =~ ^[0-9]+$ ]] || { printf 'error: QAD_BREAKGLASS_POLL_SECS must be a whole number\n' >&2; exit 2; }
MARK='Generated by qemu-ad-pve'
PRE="$STATE_DIR/pre-state"
RUNLOG="$STATE_DIR/breakglass.log"

die() { printf 'error: %s\n' "$*" >&2; exit 2; }
usage() { sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }

APPLY=0; DRYFLAG=0; KEEP_BUILD=0; CAPTURE=0; FORCE_PRE=0; VERIFY_ONLY=0; DESTROY=0; CLEAR_PROT=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --dry-run|-n) DRYFLAG=1 ;;
    --keep-build) KEEP_BUILD=1 ;;
    --capture-prestate) CAPTURE=1 ;;
    --force-prestate) FORCE_PRE=1 ;;
    --verify) VERIFY_ONLY=1 ;;
    --destroy-vms) DESTROY=1 ;;
    --clear-vm-protection) CLEAR_PROT=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown option: %s\n' "$a" >&2; exit 2 ;;
  esac
done
((APPLY && DRYFLAG)) && die "--apply and --dry-run are mutually exclusive"
DRY=$((1 - APPLY))
((VERIFY_ONLY && APPLY)) && die "--verify is read-only; do not combine it with --apply"
((CLEAR_PROT && !DESTROY)) && die "--clear-vm-protection only makes sense together with --destroy-vms"

# ---------------------------------------------------------------- validation (before anything is touched)
PATHVARS=(PREFIX SRC_ROOT LIST_FILE WRAPPER_PATH VENDOR_PATH LOG_FILE DPKG_LOCK STATE_DIR PID_DIR PVE_QEMU_CONF_DIR)
canon() {  # canon <label> <path>: absolute, no "..", no "//", no trailing "/", no "." component, no odd characters
  case "$2" in
    /*) ;;
    *) die "refusing: $1=$2 is not an absolute path" ;;
  esac
  case "$2" in
    *..*|*//*|*/|*/./*|*/.) die "refusing: $1=$2 is not a canonical path (no '..', '//', trailing '/', '.' components)" ;;
  esac
  [[ $2 =~ ^[A-Za-z0-9._/+@:-]+$ ]] || die "refusing: $1=$2 is not a canonical path (only letters, digits and . _ / + @ : - are allowed)"
}
for n in "${PATHVARS[@]}"; do canon "$n" "${!n}"; done
[[ $QEMU_VER =~ ^[0-9][0-9A-Za-z._-]*$ ]] || die "refusing: QEMU_VER=$QEMU_VER has unexpected characters"
[[ $WRAPPER_PATH != "$VENDOR_PATH" ]] || die "refusing: WRAPPER_PATH and VENDOR_PATH are the same path"

# Never write to a block or character device (or a fifo/socket), and nothing under /dev, /proc, /sys: check every path
# we may create, rewrite, move onto or delete, and where it resolves.
devcheck() {
  local p r
  for p in "$WRAPPER_PATH" "$VENDOR_PATH" "${WRAPPER_PATH}.qemu-ad-new" "${WRAPPER_PATH}.bg-new" "$LIST_FILE" "$LOG_FILE" "$STATE_DIR" \
           "$RUNLOG" "$PRE" "$PREFIX" "$SRC_ROOT" "$DPKG_LOCK" "$PID_DIR" "$PVE_QEMU_CONF_DIR"; do
    r=$(readlink -m -- "$p" 2>/dev/null) || r=$p
    if [[ -b $p || -b $r ]]; then die "refusing: $p is (or resolves to) a block device"; fi
    if [[ -c $p || -c $r ]]; then die "refusing: $p is (or resolves to) a character device"; fi
    if [[ -p $p || -p $r || -S $p || -S $r ]]; then die "refusing: $p is (or resolves to) a fifo or socket"; fi
    case "$p" in /dev|/dev/*|/proc|/proc/*|/sys|/sys/*) die "refusing: $p is under /dev, /proc or /sys" ;; esac
    case "$r" in /dev|/dev/*|/proc|/proc/*|/sys|/sys/*) die "refusing: $p resolves under /dev, /proc or /sys ($r)" ;; esac
  done
}
devcheck

if [[ -n $SANDBOX ]]; then
  canon QAD_BREAKGLASS_SANDBOX "$SANDBOX"
  [[ $SANDBOX != / && -d $SANDBOX ]] || die "refusing: QAD_BREAKGLASS_SANDBOX=$SANDBOX must be an existing directory other than /"
  SBR=$(readlink -f -- "$SANDBOX") || die "refusing: cannot resolve QAD_BREAKGLASS_SANDBOX"
  for n in "${PATHVARS[@]}"; do
    p=${!n}; r=$(readlink -m -- "$p") || die "refusing: cannot resolve $n=$p"
    case "$p" in "$SANDBOX"/?*) ;; *) die "refusing: $n=$p is outside QAD_BREAKGLASS_SANDBOX=$SANDBOX" ;; esac
    case "$r" in "$SBR"/?*) ;; *) die "refusing: $n=$p resolves to $r, outside QAD_BREAKGLASS_SANDBOX=$SANDBOX" ;; esac
  done
else
  case "$PREFIX" in
    /usr/local/bin|/usr/local/sbin|/usr/local/lib|/usr/local/lib64|/usr/local/etc|/usr/local/share|/usr/local/include|/usr/local/src|/usr/local/man|/usr/local/games)
      die "refusing: PREFIX=$PREFIX is a system directory" ;;
    /opt/?*|/usr/local/?*|/srv/?*) ;;
    *) die "refusing: PREFIX=$PREFIX must be a directory below /opt, /usr/local or /srv" ;;
  esac
  case "$LIST_FILE" in
    /etc/qemu-ad/?*|/var/lib/qemu-ad/?*) ;;
    *) die "refusing: LIST_FILE=$LIST_FILE must be a file below /etc/qemu-ad or /var/lib/qemu-ad" ;;
  esac
  case "$SRC_ROOT" in /|/usr|/usr/*|/etc|/etc/*|/bin|/sbin|/lib*|/boot|/boot/*|/dev|/dev/*|/proc|/proc/*|/sys|/sys/*|/root|/home) die "refusing: SRC_ROOT=$SRC_ROOT is a system directory" ;; esac
fi
[[ ! -d $LIST_FILE ]] || die "refusing: LIST_FILE=$LIST_FILE is a directory"

# PREFIX and SRC_ROOT are removed recursively: nothing else we manage may live inside them, and they may not nest.
under() { [[ $1 == "$2" || $1 == "$2"/* ]]; }
RP_PREFIX=$(readlink -m -- "$PREFIX"); RP_SRC=$(readlink -m -- "$SRC_ROOT")
under "$RP_PREFIX" "$RP_SRC" && die "refusing: PREFIX=$PREFIX is inside (or equal to) SRC_ROOT=$SRC_ROOT"
under "$RP_SRC" "$RP_PREFIX" && die "refusing: SRC_ROOT=$SRC_ROOT is inside PREFIX=$PREFIX"
for n in WRAPPER_PATH VENDOR_PATH LIST_FILE LOG_FILE STATE_DIR DPKG_LOCK PID_DIR PVE_QEMU_CONF_DIR; do
  r=$(readlink -m -- "${!n}")
  under "$r" "$RP_PREFIX" && die "refusing: $n=${!n} lies inside PREFIX=$PREFIX, which is deleted recursively"
  under "$r" "$RP_SRC" && die "refusing: $n=${!n} lies inside SRC_ROOT=$SRC_ROOT"
done

# VMID lists: digits only (max 9), leading zeros normalised (07001 == 7001), sorted, unique
NORM=()
norm_ids() {  # norm_ids <label> <words...>: validates in THIS shell (die must exit the script), sets NORM
  local lbl=$1 v; shift; NORM=()
  for v in "$@"; do
    [[ $v =~ ^[0-9]{1,9}$ ]] || die "refusing: $lbl entry '$v' is not a number (1-9 digits)"
    NORM+=("$((10#$v))")
  done
  if ((${#NORM[@]})); then mapfile -t NORM < <(printf '%s\n' "${NORM[@]}" | sort -un); fi
}
read -ra _w <<<"$VMIDS"
norm_ids QAD_BREAKGLASS_VMIDS ${_w[@]+"${_w[@]}"}; VMID_A=("${NORM[@]}"); VMIDS="${VMID_A[*]-}"
PROT_SET=0; PROT_A=()
if [[ -n ${PROTECTED//[[:space:]]/} ]]; then
  PROT_SET=1
  if [[ ${PROTECTED//[[:space:]]/} != none ]]; then
    read -ra _w <<<"$PROTECTED"
    norm_ids QAD_PROTECTED_VMIDS "${_w[@]}"; PROT_A=("${NORM[@]}")
  fi
fi
PROTECTED="${PROT_A[*]-}"
if ((${#VMID_A[@]})); then
  ((PROT_SET)) || die "refusing: QAD_BREAKGLASS_VMIDS is set but QAD_PROTECTED_VMIDS is not; list the VMIDs to protect, or say 'none' explicitly"
  for v in "${VMID_A[@]}"; do
    for p in ${PROT_A[@]+"${PROT_A[@]}"}; do [[ $v == "$p" ]] && die "refusing: VMID $v is in both QAD_BREAKGLASS_VMIDS and QAD_PROTECTED_VMIDS"; done
  done
  if ((!VERIFY_ONLY && !CAPTURE)); then
    ((DESTROY)) || die "refusing: QAD_BREAKGLASS_VMIDS is set but --destroy-vms was not given (an inherited environment variable alone never destroys a VM)"
  fi
elif ((DESTROY && !VERIFY_ONLY && !CAPTURE)); then
  die "refusing: --destroy-vms was given but QAD_BREAKGLASS_VMIDS is empty"
fi

if ((APPLY)) && [[ -z $SANDBOX ]]; then
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "--apply needs root"
fi

# ---------------------------------------------------------------- logging / acting
LOG_READY=0
log() {
  local m; m="$(date '+%F %T') $*"
  printf '%s\n' "$m"
  ((LOG_READY)) && printf '%s\n' "$m" >> "$RUNLOG" 2>/dev/null
  return 0
}
# act <cmd...>: run it with --apply, otherwise only say what would run
act() {
  if ((DRY)); then log "DRY-RUN: $*"; return 0; fi
  log "+ $*"; "$@"
}
have() { command -v "$1" >/dev/null 2>&1; }
# glob <pattern>: the only place pathname expansion is switched on (set -f is the default). Patterns come from
# validated paths (no glob characters) plus a literal suffix. Prints matches, one per line; nothing if none.
glob() { set +f; compgen -G "$1" 2>/dev/null; set -f; }

# ---------------------------------------------------------------- probes (read-only)
is_elf() { [[ $(head -c4 -- "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n') == 7f454c46 ]]; }
is_wrapper_file() { [[ -f $1 ]] && grep -q -- "$MARK" "$1" 2>/dev/null; }
exists_or_link() { [[ -e $1 || -L $1 ]]; }
divert_list() { have dpkg-divert && dpkg-divert --list "$WRAPPER_PATH" 2>/dev/null; }
divert_ours() { local l; l=$(divert_list) || return 1; [[ $l == *" to ${VENDOR_PATH}"* ]]; }
divert_any()  { local l; l=$(divert_list) || return 1; [[ -n $l ]]; }
dpkg_lock_held() {
  local f="$1" ino
  [[ -e $f ]] || return 1
  ino=$(stat -c %i "$f") || return 1
  [[ -r /proc/locks ]] || return 1
  awk -v ino="$ino" '{ n = split($6, a, ":"); if (a[n] == ino) found = 1 } END { exit !found }' /proc/locks
}
vendor_resolves() {  # WRAPPER_PATH exists, resolves to a real ELF, and is not our wrapper
  [[ -e $WRAPPER_PATH ]] || return 1
  local r; r=$(readlink -f -- "$WRAPPER_PATH") || return 1
  is_elf "$r" && ! is_wrapper_file "$r"
}

# qm probes. Every one is tri-state: a failing or unparseable `qm` call is "error", never "absent"/"stopped".
qm_list_ids() {  # prints the VMIDs from `qm list`, one per line (possibly none); non-zero if qm failed or the output is not a list
  have qm || return 1
  local lst id
  lst=$(qm list 2>/dev/null) || return 1
  [[ $lst == *VMID* ]] || return 1
  while read -r id _; do
    [[ -n $id && $id != VMID ]] || continue
    [[ $id =~ ^[0-9]{1,9}$ ]] || return 1
    printf '%s\n' "$((10#$id))"
  done <<<"$lst"
}
vm_state() {  # exists | absent | error. `qm list` decides; `qm config` must agree when the VM is not listed.
  local ids
  ids=$(qm_list_ids) || { echo error; return 0; }
  if grep -qx -- "$((10#$1))" <<<"$ids"; then echo exists; return 0; fi
  if qm config "$1" >/dev/null 2>&1; then echo error; return 0; fi   # listed nowhere but has a config: inconsistent, do not guess
  echo absent
}
vm_status() {  # stopped | running | ... | error
  local o s
  have qm || { echo error; return 0; }
  o=$(qm status "$1" 2>/dev/null) || { echo error; return 0; }
  s=$(sed -n 's/^status: *\([a-z]*\)$/\1/p' <<<"$o" | head -n1)
  echo "${s:-error}"
}
vm_protection() {  # 0 | 1 | error
  local c
  have qm || { echo error; return 0; }
  c=$(qm config "$1" 2>/dev/null) || { echo error; return 0; }
  [[ $c == *[![:space:]]* ]] || { echo error; return 0; }
  if grep -q '^protection: 1' <<<"$c"; then echo 1; else echo 0; fi
}

# ---------------------------------------------------------------- pre-state capture
CAP_TMP=""
cap_abort() { [[ -n $CAP_TMP ]] && rm -rf -- "$CAP_TMP"; log "ERROR: $*; pre-state NOT written"; return 1; }
capture_prestate() {
  if [[ -d $PRE && $FORCE_PRE -eq 0 ]]; then log "pre-state already exists at $PRE (not overwriting; use --force-prestate)"; return 0; fi
  if ((DRY)); then log "DRY-RUN: would capture pre-state (qm list/config, package, divert, pid and directory info) into $PRE"; return 0; fi
  local lst id f
  have qm || { cap_abort "qm not found"; return 1; }
  CAP_TMP="$STATE_DIR/.pre-state.new.$$"
  rm -rf -- "$CAP_TMP"
  ( umask 077; mkdir -p "$CAP_TMP" ) || { cap_abort "cannot create $CAP_TMP"; return 1; }
  lst=$(qm list 2>&1) || { cap_abort "qm list failed"; return 1; }
  [[ $lst == *VMID* ]] || { cap_abort "qm list printed no VMID header"; return 1; }
  ( umask 077; printf '%s\n' "$lst" > "$CAP_TMP/qm-list.txt" ) || { cap_abort "cannot write qm-list.txt"; return 1; }
  while read -r id _; do
    [[ -n $id && $id != VMID ]] || continue
    [[ $id =~ ^[0-9]{1,9}$ ]] || { cap_abort "unparseable qm list row '$id'"; return 1; }
    ( umask 077; qm config "$id" > "$CAP_TMP/qm-config-$id.txt" 2>&1 ) || { cap_abort "qm config $id failed"; return 1; }
  done <<<"$lst"
  (
    umask 077
    { date -Is; hostname; } > "$CAP_TMP/captured-at.txt" 2>&1
    have dpkg && dpkg -l pve-qemu-kvm qemu-server pve-manager > "$CAP_TMP/dpkg-l.txt" 2>&1
    ls -l "$WRAPPER_PATH" "$VENDOR_PATH" > "$CAP_TMP/ls-kvm.txt" 2>&1
    sha256sum "$(readlink -f -- "$WRAPPER_PATH")" > "$CAP_TMP/sha256-kvm.txt" 2>&1
    divert_list > "$CAP_TMP/divert-kvm.txt" 2>&1
    have dpkg && dpkg -S "$WRAPPER_PATH" > "$CAP_TMP/dpkg-S-kvm.txt" 2>&1
    have pveversion && pveversion -v > "$CAP_TMP/pveversion.txt" 2>&1
    ls -l "$PVE_QEMU_CONF_DIR" > "$CAP_TMP/conf-dir.txt" 2>&1
    : > "$CAP_TMP/pids.txt"
    while IFS= read -r f; do [[ -e $f ]] && echo "$(basename "$f" .pid) $(cat "$f")" >> "$CAP_TMP/pids.txt"; done < <(glob "$PID_DIR/*.pid")
    ls -la "$(dirname "$LIST_FILE")" "$PREFIX" "$SRC_ROOT" > "$CAP_TMP/qemu-ad-dirs.txt" 2>&1
  )
  [[ ! -d $PRE ]] || rm -rf -- "$PRE"
  mv -T -- "$CAP_TMP" "$PRE" || { cap_abort "cannot move the snapshot into place"; return 1; }
  CAP_TMP=""
  log "pre-state captured in $PRE"
}

# ---------------------------------------------------------------- step 1: optional VM destruction (test nodes only)
HOSTN=""
destroy_gate() {  # refuses (exit 2) unless this is an explicitly declared, single, fully accounted-for test node
  [[ -n $TEST_HOST ]] || die "refusing to destroy VMs: QAD_BREAKGLASS_TEST_HOSTNAME is not set (set it to this test node's hostname)"
  HOSTN=$(hostname 2>/dev/null) || die "refusing to destroy VMs: cannot read this node's hostname"
  [[ -n $HOSTN && $HOSTN == "$TEST_HOST" ]] || die "refusing to destroy VMs: this node is '${HOSTN:-?}', not the declared test node (QAD_BREAKGLASS_TEST_HOSTNAME)"
  have qm || die "refusing to destroy VMs: qm not found (not a PVE node)"
  local ids id x known
  ids=$(qm_list_ids) || die "refusing to destroy VMs: 'qm list' failed or is unparseable; cannot verify which VMs exist on this node"
  for id in $ids; do
    known=0
    for x in "${VMID_A[@]}" ${PROT_A[@]+"${PROT_A[@]}"}; do [[ $id == "$x" ]] && known=1; done
    ((known)) || die "refusing to destroy VMs: VMID $id exists on this node but is in neither QAD_BREAKGLASS_VMIDS nor QAD_PROTECTED_VMIDS"
  done
  if have pvecm && pvecm status >/dev/null 2>&1; then die "refusing to destroy VMs: this node is in a cluster"; fi
  log "destroy gate ok on $HOSTN (VMs to destroy: $VMIDS; protected: ${PROTECTED:-none})"
}
confirm_destroy() {  # typed confirmation; only a person at a terminal can answer it
  local src nonce phrase ans
  if [[ -n $SANDBOX && -n ${QAD_BREAKGLASS_TTY:-} ]]; then
    canon QAD_BREAKGLASS_TTY "$QAD_BREAKGLASS_TTY"
    case "$QAD_BREAKGLASS_TTY" in "$SANDBOX"/?*) ;; *) die "refusing: QAD_BREAKGLASS_TTY is outside QAD_BREAKGLASS_SANDBOX" ;; esac
    src=$QAD_BREAKGLASS_TTY
    nonce=${QAD_BREAKGLASS_NONCE:-}
    [[ -z $nonce || $nonce =~ ^[0-9a-f]{8}$ ]] || die "refusing: QAD_BREAKGLASS_NONCE must be 8 hex digits"
  else
    [[ -t 0 && -t 2 ]] || die "refusing to destroy VMs: the typed confirmation needs an interactive terminal (stdin and stderr must be a tty; \`yes |\`, < /dev/null and cron cannot confirm)"
    src=/dev/tty
    nonce=""
  fi
  [[ -n $nonce ]] || nonce=$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
  [[ $nonce =~ ^[0-9a-f]{8}$ ]] || die "refusing: cannot generate a confirmation token"
  phrase="destroy ${VMIDS// /,} on $HOSTN $nonce"
  printf 'About to DESTROY VM(s) %s on %s (protected: %s). To continue type exactly:\n  %s\n> ' "$VMIDS" "$HOSTN" "${PROTECTED:-none}" "$phrase" >&2
  ans=""
  IFS= read -r -t 300 ans < "$src" || die "refusing: no typed confirmation received"
  [[ $ans == "$phrase" ]] || die "refusing: the typed confirmation did not match; nothing was changed"
  log "typed confirmation accepted"
}

vm_fail() { log "ERROR: $*"; return 1; }
step_vms() {
  local id st pr p t cfg
  if ((${#VMID_A[@]} == 0)); then log "--- step 1: no VMs to destroy (QAD_BREAKGLASS_VMIDS is empty)"; return 0; fi
  log "--- step 1: destroy VM(s) $VMIDS only (protected: ${PROTECTED:-none})"
  for id in "${VMID_A[@]}"; do
    for p in ${PROT_A[@]+"${PROT_A[@]}"}; do [[ $id == "$p" ]] && { log "BUG: $id is protected"; return 1; }; done
    st=$(vm_state "$id")
    [[ $st != error ]] || { vm_fail "cannot tell whether VM $id exists (a qm call failed); not touching it"; return 1; }
    # drop it from the list first, so a later failure cannot leave it routed to the side binary
    if [[ -f $LIST_FILE ]] && grep -qxE "[[:space:]]*${id}[[:space:]]*" "$LIST_FILE"; then
      if ((DRY)); then log "DRY-RUN: remove $id from $LIST_FILE"; else
        t=$(mktemp "${LIST_FILE}.XXXXXX") || { vm_fail "cannot create a temp file next to $LIST_FILE"; return 1; }
        grep -vxE "[[:space:]]*${id}[[:space:]]*" "$LIST_FILE" > "$t"; [[ $? -le 1 ]] || { rm -f "$t"; vm_fail "cannot rewrite $LIST_FILE"; return 1; }
        cat "$t" > "$LIST_FILE" || { rm -f "$t"; vm_fail "cannot rewrite $LIST_FILE"; return 1; }
        rm -f "$t"; log "removed $id from $LIST_FILE"
      fi
    else log "$id not in $LIST_FILE"; fi
    if [[ $st == absent ]]; then log "VM $id does not exist: nothing to do"; continue; fi
    if ((!DRY)); then
      cfg=$(qm config "$id" 2>&1) || { vm_fail "qm config $id failed; not destroying it"; return 1; }
      ( umask 077; mkdir -p "$STATE_DIR/saved" && printf '%s\n' "$cfg" > "$STATE_DIR/saved/${id}-config-$(date +%s).txt" ) || { vm_fail "cannot save the config of VM $id; not destroying it"; return 1; }
    else log "DRY-RUN: save the config of VM $id under $STATE_DIR/saved"; fi
    st=$(vm_status "$id")
    [[ $st != error ]] || { vm_fail "qm status $id failed; cannot tell whether it runs; not destroying it"; return 1; }
    if [[ $st != stopped ]]; then
      act qm stop "$id" --timeout 45 || { vm_fail "qm stop $id failed; not destroying it"; return 1; }
      if ((!DRY)); then
        for _ in $(seq 1 30); do st=$(vm_status "$id"); [[ $st == stopped ]] && break; sleep "$POLL"; done
        [[ $st == stopped ]] || { vm_fail "VM $id did not reach 'stopped' (status: $st); not destroying it"; return 1; }
      fi
    fi
    pr=$(vm_protection "$id")
    [[ $pr != error ]] || { vm_fail "cannot read the protection flag of VM $id (qm config failed); not destroying it"; return 1; }
    if [[ $pr == 1 ]]; then
      if ((CLEAR_PROT)); then
        act qm set "$id" --protection 0 || { vm_fail "qm set $id --protection 0 failed; not destroying it"; return 1; }
        if ((!DRY)); then [[ $(vm_protection "$id") == 0 ]] || { vm_fail "VM $id is still protected; not destroying it"; return 1; }; fi
      else
        vm_fail "VM $id has PVE's own protection flag set; not destroying it (pass --clear-vm-protection to override, deliberately)"; return 1
      fi
    fi
    if ((!DRY)); then
      [[ $(vm_status "$id") == stopped ]] || { vm_fail "VM $id is not confirmed stopped right before destroy; not destroying it"; return 1; }
    fi
    act qm destroy "$id" --purge 1 --destroy-unreferenced-disks 1 || { vm_fail "qm destroy $id failed"; return 1; }
    if ((!DRY)); then [[ $(vm_state "$id") == absent ]] || { vm_fail "VM $id is not confirmed gone after qm destroy"; return 1; }; fi
  done
  return 0
}
# ---------------------------------------------------------------- step 2: restore the vendor kvm
KVM_OK=1
step_kvm() {
  local f
  log "--- step 2: restore the real $WRAPPER_PATH"
  if ((!DRY)) && dpkg_lock_held "$DPKG_LOCK"; then
    log "ERROR: another package manager holds $DPKG_LOCK; wait for it to finish and run again"; KVM_OK=0; return 1
  fi
  for f in "${WRAPPER_PATH}.qemu-ad-new" "${WRAPPER_PATH}.bg-new"; do exists_or_link "$f" && act rm -f "$f"; done
  if divert_ours; then
    if ! exists_or_link "$VENDOR_PATH"; then
      log "divert recorded but $VENDOR_PATH is missing: reinstalling pve-qemu-kvm (dpkg puts the vendor file at $VENDOR_PATH)"
      have apt-get && act env DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y -o Dpkg::Options::=--force-confold pve-qemu-kvm
    fi
    if ((DRY)) || exists_or_link "$VENDOR_PATH"; then
      # drop the divert record first (no file moves), then ONE atomic mv puts the vendor file back over the wrapper
      if act dpkg-divert --local --no-rename --remove "$WRAPPER_PATH"; then
        act mv -f "$VENDOR_PATH" "$WRAPPER_PATH" || { log "ERROR: could not move $VENDOR_PATH onto $WRAPPER_PATH"; KVM_OK=0; }
      else log "ERROR: dpkg-divert --remove failed; nothing moved"; KVM_OK=0; return 1; fi
    else
      log "ERROR: $VENDOR_PATH is still missing; dropping the divert record and falling back to repair"
      act dpkg-divert --local --no-rename --remove "$WRAPPER_PATH"
    fi
  elif divert_any; then
    log "WARNING: a divert for $WRAPPER_PATH exists that is not ours; leaving it alone:"; divert_list | sed 's/^/    /'
  fi
  # no divert (or already removed): is the wrapper path a vendor binary?
  if ((!DRY)) && ! vendor_resolves; then
    log "$WRAPPER_PATH is not a vendor ELF (half-installed, or the wrapper was left behind): repairing"
    if exists_or_link "$VENDOR_PATH" && is_elf "$(readlink -f -- "$VENDOR_PATH")" && ! is_wrapper_file "$(readlink -f -- "$VENDOR_PATH")" && ! divert_any; then
      act mv -f "$VENDOR_PATH" "$WRAPPER_PATH"
    fi
    if ! vendor_resolves && have apt-get && ! divert_any; then
      act env DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y -o Dpkg::Options::=--force-confold pve-qemu-kvm
    fi
    local pk; pk="$(dirname "$WRAPPER_PATH")/qemu-system-x86_64"
    if ! vendor_resolves && ! divert_any && [[ -f $pk ]] && is_elf "$pk" && ! is_wrapper_file "$pk"; then
      log "last resort: symlink $WRAPPER_PATH -> qemu-system-x86_64 (the packaged layout)"
      ln -sfn qemu-system-x86_64 "${WRAPPER_PATH}.bg-new" && mv -fT "${WRAPPER_PATH}.bg-new" "$WRAPPER_PATH"
    fi
    vendor_resolves || { log "ERROR: $WRAPPER_PATH is still not a vendor binary"; KVM_OK=0; }
  elif ((DRY)) && ! vendor_resolves; then
    log "DRY-RUN: $WRAPPER_PATH is not a vendor ELF now; a real run would repair it (vendor file back in place, else apt --reinstall pve-qemu-kvm, else symlink)"
  fi
  # a stale vendor copy with no divert
  if ! divert_any && exists_or_link "$VENDOR_PATH" && vendor_resolves; then
    if [[ -L $VENDOR_PATH && $(readlink -f -- "$VENDOR_PATH") == "$(readlink -f -- "$WRAPPER_PATH")" ]] || cmp -s "$VENDOR_PATH" "$WRAPPER_PATH"; then
      act rm -f "$VENDOR_PATH"
    else
      log "WARNING: $VENDOR_PATH exists but differs from $WRAPPER_PATH; leaving it (inspect by hand)"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------- step 3: remove qemu-ad artifacts
step_files() {
  log "--- step 3: remove qemu-ad files"
  local f it x rc_files=0 its=()
  if ((!DRY && !KVM_OK)); then log "skipped: $WRAPPER_PATH is not a vendor binary yet, so the side QEMU is left in place"; return 0; fi
  if [[ -e $LIST_FILE || -L $LIST_FILE ]]; then act rm -f "$LIST_FILE"; fi
  if [[ -d $(dirname "$LIST_FILE") ]] && ! ((DRY)); then rmdir "$(dirname "$LIST_FILE")" 2>/dev/null; fi
  [[ -e $LOG_FILE || -L $LOG_FILE ]] && act rm -f "$LOG_FILE"
  while IFS= read -r f; do [[ -e $f || -L $f ]] && act rm -f "$f"; done < <(glob "$LOG_FILE.[0-9]*")
  if ((KEEP_BUILD)); then log "keep-build: leaving $PREFIX and $SRC_ROOT"; return 0; fi
  if [[ -L $PREFIX ]]; then act rm -f "$PREFIX"
  elif [[ -d $PREFIX ]]; then
    # only recurse into something that looks like ours (or is empty): a mistyped PREFIX must not delete another tree
    if [[ -e $PREFIX/bin/qemu-system-x86_64 || -e $PREFIX/.qemu-ad-configure-flags || -z $(ls -A -- "$PREFIX") ]]; then act rm -rf -- "$PREFIX"
    else log "ERROR: $PREFIX has neither bin/qemu-system-x86_64 nor .qemu-ad-configure-flags; it does not look like a qemu-ad prefix, so it is NOT deleted (inspect it, remove it by hand)"; rc_files=1; fi
  fi
  while IFS= read -r x; do [[ -n $x ]] && its+=("${x#"$SRC_ROOT"/}"); done < <(glob "$SRC_ROOT/.extract.*")
  for it in "qemu-${QEMU_VER}" "qemu-${QEMU_VER}.tar.xz" "qemu-${QEMU_VER}.tar.xz.part" "qemu-anti-detection" ${its[@]+"${its[@]}"}; do
    if [[ -e $SRC_ROOT/$it || -L $SRC_ROOT/$it ]]; then act rm -rf -- "${SRC_ROOT:?}/${it:?}"; fi
  done
  if [[ -d $SRC_ROOT ]] && ! ((DRY)); then rmdir "$SRC_ROOT" 2>/dev/null; fi
  log "note: apt build dependencies (build-essential, libaio-dev, ...) are left installed; they are harmless"
  return $rc_files
}

# ---------------------------------------------------------------- step 4: verify
FAILS=0
chk() {  # chk <label> <cmd...>
  local l=$1; shift
  if "$@"; then log "  PASS  $l"; else log "  FAIL  $l"; FAILS=$((FAILS+1)); fi
}
t_no_divert() { ! divert_any; }
t_kvm_runs() { [[ -x $WRAPPER_PATH ]] && "$WRAPPER_PATH" --version >/dev/null 2>&1; }
t_dpkg_owns() { ! have dpkg || dpkg -S "$WRAPPER_PATH" 2>/dev/null | grep -q '^pve-qemu-kvm'; }
t_no_leftovers() { local f; for f in "$VENDOR_PATH" "${WRAPPER_PATH}.qemu-ad-new" "${WRAPPER_PATH}.bg-new"; do exists_or_link "$f" && return 1; done; return 0; }
t_absent() { [[ ! -e $1 && ! -L $1 ]]; }
t_no_log() { local f; [[ -e $LOG_FILE || -L $LOG_FILE ]] && return 1; while IFS= read -r f; do [[ -e $f || -L $f ]] && return 1; done < <(glob "$LOG_FILE.[0-9]*"); return 0; }
t_no_tree() { local it; for it in "qemu-${QEMU_VER}" "qemu-${QEMU_VER}.tar.xz" "qemu-anti-detection"; do exists_or_link "$SRC_ROOT/$it" && return 1; done; return 0; }
t_vm_gone() { [[ $(vm_state "$1") == absent ]]; }
t_dpkg_audit() { ! have dpkg || [[ -z $(dpkg --audit 2>&1) ]]; }
t_same_status() {
  local id was cur lst bad=0
  if [[ ! -r $PRE/qm-list.txt ]] || ! grep -q VMID "$PRE/qm-list.txt"; then log "        pre-state qm list is missing or invalid"; return 1; fi
  lst=$(qm list 2>/dev/null) && [[ $lst == *VMID* ]] || { log "        qm list failed now; cannot compare"; return 1; }
  for id in ${PROT_A[@]+"${PROT_A[@]}"}; do
    was=$(awk -v i="$id" '$1==i{print $3}' "$PRE/qm-list.txt" 2>/dev/null)
    cur=$(awk -v i="$id" '$1==i{print $3}' <<<"$lst")
    [[ $was == "$cur" ]] || { bad=1; log "        VM $id status: pre-state=${was:-absent} now=${cur:-absent}"; }
  done
  ((bad == 0))
}
t_same_pids() {
  local id was cur bad=0
  [[ -r $PRE/pids.txt ]] || { log "        pre-state pids.txt is missing"; return 1; }
  for id in ${PROT_A[@]+"${PROT_A[@]}"}; do
    was=$(awk -v i="$id" '$1==i{print $2}' "$PRE/pids.txt" 2>/dev/null)
    cur=$(cat "$PID_DIR/$id.pid" 2>/dev/null)
    [[ $was == "$cur" ]] || { bad=1; log "        VM $id pid: pre-state=${was:-none} now=${cur:-none}"; }
  done
  ((bad == 0))
}
step_verify() {
  FAILS=0
  log "--- step 4: end-state report$( ((DRY)) && ((!VERIFY_ONLY)) && echo ' (DRY-RUN: this is the CURRENT state, not the end state)')"
  chk "$WRAPPER_PATH is a vendor ELF (not the wrapper)" vendor_resolves
  chk "dpkg owns the kvm binary (pve-qemu-kvm), when dpkg is available" t_dpkg_owns
  chk "no dpkg divert for $WRAPPER_PATH" t_no_divert
  chk "no $VENDOR_PATH or staged-wrapper leftovers" t_no_leftovers
  chk "vendor kvm runs (--version)" t_kvm_runs
  chk "no VMID list ($LIST_FILE)" t_absent "$LIST_FILE"
  if ((KEEP_BUILD)); then log "  (keep-build: $PREFIX and the sources are not checked)"; else
    chk "no side QEMU prefix ($PREFIX)" t_absent "$PREFIX"
    chk "no build tree under $SRC_ROOT" t_no_tree
  fi
  chk "no wrapper log ($LOG_FILE)" t_no_log
  local v; for v in ${VMID_A[@]+"${VMID_A[@]}"}; do chk "VM $v gone" t_vm_gone "$v"; done
  chk "dpkg --audit is clean (when dpkg is available)" t_dpkg_audit
  if [[ -d $PRE && -n $PROTECTED ]]; then
    chk "protected VMs have the same status as in the pre-state" t_same_status
    chk "protected VMs have the same PIDs as in the pre-state (processes untouched)" t_same_pids
  else
    log "  INFO  no pre-state at $PRE (or no protected VMIDs): protected-VM comparison skipped"
  fi
  if ((FAILS)); then log "RESULT: FAIL ($FAILS check(s) failed)"; else log "RESULT: PASS"; fi
  ((FAILS == 0))
}

# ---------------------------------------------------------------- main
if ((VERIFY_ONLY)); then step_verify; exit $?; fi
if ((${#VMID_A[@]} > 0 && !CAPTURE)); then
  destroy_gate                                     # exit 2 unless this is a declared, single, fully accounted-for test node
  if ((DRY)); then log "DRY-RUN: --apply would now ask for a typed confirmation (a phrase with a fresh random token) on the terminal"
  else confirm_destroy; fi                         # exit 2 unless a person types the phrase
fi
if ((APPLY)); then
  if (umask 077; mkdir -p "$STATE_DIR") 2>/dev/null && : >> "$RUNLOG" 2>/dev/null; then chmod 600 "$RUNLOG" 2>/dev/null; LOG_READY=1; else
    printf 'warning: cannot write %s; continuing without a run log\n' "$RUNLOG" >&2
  fi
fi
if ((CAPTURE)); then capture_prestate; exit $?; fi
log "=== qemu-ad break glass start ($( ((DRY)) && echo 'DRY-RUN: pass --apply to make changes' || echo APPLY)) keep-build=$KEEP_BUILD ==="
rc=0
step_vms || rc=1
if ((rc && !DRY)); then log "step 1 failed; stopping before touching the kvm wrapper"; step_verify; exit 1; fi
step_kvm || rc=1
step_files || rc=1
if step_verify; then vrc=0; else vrc=1; fi
if ((DRY)); then log "dry run finished: nothing was changed. Re-run with --apply to do it."; exit $rc; fi
exit $((rc || vrc))
