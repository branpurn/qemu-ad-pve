#!/bin/bash
# qad-l1.sh <step>: provisioning steps that run INSIDE the nested L1 (Debian 13), called by
# setup.sh on the PVE host over SSH. Every step is idempotent and logs to
# /var/log/qemu-ad-setup/<step>.log. Settings: /etc/qemu-ad/setup.env (written by setup.sh).
#
# Steps:  packages | dkms | qemu-ad-build | qemu-ad-check | qemu-optpatch-build | qemu-optpatch-check | qemu-ad-libs PKG... | vfio | scripts | check-kvm |
#         stage | l2-install | l2-install-status | l2-wipe | l2-enable | verify | status
# Exit codes: 0 ok, 100 = reboot L1 and run the same step again, other = failure.
set -euo pipefail

REPO=${QAD_REPO:-/root/qemu-ad-pve}
ENVF=${QAD_ENV:-/etc/qemu-ad/setup.env}
W=/root/w10
STAGE=/root/qad-stage
LOGDIR=/var/log/qemu-ad-setup
# L2 SSH host key (L1 state): the Windows sshd key only exists after Setup, so the first connect
# uses accept-new; its fingerprint is then recorded in L2_PIN and every later connection
# (l2_ssh and the GPU check) uses StrictHostKeyChecking=yes. Reset on reinstall/wipe.
L2_KNOWN=$W/l2_known_hosts
L2_PIN=$W/l2_hostkey.pinned
# dkms/ (kvm-l1, MODULE_VERSION "l1-dkms-0.1") is the ONE canonical patched KVM package.
KVM_PATCH_RE='l1-dkms'
L2_UNIT=w10-l2.service  # PR #24's unit (scripts/qm-native-9200/), reused verbatim
LAB_L1_GPU='0000:02:01.0 0000:02:01.1'  # GPU BDFs hard-coded in PR #24's unit/helper
DKMS_NAME=kvm-l1
DKMS_VER=0.1.0

step=${1:-}
[ -n "$step" ] || { sed -n '2,9p' "$0" >&2; exit 64; }
[ "$(id -u)" -eq 0 ] || { echo "qad-l1.sh: needs root" >&2; exit 1; }
if [ -d /etc/pve ] || command -v pveversion >/dev/null 2>&1; then
  echo "qad-l1.sh: refusing to run on a Proxmox VE host; this runs inside the nested L1 only" >&2
  exit 3
fi
# shellcheck disable=SC1090
. "$ENVF"
mkdir -p "$LOGDIR"
case "$step" in
  l2-install-status|status|verify|check-kvm|qemu-ad-check|qemu-optpatch-check) ;;
  *) exec > >(tee -a "$LOGDIR/$step.log") 2>&1 ;;
esac
echo "=== qad-l1.sh $step $(date -Is)"

