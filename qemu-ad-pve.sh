#!/bin/bash
# qemu-ad-pve.sh — development-environment compatibility QEMU beside stock Proxmox
#
# Purpose
# -------
# A lab tool. Some guests and some programs under test refuse to run when the
# emulated hardware identifies itself as QEMU. This script builds a second
# QEMU, with device-identity strings rewritten, and sends only listed VMIDs
# to it. It is for a development host you control. It is not a production
# hypervisor and it is not a supported Proxmox configuration.
#
# What this is
# ------------
# Stock Proxmox keeps pve-qemu-kvm at /usr/bin/kvm (after the divert below,
# at /usr/bin/kvm.pve). Every guest qm starts still goes through that path.
# This script builds a second QEMU from the vanilla tarball plus the
# zhaodice/qemu-anti-detection patch, installs it under /opt/qemu-ad, and
# puts a wrapper at /usr/bin/kvm that execs the side binary only for VMIDs
# listed in /etc/qemu-ad/vms.
#
# Guests not in that list are exec'd straight to the vendor binary. A bad
# side build cannot take the node down.
#
# What this does not do
# ---------------------
# - It does not replace pve-qemu-kvm or qemu-server.
# - It does not apply the patch to Proxmox's QEMU tree. The patch is against
#   vanilla qemu; pve-qemu carries backup/migration/machine-type patches that
#   conflict with that.
# - Live backup and live migration of a side guest will fail. qm sends QMP
#   commands (backup, fleecing, query-proxmox-support) that vanilla QEMU
#   does not implement. Start and stop still work, because the pidfile and
#   the QMP socket stay on the paths qemu-server chose.
# - A machine type of pc-q35-X.Y+pveN will not boot on vanilla QEMU. On the
#   side-binary path the wrapper strips +pve<N> only inside the value of
#   -machine / -M (not from -name, -smbios, paths, ...) and drops the
#   "-id <vmid>" pair. Pin the guest to a version this tree knows anyway
#   (pc-q35-10.1 is safe on the 10.2.2 build).
#
# Usage
# -----
#   ./qemu-ad-pve.sh install          # deps, build, divert, wrapper
#   ./qemu-ad-pve.sh add-vm 200       # send VMID 200 to the side binary
#   ./qemu-ad-pve.sh del-vm 200
#   ./qemu-ad-pve.sh status
#   ./qemu-ad-pve.sh showcmd 200      # qm showcmd, then the rewritten argv
#   ./qemu-ad-pve.sh uninstall        # restore /usr/bin/kvm, leave /opt
#   ./qemu-ad-pve.sh uninstall --purge
#
# install is idempotent. Re-run it after a pve-qemu-kvm upgrade; the divert
# already sends the new vendor binary to /usr/bin/kvm.pve.
#
# Do not `apt remove pve-qemu-kvm` while the divert is active; run
# `uninstall` first. If it was already removed: `apt install --reinstall
# pve-qemu-kvm` (dpkg puts the vendor binary back at /usr/bin/kvm.pve), then
# `uninstall`. `status` warns about this state.
#
# The VMID list holds one VMID per line. Leading/trailing whitespace and a
# trailing carriage return (CRLF) are ignored; anything else on the line
# (such as a comment after the number) makes that line not match.
#
# Guest config that actually uses the patch (set these yourself, per VMID)
# -------------------------------------------------------------------------
#   cpu: host,hidden=1,hv-vendor-id=GenuineIntel
#   machine: pc-q35-10.1
#   args: -smbios type=1,manufacturer=ASUS,product=System,serial=...
#   hostpci0: 0000:01:00,pcie=1,romfile=/var/lib/qemu-ad/gpu.rom
# hidden=1 is the stock Proxmox knob. Proxmox turns it into kvm=off on the
# -cpu line (hides the KVM signature leaf); it does NOT clear the CPUID
# hypervisor bit.
# The patch rewrites device names, SMBIOS VM bit, and BGRT inside QEMU.
# SMBIOS manufacturer strings still come from args. Passthrough is a normal
# hostpci line; do not also assign that PCI address to another guest.

set -euo pipefail

# ---------------------------------------------------------------------------
# Knobs. Override on the command line: QEMU_VER=10.2.2 ./qemu-ad-pve.sh install
# The patch file name and the tarball version must match. qemu-anti-detection
# ships qemu-<ver>.patch for specific releases only.
# ---------------------------------------------------------------------------
QEMU_VER="${QEMU_VER:-10.2.2}"
PREFIX="${PREFIX:-/opt/qemu-ad}"
SRC_ROOT="${SRC_ROOT:-/opt/src}"
PATCH_REPO="${PATCH_REPO:-https://github.com/zhaodice/qemu-anti-detection.git}"
TARBALL_URL="${TARBALL_URL:-https://download.qemu.org/qemu-${QEMU_VER}.tar.xz}"
LIST_FILE="${LIST_FILE:-/etc/qemu-ad/vms}"
WRAPPER_PATH="${WRAPPER_PATH:-/usr/bin/kvm}"
VENDOR_PATH="${VENDOR_PATH:-/usr/bin/kvm.pve}"
LOG_FILE="${LOG_FILE:-/var/log/qemu-ad-wrapper.log}"
DPKG_LOCK="${DPKG_LOCK:-/var/lib/dpkg/lock-frontend}"

