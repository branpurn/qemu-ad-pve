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
# - A machine type of pc-q35-X.Y+pveN will not boot on vanilla QEMU. The
#   wrapper strips a trailing +pve<N> from each argument before the exec.
#   Pin the guest to a version this tree knows anyway (pc-q35-10.1 is safe
#   on the 10.2.2 build).
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
# Guest config that actually uses the patch (set these yourself, per VMID)
# -------------------------------------------------------------------------
#   cpu: host,hidden=1,hv-vendor-id=GenuineIntel
#   machine: pc-q35-10.1
#   args: -smbios type=1,manufacturer=ASUS,product=System,serial=...
#   hostpci0: 0000:01:00,pcie=1,romfile=/var/lib/qemu-ad/gpu.rom
# hidden=1 is the stock Proxmox knob (kvm hidden + hypervisor bit clear).
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
  apt-get update
  apt-get install -y \
    git wget ca-certificates build-essential ninja-build pkg-config \
    python3 python3-venv meson flex bison \
    libglib2.0-dev libpixman-1-dev zlib1g-dev \
    libaio-dev liburing-dev
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

  local tarball="${SRC_ROOT}/qemu-${QEMU_VER}.tar.xz"
  if [[ ! -f $tarball ]]; then
    say "downloading ${TARBALL_URL}"
    wget -O "$tarball" "$TARBALL_URL"
  fi
  if [[ ! -d $SRC_DIR ]]; then
    say "extracting qemu-${QEMU_VER}"
    tar -C "$SRC_ROOT" -xJf "$tarball"
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
  # --reject leaves .rej files instead of a half-applied tree we cannot see.
  git -C "$SRC_DIR" apply --check "$PATCH_FILE"
  git -C "$SRC_DIR" apply "$PATCH_FILE"
  date -Is > "$stamp"
}

build_qemu() {
  if [[ -x $SIDE_BIN && ${FORCE_REBUILD:-0} -ne 1 ]]; then
    say "side binary already installed at ${SIDE_BIN} (set FORCE_REBUILD=1 to redo)"
    return 0
  fi
  say "configuring QEMU ${QEMU_VER} with prefix ${PREFIX}"
  # --prefix is the whole point. A default configure installs into /usr/local
  # and will shadow other tools on PATH. qm calls /usr/bin/kvm by absolute
  # path, but anything else that searches PATH would pick up the side build.
  (
    cd "$SRC_DIR"
    ./configure \
      --prefix="$PREFIX" \
      --target-list=x86_64-softmmu \
      --enable-kvm \
      --enable-linux-aio \
      --enable-linux-io-uring \
      --disable-docs \
      --disable-werror
    make -j"$(nproc)"
    make install
  )
  [[ -x $SIDE_BIN ]] || die "build finished but ${SIDE_BIN} is missing"
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
write_wrapper() {
  local out="${1:-$WRAPPER_PATH}"
  say "writing ${out}"
  cat > "$out" <<EOF
#!/bin/bash
# Generated by qemu-ad-pve.sh. Do not edit in place; re-run the installer.
# Listed VMIDs exec the side QEMU. Everything else execs the vendor binary.
real=${VENDOR_PATH}
side=${SIDE_BIN}
list=${LIST_FILE}
log=${LOG_FILE}

id=""
for a in "\$@"; do
  case "\$a" in
    */qemu-server/[0-9]*.pid|*/qemu-server/[0-9]*.qmp|*/qemu-server/[0-9]*.qmp,*)
      id=\$(printf '%s\n' "\$a" | sed -n 's#.*/qemu-server/\\([0-9][0-9]*\\)\\..*#\\1#p' | head -1)
      [[ -n \$id ]] && break
      ;;
  esac
done

if [[ -n \$id ]] && [[ -f \$list ]] && grep -qx "\$id" "\$list"; then
  args=()
  prev=""
  skip=0
  for a in "\$@"; do
    if (( skip )); then skip=0; prev=\$a; continue; fi
    # Vendor-only dummy option: "-id <vmid>". Vanilla QEMU has no -id.
    if [[ \$a == -id ]]; then skip=1; prev=\$a; continue; fi
    # pc-q35-10.1+pve1 -> pc-q35-10.1, only inside the -machine argument.
    if [[ \$prev == -machine || \$prev == -M ]]; then
      while [[ \$a =~ ^(.*)\+pve[0-9]+(.*)\$ ]]; do a=\${BASH_REMATCH[1]}\${BASH_REMATCH[2]}; done
    fi
    args+=("\$a")
    prev=\$a
  done
  if [[ -w \$log || ! -e \$log ]]; then
    printf '%s vmid=%s exec %s\\n' "\$(date -Is)" "\$id" "\$side" >> "\$log" || true
  fi
  exec "\$side" "\${args[@]}"
fi

exec "\$real" "\$@"
EOF
  chmod 755 "$out"
}