say() { printf '==> %s\n' "$*"; }
die() { printf 'qad-l1: ERROR: %s\n' "$*" >&2; exit 1; }
kmod() { if [ "$QAD_CPU_VENDOR" = intel ]; then echo kvm_intel; else echo kvm_amd; fi; }
upstream_ver() { printf '%s' "$1" | sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/'; }

# ------------------------------------------------------------------ packages
step_packages() {
  export DEBIAN_FRONTEND=noninteractive
  say "apt: kernel metapackages + build/runtime dependencies"
  apt-get update
  # Newest Debian kernel + its headers (the cloud image's own kernel may no longer have headers
  # in the archive). If that installs a newer kernel, exit 100 so setup.sh reboots L1 into it.
  apt-get install -y linux-image-amd64 linux-headers-amd64
  apt-get install -y --no-install-recommends \
    dkms build-essential pahole git ca-certificates xz-utils patch kmod pciutils \
    ovmf dnsmasq-base genisoimage python3 qemu-system-x86 qemu-utils wget openssh-client socat
  local newest
  newest=$(dpkg-query -W -f='${Depends}' linux-image-amd64 | grep -o 'linux-image-[0-9][^ ,]*' | head -1 | sed 's/^linux-image-//')
  apt-get install -y "linux-headers-$(uname -r)" || true
  if [ -n "$newest" ] && [ "$newest" != "$(uname -r)" ]; then
    say "running kernel $(uname -r), newest installed $newest: reboot needed"
    exit 100
  fi
  dpkg -s "linux-headers-$(uname -r)" >/dev/null 2>&1 || die "linux-headers-$(uname -r) not installable"
  if [ "${QAD_HOLD_KERNEL:-1}" = 1 ]; then
    # dkms/dkms.conf has AUTOINSTALL="no": a kernel update would silently boot stock KVM (and
    # start-l2.sh would then refuse). Hold the kernel; unhold deliberately and rebuild DKMS.
    apt-mark hold linux-image-amd64 linux-headers-amd64 "linux-image-$(uname -r)" "linux-headers-$(uname -r)"
  fi
  say "packages OK (kernel $(uname -r))"
}

# ------------------------------------------------------------------ patched KVM (DKMS)
fetch_debian_source() { # <kver> <upstream ver>: the L1 kernel's own Debian source, like the lab build
  local kver=$1 up=$2 mm pkgver tmp deb dest inner
  mm=$(printf '%s' "$up" | cut -d. -f1,2)
  pkgver=$(dpkg-query -W -f='${Version}' "linux-image-$kver")
  dest="$REPO/dkms/src/$up"
  tmp=$(mktemp -d /var/tmp/qad-ksrc.XXXXXX)
  say "apt-get download linux-source-$mm=$pkgver (only arch/x86/kvm + virt/kvm are kept)"
  (cd "$tmp" && apt-get download "linux-source-$mm=$pkgver")
  deb=$(ls "$tmp"/linux-source-"$mm"_*.deb)
  dpkg-deb --fsys-tarfile "$deb" | tar -xO --wildcards "*usr/src/linux-source-$mm.tar.xz" >"$tmp/src.tar.xz"
  tar -xJf "$tmp/src.tar.xz" -C "$tmp" --wildcards "*/arch/x86/kvm/*" "*/virt/kvm/*"
  inner=$(find "$tmp" -maxdepth 1 -type d -name "linux-source-$mm*" | head -1)
  [ -d "$inner/arch/x86/kvm" ] || die "linux-source-$mm did not contain arch/x86/kvm"
  rm -rf "$dest"
  mkdir -p "$dest/arch/x86" "$dest/virt"
  cp -a "$inner/arch/x86/kvm" "$dest/arch/x86/kvm"
  cp -a "$inner/virt/kvm" "$dest/virt/kvm"
  # Same hash format as dkms/fetch-kvm-source.sh, so stage.sh's --verify accepts it.
  (cd "$dest" && LC_ALL=C find arch/x86/kvm virt/kvm -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum) \
    >"$dest/SOURCE-SHA256SUMS"
  {
    echo "repo=debian:linux-source-$mm"
    echo "version=$pkgver"
    echo "deb_sha256=$(sha256sum "$deb" | awk '{print $1}')"
    echo "kernel=$kver"
    echo "fetched_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "files=$(wc -l <"$dest/SOURCE-SHA256SUMS")"
  } >"$dest/SOURCE-INFO"
  rm -rf "$tmp"
}

step_dkms() {
  local kver up src st
  kver=$(uname -r)
  up=$(upstream_ver "$kver")
  src="$REPO/dkms/src/$up"
  if [ ! -f "$src/SOURCE-SHA256SUMS" ]; then
    case "$QAD_KVM_SOURCE" in
      debian) fetch_debian_source "$kver" "$up" ;;
      upstream) "$REPO/dkms/fetch-kvm-source.sh" "$up" ;;
      *) die "unknown QAD_KVM_SOURCE=$QAD_KVM_SOURCE" ;;
    esac
  else
    say "source already staged: $src"
  fi
  # Single patched KVM package: refuse if another DKMS package (e.g. the lab's kvm-patched/1.0)
  # also ships kvm modules; docs/SETUP.md "Aligning the lab's kvm-patched/1.0" shows how to switch.
  local other
  other=$(dkms status 2>/dev/null | awk -F'[/,: ]+' '{print $1"/"$2}' | grep -v "^$DKMS_NAME/" | grep -i kvm || true)
  [ -z "$other" ] || die "another patched-KVM DKMS package is registered ($other); remove it first (docs/SETUP.md)"
  st=$(dkms status "$DKMS_NAME/$DKMS_VER" -k "$kver" 2>/dev/null || true)
  # No `cmd | grep -q` under pipefail anywhere here: grep exits at the first match, the writer can die
  # of SIGPIPE and the pipeline then reports failure (live E2E 2026-10-06: `lsmod | grep -q` made
  # check-kvm FAIL on a correct L1 every time). Match on captured output instead.
  if grep -q installed <<<"$st"; then
    say "DKMS $DKMS_NAME/$DKMS_VER already installed for $kver"
  elif grep -q . <<<"$(dkms status "$DKMS_NAME/$DKMS_VER" 2>/dev/null)"; then
    say "DKMS $DKMS_NAME/$DKMS_VER registered but not installed for $kver: build + install"
    dkms build "$DKMS_NAME/$DKMS_VER" -k "$kver"
    dkms install "$DKMS_NAME/$DKMS_VER" -k "$kver"
  else
    "$REPO/dkms/scripts/l1-dkms.sh" install
  fi
  # Boot default (docs/gpu-phase-patched-kvm-default.md): updates/dkms outranks the stock
  # module in depmod's search order, and modules-load.d loads it on every boot.
  kmod >/etc/modules-load.d/kvm-patched.conf
  local f
  f=$(modinfo -F filename kvm)
  case "$f" in
    */updates/dkms/*) say "modinfo kvm -> $f (patched module is the default after reboot)" ;;
    *) die "modinfo kvm still resolves to $f, not updates/dkms" ;;
  esac
}

# ------------------------------------------------------------------ qemu-ad-pve binary
step_qemu_ad_build() {
  # Build-only entry of qemu-ad-pve.sh: deps, fetch (pinned sha256), patch, build to /opt/qemu-ad.
  # No /usr/bin/kvm divert (there is no qemu-server in L1).
  "$REPO/qemu-ad-pve.sh" build
}

step_qemu_optpatch_build() {
  # OPT-IN (l2.optional_patches): a second QEMU in /opt/qemu-ad-optpatch with the optional patches
  # (patches/optional/, docs/optional-qemu-patches.md). /opt/qemu-ad stays untouched; the L2 only uses
  # the new binary when `scripts` writes QB= into /etc/qemu-ad-l2.env. Own source tree, so the
  # patched sources never mix with the plain build.
  [ -n "${QAD_L2_OPTIONAL_PATCHES:-}" ] || die "qemu-optpatch-build: QAD_L2_OPTIONAL_PATCHES is empty (l2.optional_patches)"
  QAD_OPTIONAL_PATCHES="${QAD_L2_OPTIONAL_PATCHES// /,}" PREFIX=/opt/qemu-ad-optpatch \
    SRC_ROOT=/opt/src-optpatch "$REPO/qemu-ad-pve.sh" build
}

step_qemu_optpatch_check() {
  local qb=/opt/qemu-ad-optpatch/bin/qemu-system-x86_64
  [ -x "$qb" ] || { echo "QEMU_OPTPATCH=missing"; exit 1; }
  echo "QEMU_OPTPATCH=$("$qb" --version | head -1) patches=$(sed 's/.*# optional-patches=//p;d' /opt/qemu-ad-optpatch/.qemu-ad-configure-flags 2>/dev/null)"
}

step_qemu_ad_libs() { # <debian package>...: runtime libraries the copied host /opt/qemu-ad needs
  # setup.sh maps the sonames qemu-ad-check reports as missing to package names with `dpkg -S` on the
  # PVE host (same Debian 13 archive), then calls this. Only installs; never removes anything.
  [ "$#" -gt 0 ] || die "qemu-ad-libs: no packages given"
  local p
  for p in "$@"; do [[ $p =~ ^[a-z0-9][a-z0-9.+-]+$ ]] || die "qemu-ad-libs: bad package name '$p'"; done
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y --no-install-recommends "$@"
  say "installed $*"
}

step_qemu_ad_check() {
  local qb=/opt/qemu-ad/bin/qemu-system-x86_64 missing
  [ -x "$qb" ] || { echo "QEMU_AD=missing"; exit 1; }
  missing=$(ldd "$qb" 2>/dev/null | awk '/not found/{print $1}' | tr '\n' ' ')
  [ -z "$missing" ] || { echo "QEMU_AD=libs-missing $missing"; exit 1; }
  echo "QEMU_AD=$("$qb" --version | head -1)"
}

# ------------------------------------------------------------------ vfio-pci for the GPU in L1
step_vfio() {
  local ids
  ids=$(printf '%s' "$QAD_GPU_IDS" | tr ' ' ',')
  cat >/etc/modprobe.d/qemu-ad-vfio.conf <<CONF
# qemu-ad-pve setup: the passed-through GPU belongs to the Windows L2, never to L1's drivers.
options vfio-pci ids=$ids
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep amdgpu pre: vfio-pci
softdep radeon pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
softdep xhci_pci pre: vfio-pci
CONF
  echo vfio-pci >/etc/modules-load.d/qemu-ad-vfio.conf
  update-initramfs -u
  say "vfio-pci claims $ids from the next boot"
}

# ------------------------------------------------------------------ scripts + service
step_scripts() {
  install -d -m 700 "$W" /root/l2
  install -m 755 "$REPO/scripts/l1-w10/start-l2.sh" "$REPO/scripts/l1-w10/resolve-windows-disk.sh" \
    "$REPO/scripts/l1-w10/mk-wheel-iso.sh" "$REPO/setup/l1/l2net-up.sh" "$REPO/setup/l1/l2net-down.sh" \
    "$REPO/setup/l1/qad-qmp.py" "$REPO/tests/w10-code43-run.sh" "$W/"
  install -m 644 "$REPO/tests/w10-code43-check.ps1" "$W/"
  [ -f /root/l2/OVMF_CODE.fd ] || install -m 644 /usr/share/OVMF/OVMF_CODE_4M.fd /root/l2/OVMF_CODE.fd
  [ -f "$W/l2_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -C "qad-l1-to-l2" -f "$W/l2_ed25519"
  local extra=""
  if [ -f "$W/stage.iso" ]; then
    extra="-drive file=$W/stage.iso,format=raw,if=none,id=stg,media=cdrom,readonly=on -device ide-cd,drive=stg,bus=ide.2"
  fi
  # one -smbios argument per line (start-l2.sh SMBIOS_FILE); empty profile = empty file
  printf '%s\n' "${QAD_L2_SMBIOS:-}" | tr '|' '\n' >"$W/smbios.txt"
  cat >/etc/qemu-ad-l2.env <<CONF
# Written by setup.sh (qad-l1.sh scripts). Read by /root/w10/start-l2.sh and l2net-up.sh.
GPU_IDS="$QAD_GPU_IDS"
L2_SMP=$QAD_L2_SMP
L2_MEM=$QAD_L2_MEM
L2_MAC=$QAD_L2_MAC
CPU=$QAD_L2_CPU
VGA=${QAD_L2_VGA:-std}
DISK_MODEL="${QAD_L2_DISK_MODEL:-}"
DISK_SERIAL="${QAD_L2_DISK_SERIAL:-}"
DISK_FW="${QAD_L2_DISK_FW:-}"
SMBIOS_FILE=$W/smbios.txt
MMIO64_MB=$QAD_MMIO64_MB
KVM_PATCH_RE='$KVM_PATCH_RE'
REQUIRE_QEMU_AD=1
WIN_DISK_SERIAL=drive-scsi1
# No NTFS UUID on greenfield installs (the lab VM 9200 value is only in
# scripts/l1-w10/qemu-ad-l2.env.lab-9200.example).
WIN_DISK_UUID=
# Size heuristic window tracks the setup-created Windows disk (lab sample is ~80G / 70-90;
# setup.sh default is 128G). Serial drive-scsi1 remains the primary identity.
WIN_DISK_MIN_GB=$(( ${QAD_L2_DISK_GB:-80} * 80 / 100 ))
WIN_DISK_MAX_GB=$(( ${QAD_L2_DISK_GB:-80} * 120 / 100 ))
L2_BRIDGE_IP=$QAD_L2_BRIDGE_IP
L2_NET_PREFIX=$QAD_L2_NET_PREFIX
L2_IP=$QAD_L2_IP
L2_DHCP_START=$QAD_L2_DHCP_START
L2_DHCP_END=$QAD_L2_DHCP_END
EXTRA="$extra"
CONF
  # OPT-IN identity settings (all default off; without them the env file is exactly as before).
  # Revert: empty the l2.* keys, `setup.sh install --redo l1_scripts`, `systemctl restart w10-l2`
  # (or copy back the /etc/qemu-ad-l2.env backup), or just delete the lines below.
  if [ -n "${QAD_L2_OPTIONAL_PATCHES:-}" ] && [ -x /opt/qemu-ad-optpatch/bin/qemu-system-x86_64 ]; then
    {
      echo "# optional QEMU patches (l2.optional_patches): $QAD_L2_OPTIONAL_PATCHES"
      echo "QB=/opt/qemu-ad-optpatch/bin/qemu-system-x86_64"
      [ -z "${QAD_L2_OEM_ID:-}" ] || printf 'OEM_ID=%q\n' "$QAD_L2_OEM_ID"
      [ -z "${QAD_L2_OEM_TABLE_ID:-}" ] || printf 'OEM_TABLE_ID=%q\n' "$QAD_L2_OEM_TABLE_ID"
      [ -z "${QAD_L2_OEM_REVISION:-}" ] || printf 'OEM_REVISION=%q\n' "$QAD_L2_OEM_REVISION"
    } >>/etc/qemu-ad-l2.env
  fi
  if [ "${QAD_L2_OVMF_IDENTITY:-0}" = 1 ] && [ -s /opt/ovmf-identity/OVMF_CODE.fd ]; then
    printf '# rebuilt OVMF (l2.ovmf_identity_dir); the persistent VARS.fd is kept\nOVMF_CODE=/opt/ovmf-identity/OVMF_CODE.fd\n' >>/etc/qemu-ad-l2.env
  fi
  install_l2_unit
  systemctl daemon-reload
  say "scripts in $W, settings /etc/qemu-ad-l2.env, unit $L2_UNIT (enabled later)"
}

# PR #24's L1 autostart unit + helper (ACPI power-down of the L2 on L1 shutdown), reused as-is.
# They hard-code the lab's L1 GPU address 02:01.0/.1; if this L1 enumerates the GPU elsewhere,
# exactly those strings are replaced (and the replacement is checked), nothing else.
install_l2_unit() {
  local src="$REPO/scripts/qm-native-9200" bdfs first tmp
  if [ ! -f "$src/w10-l2.service" ] || [ ! -f "$src/l2-service.sh" ]; then die "missing $src (qm-native-9200 files)"; fi
  bdfs=$(gpu_bdfs | tr '\n' ' ' | sed 's/ $//') || die "cannot resolve the GPU functions ($QAD_GPU_IDS) in L1"
  first=${bdfs%% *}
  tmp=$(mktemp -d)
  cp "$src/l2-service.sh" "$src/w10-l2.service" "$tmp/"
  if [ "$bdfs" != "$LAB_L1_GPU" ]; then
    say "L1 GPU is at '$bdfs' (qm-native-9200 files assume '$LAB_L1_GPU'): adapting those strings only"
    grep -qF "for d in $LAB_L1_GPU; do" "$tmp/l2-service.sh" || die "l2-service.sh changed upstream; cannot adapt"
    grep -qxF "ConditionPathExists=/sys/bus/pci/devices/0000:02:01.0" "$tmp/w10-l2.service" \
      || die "w10-l2.service changed upstream; cannot adapt"
    sed -i "s|for d in $LAB_L1_GPU; do|for d in $bdfs; do|; s|GPU 02:01.0/.1|GPU $bdfs|" "$tmp/l2-service.sh"
    sed -i "s|^ConditionPathExists=/sys/bus/pci/devices/0000:02:01.0$|ConditionPathExists=/sys/bus/pci/devices/$first|" \
      "$tmp/w10-l2.service"
  fi
  install -m 755 "$tmp/l2-service.sh" "$W/l2-service.sh"
  install -m 644 "$tmp/w10-l2.service" "/etc/systemd/system/$L2_UNIT"
  rm -rf "$tmp"
}

# ------------------------------------------------------------------ checks after reboot
gpu_bdfs() { # prints one BDF per GPU function (by vendor:device), fails unless each is unique
  local id hits
  for id in $QAD_GPU_IDS; do
    mapfile -t hits < <(lspci -Dn -d "$id" | awk '{print $1}')
    [ "${#hits[@]}" -eq 1 ] || { echo "GPU_FUNC_$id=${#hits[@]}-matches" >&2; return 1; }
    printf '%s\n' "${hits[0]}"
  done
}

step_check_kvm() {
  local ok=1 ver file bdf drv grp groups=""
  ver=$(cat /sys/module/kvm/version 2>/dev/null || echo none)
  file=$(modinfo -F filename kvm 2>/dev/null || echo none)
  echo "KVM_VERSION=$ver"
  echo "KVM_FILE=$file"
  [[ $ver =~ $KVM_PATCH_RE ]] || ok=0
  case "$file" in */updates/dkms/*) ;; *) ok=0 ;; esac
  [ -d "/sys/module/$(kmod)" ] || ok=0  # was `lsmod | grep -q`: SIGPIPE + pipefail = false FAIL
  echo "KVM_MODULE=$(kmod) loaded=$(lsmod | grep -c "^$(kmod) ")"
  if compgen -G '/sys/class/iommu/dmar*' >/dev/null; then echo "DMAR=yes"; else echo "DMAR=no"; ok=0; fi
  if bdfs=$(gpu_bdfs); then
    for bdf in $bdfs; do
      drv=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null)" 2>/dev/null || echo none)
      grp=$(basename "$(readlink "/sys/bus/pci/devices/$bdf/iommu_group" 2>/dev/null)" 2>/dev/null || echo none)
      echo "GPU_FUNC=$bdf driver=$drv group=$grp"
      [ "$drv" = vfio-pci ] || ok=0
      groups="$groups $grp"
    done
    [ "$(printf '%s' "$groups" | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l)" -eq 1 ] || { echo "GPU_GROUPS=split:$groups"; ok=0; }
  else
    ok=0
  fi
  echo "CHECK_KVM=$([ $ok = 1 ] && echo PASS || echo FAIL)"
  [ $ok = 1 ]
}

# ------------------------------------------------------------------ staging ISOs
step_stage() {
  local s="$STAGE/iso" in="$STAGE/in"
  rm -rf "$s"
  mkdir -p "$s/qad" "$in"
  install -m 644 "$REPO/setup/l1/windows/firstlogon.ps1" "$REPO/setup/l1/windows/gpu-driver.ps1" "$s/qad/"
  install -m 644 "$REPO/tests/w10-code43-check.ps1" "$REPO/scripts/l1-w10/pytorch-offline-bench.py" "$s/qad/"
  install -m 644 "$W/l2_ed25519.pub" "$s/qad/authorized_keys"
  # Downloads (only present when setup.sh ran with --download-proprietary): sha256-checked.
  if [ -s "$STAGE/downloads.txt" ]; then
    local url sha name
    mkdir -p "$in/downloads"
    while read -r url sha name; do
      [ -n "$url" ] || continue
      if [ ! -f "$in/downloads/$name" ] || ! echo "$sha  $in/downloads/$name" | sha256sum -c --quiet; then
        say "download $name"
        wget -q -O "$in/downloads/$name.part" "$url"
        echo "$sha  $in/downloads/$name.part" | sha256sum -c --quiet || die "sha256 mismatch for $url"
        mv "$in/downloads/$name.part" "$in/downloads/$name"
      fi
    done <"$STAGE/downloads.txt"
  fi
  local f
  for f in "$in"/nvidia_driver/* "$in"/downloads/*-desktop-win*.exe "$in"/downloads/*nvidia*.exe; do
    [ -f "$f" ] && { mkdir -p "$s/qad/nvidia"; cp -- "$f" "$s/qad/nvidia/"; }
  done
  for f in "$in"/python_installer/* "$in"/downloads/python-*.exe; do
    [ -f "$f" ] && { mkdir -p "$s/qad/python"; cp -- "$f" "$s/qad/python/"; }
  done
  for f in "$in"/openssh_zip/* "$in"/downloads/OpenSSH-Win64*.zip; do
    [ -f "$f" ] && { mkdir -p "$s/qad/openssh"; cp -- "$f" "$s/qad/openssh/"; }
  done
  if compgen -G "$in/wheelhouse/*.whl" >/dev/null || compgen -G "$in/downloads/*.whl" >/dev/null; then
    mkdir -p "$s/wheelhouse"
    cp -- "$in"/wheelhouse/* "$s/wheelhouse/" 2>/dev/null || true
    cp -- "$in"/downloads/*.whl "$s/wheelhouse/" 2>/dev/null || true
    (cd "$s/wheelhouse" && for c in SHA256SUMS*; do if [ -e "$c" ]; then sha256sum -c "$c"; fi; done)
  fi
  for f in "$in"/extra/*; do
    [ -f "$f" ] && { mkdir -p "$s/extra"; cp -- "$f" "$s/extra/"; }
  done
  # Same genisoimage flags as scripts/l1-w10/mk-wheel-iso.sh (Joliet long names, files > 2 GiB).
  genisoimage -quiet -o "$W/stage.iso.tmp" -V QADSTAGE -J -joliet-long -R -iso-level 3 "$s"
  mv "$W/stage.iso.tmp" "$W/stage.iso"
  rm -rf "$s"
  if [ -f "$STAGE/autounattend.xml" ]; then
    local u="$STAGE/unattend-iso"
    rm -rf "$u"; mkdir -p "$u"
    install -m 600 "$STAGE/autounattend.xml" "$u/autounattend.xml"
    genisoimage -quiet -o "$W/autounattend.iso.tmp" -V QADUNATTEND -J -R "$u"
    chmod 600 "$W/autounattend.iso.tmp"
    mv "$W/autounattend.iso.tmp" "$W/autounattend.iso"
    rm -rf "$u"
  fi
  step_scripts >/dev/null  # refresh EXTRA in /etc/qemu-ad-l2.env so normal boots see stage.iso
  say "stage.iso $(du -h "$W/stage.iso" | cut -f1)$([ -f "$W/autounattend.iso" ] && echo ', autounattend.iso')"
}

# ------------------------------------------------------------------ Windows L2 creation
find_win_cd() { # the Windows ISO is attached to L1 as a CD; find it by its volume label
  local d lab hits=()
  for d in $(lsblk -dpno NAME,TYPE | awk '$2=="rom"{print $1}'); do
    lab=$(lsblk -dno LABEL "$d" 2>/dev/null || true)
    if [ -n "$QAD_WIN_ISO_LABEL" ]; then
      if [ "$lab" = "$QAD_WIN_ISO_LABEL" ]; then printf '%s\n' "$d"; return 0; fi
    elif [ -n "$lab" ] && [ "$lab" != cidata ]; then
      hits+=("$d")  # label unknown on the host: accept the single non-seed CD
    fi
  done
  if [ "${#hits[@]}" -eq 1 ]; then printf '%s\n' "${hits[0]}"; return 0; fi
  return 1
}

step_l2_install() {
  if systemctl is-active --quiet qemu-ad-l2-install; then say "install already running"; return 0; fi
  if [ -f "$W/install.state" ] && grep -qx DONE "$W/install.state"; then say "L2 already created"; return 0; fi
  systemctl is-active --quiet "$L2_UNIT" && die "$L2_UNIT is running; refusing to install over it"
  systemctl reset-failed qemu-ad-l2-install 2>/dev/null || true
  local secs=$(( QAD_INSTALL_TIMEOUT_MIN * 60 ))
  l2_forget_hostkey  # a new Windows install generates a new sshd host key
  echo RUNNING >"$W/install.state"
  systemd-run --unit=qemu-ad-l2-install --description="qemu-ad-pve: create Windows L2 (no GPU)" \
    --property=RuntimeMaxSec="$secs" --collect \
    /bin/bash "$REPO/setup/l1/qad-l2-create.sh"
  say "started unit qemu-ad-l2-install (timeout ${QAD_INSTALL_TIMEOUT_MIN} min); VNC (L1-local): $QAD_VNC"
}

step_l2_install_status() {
  local st
  st=$(cat "$W/install.state" 2>/dev/null || echo NONE)
  if [ "$st" = RUNNING ] && ! systemctl is-active --quiet qemu-ad-l2-install; then
    st=FAILED
    echo FAILED >"$W/install.state"
  fi
  echo "INSTALL_STATE=$st"
  tail -n 3 "$LOGDIR/l2-create.log" 2>/dev/null | sed 's/^/INSTALL_LOG=/' || true
}

step_l2_wipe() {
  # Only for `setup.sh install --redo l2_install --wipe-l2-disk`: clear a half-installed Windows disk.
  # Target = the ONE disk whose serial is exactly drive-scsi1, never mounted / ext4 / root.
  systemctl is-active --quiet qemu-ad-l2-install && die "install unit still running"
  systemctl is-active --quiet "$L2_UNIT" && die "$L2_UNIT is running"
  local d serial hits=()
  for d in $(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}'); do
    serial=$(udevadm info --query=property --name="$d" 2>/dev/null | awk -F= '/^ID_SERIAL_SHORT=/{print $2}')
    [ "$serial" = drive-scsi1 ] && hits+=("$d")
  done
  [ "${#hits[@]}" -eq 1 ] || die "expected exactly one disk with serial drive-scsi1, found ${#hits[@]}"
  d=${hits[0]}
  grep -q . <<<"$(lsblk -no MOUNTPOINT "$d")" && die "$d has mounted partitions"
  grep -qx ext4 <<<"$(lsblk -no FSTYPE "$d")" && die "$d has an ext4 filesystem (L1 root?)"
  say "wiping signatures on $d (serial drive-scsi1)"
  lsblk -lnpo NAME,TYPE "$d" | awk '$2=="part"{print $1}' | while read -r p; do wipefs -a "$p"; done
  wipefs -a "$d"
  rm -f "$W/install.state" "$W/VARS.install.fd"
  l2_forget_hostkey
}

step_l2_enable() {
  [ -f "$W/VARS.fd" ] || die "no $W/VARS.fd (L2 not created yet)"
  rm -f "$W/autounattend.iso"  # contains the admin password; only needed during Setup
  systemctl enable "$L2_UNIT"
  systemctl start "$L2_UNIT"
  systemctl --no-pager --lines=5 status "$L2_UNIT" || true
}

# ------------------------------------------------------------------ verify / status
l2_strict() { # yes once the L2 host key is pinned, accept-new before the first connect
  if [ -s "$L2_PIN" ] && [ -s "$L2_KNOWN" ]; then echo yes; else echo accept-new; fi
}

l2_forget_hostkey() {
  rm -f "$L2_KNOWN" "$L2_PIN"
}

l2_pin_hostkey() { # record the key accept-new just stored; no-op when already pinned
  [ "$(l2_strict)" = yes ] && return 0
  [ -s "$L2_KNOWN" ] || return 1
  if ! (umask 077 && ssh-keygen -lf "$L2_KNOWN" >"$L2_PIN.tmp" && mv -f "$L2_PIN.tmp" "$L2_PIN"); then
    rm -f "$L2_PIN.tmp"
    return 1
  fi
  echo "L2 host key pinned: $(cut -d' ' -f2 "$L2_PIN" | tr '\n' ' ')" >&2
}

l2_ssh() {
  local strict rc=0
  strict=$(l2_strict)
  if [ "$strict" = yes ] && [ "$(ssh-keygen -lf "$L2_KNOWN" 2>/dev/null)" != "$(cat "$L2_PIN")" ]; then
    echo "L2 known_hosts ($L2_KNOWN) no longer matches the pinned key ($L2_PIN); refusing." >&2
    echo "If Windows was reinstalled outside setup.sh: rm -f $L2_KNOWN $L2_PIN" >&2
    return 255
  fi
  ssh -i "$W/l2_ed25519" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking="$strict" \
    -o UserKnownHostsFile="$L2_KNOWN" "$QAD_ADMIN_USER@$QAD_L2_IP" "$@" || rc=$?
  # rc 255 = ssh itself failed (refused, auth, host key); anything else means we were connected.
  if [ "$strict" = accept-new ] && [ "$rc" -ne 255 ]; then l2_pin_hostkey || true; fi
  return "$rc"
}

step_verify() {
  local rc=0 pid st
  step_check_kvm || rc=1
  pid=$(cat "$W/w10.pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    st=$(python3 "$W/qad-qmp.py" "$W/qmp" status 2>/dev/null || echo unknown)
    echo "L2_RUNNING=yes pid=$pid qmp=$st exe=$(readlink "/proc/$pid/exe")"
  else
    echo "L2_RUNNING=no"; rc=1
  fi
  echo "L2_SERVICE=$(systemctl is-active "$L2_UNIT" || true) enabled=$(systemctl is-enabled "$L2_UNIT" 2>/dev/null || true)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    local out code
    # First connect pins the L2 host key; the GPU check then uses the same known_hosts + policy
    # (before: root's default known_hosts with BatchMode, i.e. "Host key verification failed").
    l2_ssh 'exit 0' >/dev/null 2>&1 || true
    echo "L2_HOSTKEY=$([ "$(l2_strict)" = yes ] && echo pinned || echo not-pinned)"
    out=$(W10_KNOWN_HOSTS="$L2_KNOWN" W10_STRICT_HOST_KEY="$(l2_strict)" \
      W10_CHECK_PS1="$W/w10-code43-check.ps1" "$W/w10-code43-run.sh" "$QAD_L2_IP" "$QAD_ADMIN_USER" \
      --key "$W/l2_ed25519" --ssh-direct 2>"$W/verify-ssh.err") && code=0 || code=$?
    printf '%s\n' "$out" | tr -d '\n' | sed 's/^/GPU_JSON=/'; echo
    case $code in
      0) echo "GPU_CODE=0 (ok)" ;;
      43) echo "GPU_CODE=43"; rc=1 ;;
      3) echo "GPU_CODE=no-nvidia-device"; rc=1 ;;
      *) echo "GPU_CODE=unknown (ssh/check rc=$code: $(tail -n 2 "$W/verify-ssh.err" | tr '\n' ' '))"; rc=1 ;;
    esac
    local cuda=${QAD_VERIFY_CUDA:-auto}
    if [ "$cuda" != no ]; then
      local venv_rc=0
      l2_ssh 'if exist C:\qad\venv\Scripts\python.exe (exit 0) else (exit 1)' 2>/dev/null || venv_rc=$?
      if [ "$venv_rc" -eq 0 ]; then
        if l2_ssh 'C:\qad\venv\Scripts\python.exe C:\qad\pytorch-offline-bench.py' >"$W/verify-cuda.log" 2>&1; then
          echo "CUDA=PASS $(grep '^RESULT' "$W/verify-cuda.log" | tail -1)"
        else
          echo "CUDA=FAIL $(tail -n 2 "$W/verify-cuda.log" | tr '\n' ' ')"; rc=1
        fi
      elif [ "$venv_rc" -eq 255 ]; then
        # ssh itself failed: say so instead of "torch not staged" (live E2E 2026-10-06, sshd down)
        echo "CUDA=SKIP (L2 not reachable over SSH; torch status unknown)"; rc=1
      elif [ "$cuda" = yes ]; then
        printf '%s\n' 'CUDA=FAIL (no C:\qad\venv with torch in L2)'; rc=1
      else
        echo "CUDA=SKIP (torch not staged)"
      fi
    fi
  fi
  echo "VERIFY=$([ $rc = 0 ] && echo PASS || echo FAIL)"
  return $rc
}

step_status() {
  echo "L1_KERNEL=$(uname -r)"
  echo "KVM_VERSION=$(cat /sys/module/kvm/version 2>/dev/null || echo none)"
  echo "DKMS=$(dkms status "$DKMS_NAME" 2>/dev/null | tr '\n' ' ')"
  echo "QEMU_AD=$(/opt/qemu-ad/bin/qemu-system-x86_64 --version 2>/dev/null | head -1 || echo missing)"
  echo "INSTALL_STATE=$(cat "$W/install.state" 2>/dev/null || echo NONE)"
  echo "L2_SERVICE=$(systemctl is-active "$L2_UNIT" 2>/dev/null || true)"
  echo "L2_IP=$QAD_L2_IP"
  echo "L2_HOSTKEY=$([ "$(l2_strict)" = yes ] && echo pinned || echo not-pinned)"
}

case "$step" in
  packages) step_packages ;;
  dkms) step_dkms ;;
  qemu-ad-build) step_qemu_ad_build ;;
  qemu-ad-check) step_qemu_ad_check ;;
  qemu-ad-libs) step_qemu_ad_libs "${@:2}" ;;
  qemu-optpatch-build) step_qemu_optpatch_build ;;
  qemu-optpatch-check) step_qemu_optpatch_check ;;
  vfio) step_vfio ;;
  scripts) step_scripts ;;
  check-kvm) step_check_kvm ;;
  stage) step_stage ;;
  l2-install) step_l2_install ;;
  l2-install-status) step_l2_install_status ;;
  l2-enable) step_l2_enable ;;
  l2-wipe) step_l2_wipe ;;
  verify) step_verify ;;
  status) step_status ;;
  *) echo "unknown step: $step" >&2; exit 64 ;;
esac