# Integrity pins. Known-good SHA-256 for the versions this script has been
# checked against (tarball verified against QEMU's signed release too). For
# any other QEMU_VER, export QEMU_SHA256 and PATCH_SHA256 yourself; with no
# pin the script warns and carries on. A pin that does not match is fatal.
case "$QEMU_VER" in
  10.2.2)
    _def_qemu_sha=784b296ff29c1417aa72323abcb2d2ea9ab9771724f577dcd785c3b04f21e176
    _def_patch_sha=0d05f1a0ced91cef3fe33203b7d81c955d64694f30085544dc5e154809da110e
    ;;
  *) _def_qemu_sha=""; _def_patch_sha="" ;;
esac
QEMU_SHA256="${QEMU_SHA256:-$_def_qemu_sha}"
PATCH_SHA256="${PATCH_SHA256:-$_def_patch_sha}"

SIDE_BIN="${PREFIX}/bin/qemu-system-x86_64"
PATCH_DIR="${SRC_ROOT}/qemu-anti-detection"
SRC_DIR="${SRC_ROOT}/qemu-${QEMU_VER}"
PATCH_FILE="${PATCH_DIR}/qemu-${QEMU_VER}.patch"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "run as root"
}

# Proxmox is the intended host. A missing qm is a warning, not a hard stop,
# so the build can be rehearsed on a plain Debian box. The divert is useless
# without qemu-server.
have_pve() { command -v qm >/dev/null 2>&1 && command -v pveversion >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# Build dependencies. --disable-docs drops sphinx. slirp/gtk/vnc are not
# required: PVE guests use tap netdev and a unix VNC socket, both in the
# core x86_64-softmmu build.
# ---------------------------------------------------------------------------
install_deps() {
  say "installing build dependencies"
  export DEBIAN_FRONTEND=noninteractive
  # A broken extra repo (for example an enterprise repo with no subscription)
  # makes `apt-get update` exit non-zero. The install below still works from
  # the existing package lists, so warn instead of aborting.
  apt-get update || echo "warning: apt-get update failed; continuing with existing package lists" >&2
  apt-get install -y \
    git wget ca-certificates build-essential ninja-build pkg-config \
    python3 python3-venv meson flex bison \
    libglib2.0-dev libpixman-1-dev zlib1g-dev \
    libaio-dev liburing-dev libiscsi-dev \
    libgcrypt20-dev
}

# verify_sha256 <file> <expected-or-empty> <label> <knob-name>
verify_sha256() {
  local file="$1" want="$2" label="$3" knob="$4" got
  if [[ -z $want ]]; then
    echo "warning: no pinned SHA-256 for ${label}; set ${knob} to enforce one" >&2
    return 0
  fi
  got=$(sha256sum "$file" | awk '{print $1}')
  [[ $got == "$want" ]] || die "SHA-256 mismatch for ${label}
  expected ${want}
  got      ${got}
Delete the file and retry, or set ${knob} if you intend to use a different one."
  say "${label}: SHA-256 ok"
}

fetch_sources() {
  install -d "$SRC_ROOT"
  if [[ ! -d ${PATCH_DIR}/.git ]]; then
    say "cloning qemu-anti-detection"
    git clone --depth 1 "$PATCH_REPO" "$PATCH_DIR"
  else
    say "updating qemu-anti-detection"
    git -C "$PATCH_DIR" pull --ff-only || true
  fi
  [[ -f $PATCH_FILE ]] || die "no patch for QEMU ${QEMU_VER} at ${PATCH_FILE}
available patches:
$(ls -1 "${PATCH_DIR}"/qemu-*.patch 2>/dev/null || echo '  (none)')"
  verify_sha256 "$PATCH_FILE" "$PATCH_SHA256" "patch qemu-${QEMU_VER}.patch" PATCH_SHA256

  local tarball="${SRC_ROOT}/qemu-${QEMU_VER}.tar.xz"
  if [[ ! -f $tarball ]]; then
    say "downloading ${TARBALL_URL}"
    # Download to a .part name so an interrupted transfer is never mistaken
    # for a finished tarball on the next run.
    command rm -f "${tarball}.part"
    if ! wget -O "${tarball}.part" "$TARBALL_URL"; then
      command rm -f "${tarball}.part"
      die "download failed: ${TARBALL_URL}"
    fi
    mv -f "${tarball}.part" "$tarball"
  fi
  verify_sha256 "$tarball" "$QEMU_SHA256" "tarball qemu-${QEMU_VER}.tar.xz" QEMU_SHA256
  if [[ ! -d $SRC_DIR ]]; then
    say "extracting qemu-${QEMU_VER}"
    # Extract into a scratch dir and rename, so an interrupted extract does
    # not leave a half-populated $SRC_DIR that later runs would trust.
    local tmpx
    tmpx=$(mktemp -d "${SRC_ROOT}/.extract.XXXXXX")
    if ! tar -C "$tmpx" -xJf "$tarball"; then
      command rm -rf "$tmpx"
      die "extract failed; delete ${tarball} and retry"
    fi
    if [[ ! -d ${tmpx}/qemu-${QEMU_VER} ]]; then
      command rm -rf "$tmpx"
      die "tarball did not contain qemu-${QEMU_VER}/"
    fi
    mv "${tmpx}/qemu-${QEMU_VER}" "$SRC_DIR"
    command rm -rf "$tmpx"
  fi
}

# git apply is not idempotent. A stamp file records a successful apply so a
# re-run does not try to patch an already-patched tree. Delete the stamp
# and the source dir to force a clean apply.
apply_patch() {
  local stamp="${SRC_DIR}/.qemu-ad-patched"
  if [[ -f $stamp ]]; then
    say "patch already applied (${stamp})"
    return 0
  fi
  say "applying ${PATCH_FILE}"
  # -p1 is what `git apply` expects for a diff generated from the qemu repo.
  # --check first: a patch that does not apply cleanly fails here, before
  # anything in the tree is modified.
  git -C "$SRC_DIR" apply --check "$PATCH_FILE"
  git -C "$SRC_DIR" apply "$PATCH_FILE"
  date -Is > "$stamp"
}

# The installed side binary can differ from QEMU_VER (for example after an
# earlier install with another version). Warn; do not rebuild implicitly.
warn_version_skew() {
  [[ -x $SIDE_BIN ]] || return 0
  local have
  have=$("$SIDE_BIN" --version 2>/dev/null | head -1) || true
  if [[ $have != *"version ${QEMU_VER}"* ]]; then
    echo "warning: installed side binary reports '${have:-unknown}', expected QEMU ${QEMU_VER}; set FORCE_REBUILD=1 to rebuild" >&2
  fi
}

# configure flags of the side build. They are recorded in the build stamp after a
# successful build, so a later `install` can tell when an existing build was
# made with different flags. The crypto backend is not optional: without it
# QEMU has no DES, and `-vnc ...,password=on` (every guest with a VGA, which
# includes the qm create default) fails with "Cipher backend does not support
# DES algorithm". gcrypt is explicit, because configure only auto-detects it
# when the dev package happens to be installed.
QAD_CONFIGURE_FLAGS=(
  --target-list=x86_64-softmmu
  --enable-kvm
  --enable-linux-aio
  --enable-linux-io-uring
  --enable-libiscsi
  --enable-gcrypt
  --disable-gnutls
  --disable-docs
  --disable-werror
)
# Resolved at call time (PREFIX can be set after this file is read).
build_stamp() { printf '%s' "${PREFIX}/.qemu-ad-configure-flags"; }

# side_rebuild_reason: print why the installed side binary should be rebuilt;
# print nothing when it is fine. With a build stamp the recorded flags are
# compared with the current ones. A build from before the stamp existed has
# none, so fall back to asking ldd whether the (dynamic) binary links libgcrypt.
side_rebuild_reason() {
  [[ -x $SIDE_BIN ]] || return 0
  local stamp
  stamp=$(build_stamp)
  if [[ -f $stamp ]]; then
    if [[ $(cat "$stamp") != "${QAD_CONFIGURE_FLAGS[*]}" ]]; then
      printf 'it was built with different configure flags than this script uses (see %s)' "$stamp"
    fi
  elif ldd "$SIDE_BIN" 2>/dev/null | grep -q '=>' && ! ldd "$SIDE_BIN" 2>/dev/null | grep -q 'libgcrypt'; then
    printf 'it does not link libgcrypt, so it has no crypto backend and guests with VGA/VNC cannot start ("Cipher backend does not support DES algorithm")'
  fi
}

build_qemu() {
  local why=""
  if [[ -x $SIDE_BIN && ${FORCE_REBUILD:-0} -ne 1 ]]; then
    why=$(side_rebuild_reason)
    if [[ -z $why ]]; then
      say "side binary already installed at ${SIDE_BIN} (set FORCE_REBUILD=1 to redo)"
      warn_version_skew
      return 0
    fi
    say "side binary at ${SIDE_BIN}: ${why}; rebuilding with gcrypt"
  fi
  say "configuring QEMU ${QEMU_VER} with prefix ${PREFIX}"
  # --prefix is the whole point. A default configure installs into /usr/local
  # and will shadow other tools on PATH. qm calls /usr/bin/kvm by absolute
  # path, but anything else that searches PATH would pick up the side build.
  (
    cd "$SRC_DIR"
    ./configure --prefix="$PREFIX" "${QAD_CONFIGURE_FLAGS[@]}"
    make -j"$(nproc)"
    make install
  )
  [[ -x $SIDE_BIN ]] || die "build finished but ${SIDE_BIN} is missing"
  printf '%s\n' "${QAD_CONFIGURE_FLAGS[*]}" > "$(build_stamp)"
  say "installed $($SIDE_BIN --version | head -1)"
}

# ---------------------------------------------------------------------------
# Wrapper.
#
# qemu-server execs /usr/bin/kvm and passes the full argv. The VMID is
# recovered from the pidfile or QMP socket path, which qemu-server sets:
#   -pidfile /var/run/qemu-server/<vmid>.pid
#   -chardev socket,id=qmp,path=/var/run/qemu-server/<vmid>.qmp,...
# qemu-server also still passes a dummy "-id <vmid>" (pve-qemu carries a
# patch that accepts and ignores it). Vanilla QEMU rejects it, so the
# wrapper drops that pair on the side-binary path only.
#
# Decision is stateless. Two concurrent starts cannot cross, unlike a
# pre-start hook that flips a symlink.
#
# +pveN is a Proxmox machine-type revision vanilla QEMU rejects. It is
# stripped only on the side-binary path. The vendor path is argv-identical.
# ---------------------------------------------------------------------------
# qad_side_args "$@": build SIDE_ARGS, the argv a vanilla QEMU accepts, from
# the argv qemu-server built for pve-qemu-kvm. Anything dropped is listed in
# SIDE_DROPPED. This one function is embedded verbatim in the generated
# wrapper (declare -f) and also used by `showcmd`, so the two cannot drift.
#   -id <vmid>       vendor-only dummy option (pve-qemu patch); vanilla has none
#   +pveN            vendor machine-type revision, stripped only inside the
#                    value of -machine / -M
qad_side_args() {
  SIDE_ARGS=()
  SIDE_DROPPED=()
  local a prev="" skip=0
  for a in "$@"; do
    if (( skip )); then skip=0; prev=$a; continue; fi
    if [[ $a == -id ]]; then SIDE_DROPPED+=("-id"); skip=1; prev=$a; continue; fi
    if [[ $prev == -machine || $prev == -M ]]; then
      while [[ $a =~ ^(.*)\+pve[0-9]+(.*)$ ]]; do a=${BASH_REMATCH[1]}${BASH_REMATCH[2]}; done
    fi
    SIDE_ARGS+=("$a")
    prev=$a
  done
}

# VMID list matching, shared by the wrapper (embedded with declare -f), add-vm,
# del-vm and showcmd so they cannot disagree. A line matches when it is exactly
# the VMID, optionally surrounded by whitespace; [[:space:]] covers the CR of
# CRLF line endings. $1 must be digits only (callers validate).
qad_list_pat() { printf '[[:space:]]*%s[[:space:]]*' "$1"; }
# qad_list_has <vmid> <list-file>: rc 0 if listed; missing/unreadable -> rc 1, silent.
# The pattern is built with printf -v (same format as qad_list_pat; keep them in
# sync) so each start does not fork a subshell for it.
qad_list_has() {
  [[ -f $2 ]] || return 1
  local p
  printf -v p '[[:space:]]*%s[[:space:]]*' "$1"
  grep -qxE -- "$p" "$2" 2>/dev/null
}

write_wrapper() {
  local out="${1:-$WRAPPER_PATH}"
  say "writing ${out}"
  cat > "$out" <<EOF
#!/bin/bash
# Generated by qemu-ad-pve.sh. Do not edit in place; re-run the installer.
# Listed VMIDs exec the side QEMU. Everything else execs the vendor binary.
real=$(printf '%q' "$VENDOR_PATH")
side=$(printf '%q' "$SIDE_BIN")
list=$(printf '%q' "$LIST_FILE")
log=$(printf '%q' "$LOG_FILE")
# argv[0] seen by the QEMU process. qemu-server decides whether a pid is "its"
# VM by matching argv[0] against kvm\$ or (^|/)qemu-..., and QEMU itself only
# defaults to KVM acceleration when argv[0] looks like kvm. exec -a keeps
# both working although the real binary lives at a different path.
argv0=$(printf '%q' "$WRAPPER_PATH")

$(declare -f qad_side_args qad_list_pat qad_list_has)

id=""
for a in "\$@"; do
  case "\$a" in
    */qemu-server/[0-9]*.pid|*/qemu-server/[0-9]*.qmp|*/qemu-server/[0-9]*.qmp,*)
      id=\$(printf '%s\n' "\$a" | sed -n 's#.*/qemu-server/\\([0-9][0-9]*\\)\\..*#\\1#p' | head -1)
      [[ -n \$id ]] && break
      ;;
  esac
done

if [[ -n \$id ]] && qad_list_has "\$id" "\$list"; then
  qad_side_args "\$@"
  # Logging is best effort and must be silent: qm parses our output, and a
  # missing/unwritable log dir must never fail or noise up a VM start. The
  # 2>/dev/null on the group also covers the shell's own redirection error.
  { printf '%s vmid=%s exec %s dropped=%s\\n' "\$(date -Is)" "\$id" "\$side" "\${SIDE_DROPPED[*]:-}" >> "\$log"; } 2>/dev/null || true
  exec -a "\$argv0" "\$side" "\${SIDE_ARGS[@]}"
fi

exec -a "\$argv0" "\$real" "\$@"
EOF
  chmod 755 "$out"
}