install_wrapper() {
  [[ -x $SIDE_BIN ]] || die "side binary missing; build first"
  install -d "$(dirname "$LIST_FILE")"
  [[ -f $LIST_FILE ]] || : > "$LIST_FILE"

  # Stage and syntax-check the wrapper BEFORE touching /usr/bin/kvm, so a
  # write failure cannot leave the host without a kvm binary. The final
  # mv is an atomic rename in the same directory.
  local staged="${WRAPPER_PATH}.qemu-ad-new"
  trap 'rm -f "$staged"' RETURN
  write_wrapper "$staged"
  bash -n "$staged" || die "generated wrapper failed bash -n; nothing changed"

  # dpkg-divert --local survives package upgrades: pve-qemu-kvm's new
  # /usr/bin/kvm lands on $VENDOR_PATH instead of replacing the wrapper.
  # --rename moves the currently installed file (binary or symlink) aside.
  if ! dpkg-divert --list "$WRAPPER_PATH" | grep -q "$VENDOR_PATH"; then
    say "diverting ${WRAPPER_PATH} -> ${VENDOR_PATH}"
    dpkg-divert --local --rename --divert "$VENDOR_PATH" "$WRAPPER_PATH"
  else
    say "divert already in place"
  fi
  [[ -e $VENDOR_PATH ]] || die "divert claimed success but ${VENDOR_PATH} is missing"
  mv -f "$staged" "$WRAPPER_PATH"
  say "wrapper installed. VMIDs in ${LIST_FILE} use ${SIDE_BIN}"
}

add_vm() {
  local id="${1:-}"
  [[ $id =~ ^[0-9]+$ ]] || die "add-vm needs a numeric VMID"
  install -d "$(dirname "$LIST_FILE")"
  [[ -f $LIST_FILE ]] || : > "$LIST_FILE"
  if grep -qx "$id" "$LIST_FILE"; then
    say "VMID ${id} already listed"
  else
    printf '%s\n' "$id" >> "$LIST_FILE"
    say "VMID ${id} will launch on ${SIDE_BIN}"
  fi
  say "set machine to a vanilla type (pc-q35-10.1) and cpu: host,hidden=1 before starting"
}

del_vm() {
  local id="${1:-}"
  [[ $id =~ ^[0-9]+$ ]] || die "del-vm needs a numeric VMID"
  [[ -f $LIST_FILE ]] || die "no list at ${LIST_FILE}"
  local tmp
  tmp=$(mktemp)
  grep -vx "$id" "$LIST_FILE" > "$tmp" || true
  mv "$tmp" "$LIST_FILE"
  say "VMID ${id} removed; next start uses the vendor binary"
}

showcmd() {
  local id="${1:-}"
  [[ $id =~ ^[0-9]+$ ]] || die "showcmd needs a numeric VMID"
  command -v qm >/dev/null 2>&1 || die "qm not on PATH"
  say "qm showcmd ${id} (vendor view)"
  qm showcmd "$id" --pretty || true
  say "side-binary view ( +pveN stripped ); not executed"
  # Reconstruct the rewrite the wrapper would do, without exec.
  local line
  while IFS= read -r line; do
    printf '%s\n' "$line" | sed -E 's/\+pve[0-9]+//g'
  done < <(qm showcmd "$id")
}

status() {
  echo "prefix:     ${PREFIX}"
  echo "side bin:   ${SIDE_BIN}"
  if [[ -x $SIDE_BIN ]]; then
    echo "side ver:   $($SIDE_BIN --version | head -1)"
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
  if dpkg-divert --list "$WRAPPER_PATH" | grep -q "$VENDOR_PATH"; then
    say "removing divert and restoring ${WRAPPER_PATH}"
    # Move the wrapper aside instead of deleting it, so a failed
    # dpkg-divert --remove cannot leave the host with no /usr/bin/kvm.
    local aside="${WRAPPER_PATH}.qemu-ad-removed"
    [[ -e $WRAPPER_PATH ]] && mv -f "$WRAPPER_PATH" "$aside"
    if dpkg-divert --local --rename --remove "$WRAPPER_PATH"; then
      rm -f "$aside"
    else
      [[ -e $aside ]] && mv -f "$aside" "$WRAPPER_PATH"
      die "dpkg-divert --remove failed; wrapper restored, nothing changed"
    fi
  else
    say "no divert to remove"
  fi
  if [[ $purge == "--purge" ]]; then
    case "$PREFIX" in
      /opt/?*|/usr/local/?*|/srv/?*) ;;
      *) die "refusing to purge PREFIX=${PREFIX} (must be under /opt, /usr/local or /srv)" ;;
    esac
    say "removing ${PREFIX} and ${LIST_FILE}"
    rm -rf "$PREFIX" "$LIST_FILE"
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

env: QEMU_VER PREFIX SRC_ROOT FORCE_REBUILD=1
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
