#!/usr/bin/env bash
# Build Debian's edk2 OVMF (the package `ovmf`) with a different firmware identity.
# Lab/dev software compatibility only. NOT run by setup.sh and it never touches a running VM:
# it builds in a work directory and leaves OVMF_CODE_4M.fd / OVMF_VARS_4M.fd in $OUT.
#
# Why a rebuild: the third string of the Windows registry value
#   HKLM\HARDWARE\DESCRIPTION\System\SystemBiosVersion   = "<vendor> - <revision>"
# is the EFI System Table FirmwareVendor + FirmwareRevision, which OVMF bakes in at build time
# (PCDs PcdFirmwareVendor / PcdFirmwareRevision; Debian's debian/rules sets the vendor to
# "Debian distribution of EDK II"). Nothing at run time (QEMU options, SMBIOS, fw_cfg) can change it.
# The firmware also adds the BGRT ACPI table with its own OEM IDs (PcdAcpiDefaultOem*).
#
# Usage (as root on a Debian 13 build host or scratch VM, e.g. a throwaway VM, NOT a Proxmox host):
#   scripts/ovmf-identity/build-ovmf-identity.sh [--print-pcd] [--no-deps]
# Environment (defaults in brackets):
#   WORKDIR [/root/scratch-ovmf]   OUT [$WORKDIR/out]
#   OVMF_VENDOR ["American Megatrends International, LLC."]   OVMF_REVISION [0x5001B]
#   OVMF_VERSION_STRING [1654]   OVMF_RELEASE_DATE [01/12/2024]
#   ACPI_OEM_ID [ALASKA] (max 6)   ACPI_OEM_TABLE_ID ["A M I"] (max 8)   ACPI_OEM_REVISION [0x1072009]
# --print-pcd prints the flags that would be passed to the build and exits (no network, no root).
set -euo pipefail

WORKDIR="${WORKDIR:-/root/scratch-ovmf}"
OUT="${OUT:-$WORKDIR/out}"
OVMF_VENDOR="${OVMF_VENDOR:-American Megatrends International, LLC.}"
OVMF_REVISION="${OVMF_REVISION:-0x5001B}"
OVMF_VERSION_STRING="${OVMF_VERSION_STRING:-1654}"
OVMF_RELEASE_DATE="${OVMF_RELEASE_DATE:-01/12/2024}"
ACPI_OEM_ID="${ACPI_OEM_ID:-ALASKA}"
ACPI_OEM_TABLE_ID="${ACPI_OEM_TABLE_ID:-A M I}"
ACPI_OEM_REVISION="${ACPI_OEM_REVISION:-0x1072009}"

die() { echo "error: $*" >&2; exit 1; }

# 8-byte space padded ASCII -> little-endian UINT64 literal (the PCD type of PcdAcpiDefaultOemTableId)
tid_hex() {
  local s i h=""
  s=$(printf '%-8s' "$1")
  for ((i = 7; i >= 0; i--)); do h+=$(printf '%02x' "'${s:i:1}"); done
  printf '0x%s' "$h"
}

validate() {
  [[ $OVMF_VENDOR =~ ^[A-Za-z0-9\ .,_-]+$ ]] || die "OVMF_VENDOR: letters, digits, space . , _ - only"
  [[ $OVMF_VERSION_STRING =~ ^[A-Za-z0-9._-]+$ ]] || die "OVMF_VERSION_STRING: letters, digits . _ - only"
  [[ $OVMF_RELEASE_DATE =~ ^[0-9]{2}/[0-9]{2}/[0-9]{4}$ ]] || die "OVMF_RELEASE_DATE must be MM/DD/YYYY"
  [[ $OVMF_REVISION =~ ^0x[0-9A-Fa-f]{1,8}$ ]] || die "OVMF_REVISION must be hex like 0x5001B"
  [[ $ACPI_OEM_REVISION =~ ^0x[0-9A-Fa-f]{1,8}$ ]] || die "ACPI_OEM_REVISION must be hex like 0x1072009"
  [[ $ACPI_OEM_ID =~ ^[A-Za-z0-9\ ]{1,6}$ ]] || die "ACPI_OEM_ID: 1-6 letters/digits/spaces"
  [[ $ACPI_OEM_TABLE_ID =~ ^[A-Za-z0-9\ ]{1,8}$ ]] || die "ACPI_OEM_TABLE_ID: 1-8 letters/digits/spaces"
}

# The flags, in the form debian/rules uses for its own PCD_FLAGS (it expands them in a shell).
pcd_flags() {
  printf '%s' "--pcd PcdFirmwareVendor=L\"${OVMF_VENDOR}\\\\0\""
  printf ' %s' "--pcd PcdFirmwareRevision=${OVMF_REVISION}"
  printf ' %s' "--pcd PcdFirmwareVersionString=L\"${OVMF_VERSION_STRING}\\\\0\""
  printf ' %s' "--pcd PcdFirmwareReleaseDateString=L\"${OVMF_RELEASE_DATE}\\\\0\""
  printf ' %s' "--pcd PcdAcpiDefaultOemId=\"${ACPI_OEM_ID}\""
  printf ' %s' "--pcd PcdAcpiDefaultOemTableId=$(tid_hex "$ACPI_OEM_TABLE_ID")"
  printf ' %s\n' "--pcd PcdAcpiDefaultOemRevision=${ACPI_OEM_REVISION}"
}

print_only=0; deps=1
for a in "$@"; do
  case $a in
    --print-pcd) print_only=1 ;;
    --no-deps) deps=0 ;;
    -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
    *) die "unknown argument $a" ;;
  esac
done
validate
if (( print_only )); then pcd_flags; exit 0; fi

[[ $EUID -eq 0 ]] || die "run as root (apt-get build-dep) or use --no-deps with the build dependencies already installed"
if [[ -e /etc/pve || -x /usr/bin/pveversion ]]; then
  die "this looks like a Proxmox VE host; build in a scratch VM or container instead (it installs a toolchain)"
fi
command -v apt-get >/dev/null || die "needs a Debian/Ubuntu build host (apt-get source edk2)"

mkdir -p "$WORKDIR" "$OUT"
cd "$WORKDIR"
# deb-src is needed for `apt-get source` / `build-dep`
if ! grep -rqs '^\(Types:.*deb-src\|deb-src\)' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
  die "no deb-src entry in apt sources (Debian 13: add deb-src to Types: in /etc/apt/sources.list.d/debian.sources, apt-get update)"
fi
if (( deps )); then
  apt-get update -q
  apt-get build-dep -y -q edk2
fi
if ! ls -d edk2-*/ >/dev/null 2>&1; then
  apt-get source -q edk2
fi
src=$(ls -d "$WORKDIR"/edk2-*/ | head -n1)
cd "$src"
rm -rf debian/ovmf-install   # make would otherwise think the old images are up to date
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}" \
  make -f debian/rules build-ovmf PCD_FLAGS="$(pcd_flags)"
install -m 0644 debian/ovmf-install/OVMF_CODE_4M.fd debian/ovmf-install/OVMF_VARS_4M.fd "$OUT"/
echo "built: $OUT/OVMF_CODE_4M.fd $OUT/OVMF_VARS_4M.fd"
echo "vendor: ${OVMF_VENDOR}; revision ${OVMF_REVISION}; ACPI OEM ${ACPI_OEM_ID} / ${ACPI_OEM_TABLE_ID} / ${ACPI_OEM_REVISION}"