# True (rc 0) if some process holds an fcntl lock on $1. dpkg uses fcntl
# (POSIX) locks, so flock(1) cannot see them; /proc/locks lists them by
# device:inode.
dpkg_lock_held() {
  local f="$1" ino
  [[ -e $f ]] || return 1
  ino=$(stat -c %i "$f") || return 1
  [[ -r /proc/locks ]] || return 1
  awk -v ino="$ino" '{ n = split($6, a, ":"); if (a[n] == ino) found = 1 } END { exit !found }' /proc/locks
}

# Printed when the divert is recorded but the vendor binary is gone, which is
# what `apt remove pve-qemu-kvm` leaves behind (dpkg deletes the diverted path
# but cannot touch our wrapper).
vendor_missing_hint() {
  printf '%s' "${VENDOR_PATH} is missing while the divert for ${WRAPPER_PATH} is still recorded: pve-qemu-kvm was probably removed.
Recover: reinstall the package (apt install --reinstall pve-qemu-kvm; dpkg writes the vendor binary back to ${VENDOR_PATH}), then run '$0 uninstall' to restore ${WRAPPER_PATH} (or '$0 install' to keep the setup)."
}

preflight_divert_remove() {
  [[ -e $VENDOR_PATH || -L $VENDOR_PATH ]] || die "$(vendor_missing_hint)"
  if dpkg_lock_held "$DPKG_LOCK"; then
    die "another package manager holds ${DPKG_LOCK}; wait for it to finish and retry"
  fi
}

# Pre-flight for anything that rewrites the divert. Cheap, read-only.
preflight_divert() {
  [[ -e $WRAPPER_PATH ]] || die "${WRAPPER_PATH} does not exist; refusing to divert a missing file (dpkg-divert --rename would silently do nothing). Reinstall pve-qemu-kvm first."
  if dpkg_lock_held "$DPKG_LOCK"; then
    die "another package manager holds ${DPKG_LOCK}; wait for it to finish and retry"
  fi
}

install_wrapper() {
  [[ -x $SIDE_BIN ]] || die "side binary missing; build first"
  preflight_divert
  install -d "$(dirname "$LIST_FILE")"
  [[ -f $LIST_FILE ]] || : > "$LIST_FILE"

  # Stage and syntax-check the wrapper BEFORE touching /usr/bin/kvm, so a
  # write failure cannot leave the host without a kvm binary. The final
  # mv is an atomic rename in the same directory. Cleanup is explicit (not a
  # RETURN trap: that trap also fires in the caller and aborts under set -u).
  local staged="${WRAPPER_PATH}.qemu-ad-new"
  if ! write_wrapper "$staged"; then
    rm -f "$staged"; die "could not write the wrapper; nothing changed"
  fi
  if ! bash -n "$staged"; then
    rm -f "$staged"; die "generated wrapper failed bash -n; nothing changed"
  fi

  # dpkg-divert --local survives package upgrades: pve-qemu-kvm's new
  # /usr/bin/kvm lands on $VENDOR_PATH instead of replacing the wrapper.
  # The vendor file is COPIED to $VENDOR_PATH first, the divert is recorded
  # without a rename, and the wrapper then replaces $WRAPPER_PATH with one
  # atomic mv, so /usr/bin/kvm exists at every instant.
  if ! dpkg-divert --list "$WRAPPER_PATH" | grep -q "$VENDOR_PATH"; then
    if [[ -e $VENDOR_PATH || -L $VENDOR_PATH ]]; then
      rm -f "$staged"; die "${VENDOR_PATH} already exists; not overwriting it"
    fi
    say "diverting ${WRAPPER_PATH} -> ${VENDOR_PATH}"
    if ! cp -aP "$WRAPPER_PATH" "$VENDOR_PATH"; then
      rm -f "$staged" "$VENDOR_PATH"; die "could not copy ${WRAPPER_PATH} to ${VENDOR_PATH}; nothing changed"
    fi
    if ! dpkg-divert --local --no-rename --divert "$VENDOR_PATH" "$WRAPPER_PATH"; then
      rm -f "$staged" "$VENDOR_PATH"; die "dpkg-divert failed; nothing changed"
    fi
  else
    say "divert already in place"
  fi
  [[ -e $VENDOR_PATH || -L $VENDOR_PATH ]] || { rm -f "$staged"; die "$(vendor_missing_hint)"; }
  if ! mv -f "$staged" "$WRAPPER_PATH"; then
    # /usr/bin/kvm is still the vendor binary here. Undo the divert and the copy.
    dpkg-divert --local --no-rename --remove "$WRAPPER_PATH" && rm -f "$VENDOR_PATH" || true
    rm -f "$staged"
    die "could not install wrapper; divert rolled back"
  fi
  say "wrapper installed. VMIDs in ${LIST_FILE} use ${SIDE_BIN}"
}

add_vm() {
  local id="${1:-}"
  [[ $id =~ ^[1-9][0-9]*$ ]] || die "add-vm needs a numeric VMID (no leading zeros)"
  install -d "$(dirname "$LIST_FILE")"
  [[ -f $LIST_FILE ]] || : > "$LIST_FILE"
  if qad_list_has "$id" "$LIST_FILE"; then
    say "VMID ${id} already listed"
  else
    # A last line without a newline would otherwise be glued to the new id.
    if [[ -s $LIST_FILE && -n $(tail -c1 "$LIST_FILE") ]]; then printf '\n' >> "$LIST_FILE"; fi
    printf '%s\n' "$id" >> "$LIST_FILE"
    say "VMID ${id} will launch on ${SIDE_BIN}"
  fi
  say "set machine to a vanilla type (pc-q35-10.1) and cpu: host,hidden=1 before starting"
}

del_vm() {
  local id="${1:-}"
  [[ $id =~ ^[1-9][0-9]*$ ]] || die "del-vm needs a numeric VMID (no leading zeros)"
  [[ -f $LIST_FILE ]] || die "no list at ${LIST_FILE}"
  # Temp file beside the list so the final mv is an atomic same-filesystem
  # rename. grep exits 1 when nothing is left (fine) and 2 on a real error
  # (fatal, list untouched). Keep the original file mode.
  local tmp rc=0
  tmp=$(mktemp "${LIST_FILE}.XXXXXX")
  grep -vxE -- "$(qad_list_pat "$id")" "$LIST_FILE" > "$tmp" || rc=$?
  if (( rc > 1 )); then
    command rm -f "$tmp"
    die "could not rewrite ${LIST_FILE}; left unchanged"
  fi
  chmod --reference="$LIST_FILE" "$tmp"
  mv -f "$tmp" "$LIST_FILE"
  say "VMID ${id} removed; next start uses the vendor binary"
}

# qad_skew_warnings <vendor argv...>: print a WARNING line for each option the
# vendor (pve-qemu 11.x) command line uses that the side QEMU lacks. Plain
# string checks on the option and its value only. The side version comes from
# its own --version (QEMU_VER if it is not built).
qad_skew_warnings() {
  local side_ver mj mn a prev="" mv
  side_ver=$("$SIDE_BIN" --version 2>/dev/null | head -1) || true
  [[ $side_ver =~ version\ ([0-9]+)\.([0-9]+) ]] || side_ver="version ${QEMU_VER}"
  mj=0; mn=0
  if [[ $side_ver =~ version\ ([0-9]+)\.([0-9]+) ]]; then mj=${BASH_REMATCH[1]}; mn=${BASH_REMATCH[2]}; fi
  for a in "$@"; do
    case "$a" in
      -spice) echo "WARNING: -spice is a vendor-only option; the side QEMU ${mj}.${mn} rejects it (SPICE/qxl display unsupported). Use vga std or serial0." ;;
      -loadstate) echo "WARNING: -loadstate (resume from a RAM snapshot) is not available on the side QEMU; the guest will fail to start." ;;
    esac
    case "$prev" in
      -machine|-M)
        if [[ $a =~ pc-(q35|i440fx)-([0-9]+)\.([0-9]+) ]]; then
          mv=${BASH_REMATCH[0]}
          if (( BASH_REMATCH[2] > mj || (BASH_REMATCH[2] == mj && BASH_REMATCH[3] > mn) )); then
            echo "WARNING: machine ${mv} is newer than the side QEMU ${mj}.${mn} and will be rejected. Pin the guest to pc-${BASH_REMATCH[1]}-${mj}.${mn} or older."
          fi
        fi ;;
      -drive|-blockdev)
        case "$a" in
          *file=rbd:*|rbd:*) echo "WARNING: rbd: drive path; the side QEMU has no rbd block driver (Ceph disks unsupported on listed guests)." ;;
          *file=pbs:*|pbs:*) echo "WARNING: pbs: drive path; the side QEMU has no pbs block driver." ;;
        esac ;;
      -device)
        [[ $a == qxl* ]] && echo "WARNING: -device ${a%%,*}: qxl needs SPICE support, which the side QEMU lacks." ;;
    esac
    prev=$a
  done
}

showcmd() {
  local id="${1:-}"
  [[ $id =~ ^[1-9][0-9]*$ ]] || die "showcmd needs a numeric VMID (no leading zeros)"
  command -v qm >/dev/null 2>&1 || die "qm not on PATH"
  say "qm showcmd ${id} (vendor view)"
  qm showcmd "$id" --pretty || true
  # Run the very function the generated wrapper uses, so this view cannot
  # drift from what is exec'd.
  local -a vendor=()
  mapfile -d '' -t vendor < <(qm showcmd "$id" --pretty 2>/dev/null | python3 -c '
import shlex,sys
t=sys.stdin.read().replace("\\\n"," ")
sys.stdout.write("\0".join(shlex.split(t)))' 2>/dev/null) || true
  if [[ ${#vendor[@]} -gt 1 ]]; then
    qad_side_args "${vendor[@]:1}"
    if qad_list_has "$id" "$LIST_FILE"; then
      say "side-binary view: VMID ${id} IS listed, so this is what gets exec'd (${#SIDE_DROPPED[@]} option(s) dropped: ${SIDE_DROPPED[*]:-none}); not executed"
    else
      say "VMID ${id} is NOT listed: it runs on the vendor binary with the argv above unchanged. Side view below is hypothetical (dropped: ${SIDE_DROPPED[*]:-none})"
    fi
    printf '%q ' "$SIDE_BIN" "${SIDE_ARGS[@]}"; echo
    if qad_list_has "$id" "$LIST_FILE"; then qad_skew_warnings "${vendor[@]:1}"; fi
  else
    echo "warning: could not parse qm showcmd output (python3 needed)" >&2
  fi
}

status() {
  echo "prefix:     ${PREFIX}"
  echo "side bin:   ${SIDE_BIN}"
  if [[ -x $SIDE_BIN ]]; then
    echo "side ver:   $($SIDE_BIN --version | head -1)"
    warn_version_skew
    local why
    why=$(side_rebuild_reason)
    if [[ -n $why ]]; then
      echo "WARNING:    side binary: ${why}. Run '$0 install' to rebuild it (or FORCE_REBUILD=1 $0 install)."
    fi
  else
    echo "side ver:   (not built)"
  fi
  echo "wrapper:    ${WRAPPER_PATH}"
  echo "vendor:     ${VENDOR_PATH}"
  if dpkg-divert --list "$WRAPPER_PATH" 2>/dev/null | grep -q .; then
    dpkg-divert --list "$WRAPPER_PATH"
  else
    echo "divert:     (none)"
  fi
  if dpkg-divert --list "$WRAPPER_PATH" 2>/dev/null | grep -q "$VENDOR_PATH" \
     && [[ ! -e $VENDOR_PATH && ! -L $VENDOR_PATH ]]; then
    echo "WARNING:    $(vendor_missing_hint)"
  fi
  echo "list:       ${LIST_FILE}"
  if [[ -f $LIST_FILE ]]; then
    echo "vmids:"
    sed 's/^/  /' "$LIST_FILE" || true
  fi
  if have_pve; then
    echo "pve:        $(pveversion -v | awk '/pve-manager|pve-qemu-kvm/{print}' | tr '\n' ' ')"
    echo
  else
    echo "pve:        qm not found"
  fi
}

uninstall() {
  local purge="${1:-}"
  # Validate before changing anything: a refused purge must not half-uninstall.
  if [[ $purge == "--purge" ]]; then
    # Reject non-canonical paths outright (empty, "..", "//", a trailing "/",
    # a "." component such as "/./" or a trailing "/."), so that nothing can
    # slip past the allow-list or the system-directory list below by spelling.
    # PREFIX is a directory below /opt, /srv or /usr/local (but not the
    # standard /usr/local subdirectories that hold other software).
    case "$PREFIX" in
      ""|*..*|*//*|*/|*/./*|*/.) die "refusing to purge PREFIX=${PREFIX} (non-canonical path)" ;;
      /usr/local/bin|/usr/local/sbin|/usr/local/lib|/usr/local/lib64|/usr/local/etc|/usr/local/share|/usr/local/include|/usr/local/src|/usr/local/man|/usr/local/games)
        die "refusing to purge PREFIX=${PREFIX} (system directory)" ;;
      /opt/?*|/usr/local/?*|/srv/?*) ;;
      *) die "refusing to purge PREFIX=${PREFIX} (must be under /opt, /usr/local or /srv)" ;;
    esac
    # LIST_FILE is a single file, removed with rm -f: it must be a canonical
    # path to a file inside /etc/qemu-ad or /var/lib/qemu-ad, never a directory.
    case "$LIST_FILE" in
      ""|*..*|*//*|*/|*/./*|*/.) die "refusing to purge LIST_FILE=${LIST_FILE} (non-canonical path)
Nothing was changed. Run plain '$0 uninstall' (without --purge) and delete the list file by hand." ;;
      /etc/qemu-ad/?*|/var/lib/qemu-ad/?*) ;;
      *) die "refusing to purge LIST_FILE=${LIST_FILE} (must be a file under /etc/qemu-ad or /var/lib/qemu-ad)
Nothing was changed. Run plain '$0 uninstall' (without --purge) and delete the list file by hand." ;;
    esac
    [[ ! -d $LIST_FILE ]] || die "refusing to purge LIST_FILE=${LIST_FILE} (is a directory)
Nothing was changed. Run plain '$0 uninstall' (without --purge) and delete the list file by hand."
  fi
  if dpkg-divert --list "$WRAPPER_PATH" | grep -q "$VENDOR_PATH"; then
    say "removing divert and restoring ${WRAPPER_PATH}"
    preflight_divert_remove
    # Drop the divert record first (no file moves). If that fails nothing has
    # changed. Then one atomic mv puts the vendor file back over the wrapper,
    # so /usr/bin/kvm exists at every instant.
    if ! dpkg-divert --local --no-rename --remove "$WRAPPER_PATH"; then
      die "dpkg-divert --remove failed; wrapper restored, nothing changed"
    fi
    if ! mv -f "$VENDOR_PATH" "$WRAPPER_PATH"; then
      dpkg-divert --local --no-rename --divert "$VENDOR_PATH" "$WRAPPER_PATH" || true
      die "could not restore ${VENDOR_PATH} to ${WRAPPER_PATH}; divert re-created, wrapper still active"
    fi
  else
    say "no divert to remove"
  fi
  if [[ $purge == "--purge" ]]; then
    say "removing ${PREFIX} and ${LIST_FILE}"
    rm -rf "$PREFIX"
    rm -f "$LIST_FILE"
  else
    say "left ${PREFIX} in place (pass --purge to remove)"
  fi
}

cmd_install() {
  need_root
  if ! have_pve; then
    echo "warning: qm/pveversion not found. Building anyway; divert still runs." >&2
  fi
  install_deps
  fetch_sources
  apply_patch
  build_qemu
  install_wrapper
  status
  cat <<EOF

next:
  $0 add-vm <vmid>
  qm set <vmid> --machine pc-q35-10.1
  qm set <vmid> --cpu host,hidden=1,hv-vendor-id=GenuineIntel
  # smbios strings go in args:; passthrough stays a hostpci line
  $0 showcmd <vmid>
  qm start <vmid>
EOF
}

usage() {
  cat <<EOF
usage: $0 <command> [args]

  install            deps, fetch, patch, build to ${PREFIX}, divert, wrapper
  add-vm <vmid>      route that guest to the side binary
  del-vm <vmid>      route that guest back to pve-qemu-kvm
  showcmd <vmid>     print vendor argv and the stripped side argv
  status
  uninstall          restore /usr/bin/kvm, keep ${PREFIX}
  uninstall --purge  also remove ${PREFIX} and the VMID list

env overrides (set in the environment, e.g. QEMU_VER=10.2.2 $0 install):
  QEMU_VER        QEMU version to build (default ${QEMU_VER})
  PREFIX          install prefix of the side QEMU (default ${PREFIX}); purged by --purge
  SRC_ROOT        where sources are fetched and unpacked (default ${SRC_ROOT})
  PATCH_REPO      git URL of the patch repository
  TARBALL_URL     QEMU source tarball URL
  QEMU_SHA256     expected SHA-256 of the tarball (built-in pin for 10.2.2)
  PATCH_SHA256    expected SHA-256 of the patch file (built-in pin for 10.2.2)
  FORCE_REBUILD   1 = rebuild even if the side binary exists
  LIST_FILE       VMID list (default ${LIST_FILE}); purged by --purge
  WRAPPER_PATH    wrapper location (default ${WRAPPER_PATH})
  VENDOR_PATH     where the vendor binary is diverted to (default ${VENDOR_PATH})
  LOG_FILE        wrapper log (default ${LOG_FILE})
  DPKG_LOCK       dpkg lock file checked before touching the divert (default ${DPKG_LOCK})
--purge only accepts PREFIX under /opt, /srv or /usr/local and LIST_FILE as a
file under /etc/qemu-ad or /var/lib/qemu-ad (canonical paths, no "." or "..").
EOF
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    install)   cmd_install "$@" ;;
    add-vm)    need_root; add_vm "${1:-}" ;;
    del-vm)    need_root; del_vm "${1:-}" ;;
    showcmd)   showcmd "${1:-}" ;;
    status)    status ;;
    uninstall) need_root; uninstall "${1:-}" ;;
    ""|-h|--help|help) usage ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
