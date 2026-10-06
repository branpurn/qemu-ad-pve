#!/bin/bash
# Resolve the Windows L2 disk at runtime. Prefer stable identity over device name.
# Priority: ID_SERIAL_SHORT=drive-scsi1 -> NTFS UUID (only if WIN_DISK_UUID is set) / LABEL=Windows
# -> NTFS + size window.
# Refuse: any mountpoint under the disk, any ext4 partition, ambiguous multi-match.
#
# Environment (serial default drive-scsi1 = the setup.sh/qm layout; label/size defaults = the lab disk):
#   WIN_DISK_SERIAL / WIN_DISK_LABEL / WIN_DISK_UUID   identities to score (WIN_DISK_UUID has no
#                                                   default: greenfield installs rely on the serial;
#                                                   the lab VM 9200 value lives in
#                                                   scripts/l1-w10/qemu-ad-l2.env.lab-9200.example)
#   WIN_DISK_MIN_GB / WIN_DISK_MAX_GB                 size window for the ntfs+size heuristic
#                                                   (defaults 70/90 for the lab ~80G disk; setup.sh
#                                                   writes ±20% of l2.disk_gb into /etc/qemu-ad-l2.env)
#   WIN_DISK_ALLOW_BLANK=1   (Windows *install* only, used by setup.sh) also accept a completely
#                            blank disk (no partition table, no filesystem signature), but ONLY when
#                            its serial is exactly WIN_DISK_SERIAL. All refuse rules still apply.
set -euo pipefail

prefer_serial="${WIN_DISK_SERIAL:-drive-scsi1}"
prefer_label="${WIN_DISK_LABEL:-Windows}"
prefer_uuid="${WIN_DISK_UUID:-}"
min_bytes=$(( ${WIN_DISK_MIN_GB:-70} * 1024 * 1024 * 1024 ))
max_bytes=$(( ${WIN_DISK_MAX_GB:-90} * 1024 * 1024 * 1024 ))
allow_blank="${WIN_DISK_ALLOW_BLANK:-0}"

candidates=()
declare -A why
declare -A blank

# is_blank <disk>: no partitions, no partition table, no filesystem/RAID/LVM signature.
is_blank() {
  local d="$1" n
  n=$(lsblk -no NAME "$d" 2>/dev/null | wc -l)
  [ "$n" -eq 1 ] || return 1
  [ -z "$(lsblk -dno PTTYPE,FSTYPE "$d" 2>/dev/null | tr -d '[:space:]')" ] || return 1
  [ -z "$(wipefs -n "$d" 2>/dev/null | tail -n +2)" ] || return 1
  return 0
}

is_refused() {
  local d="$1"
  # mounted anywhere on this disk?
  # Captured output, not `lsblk | grep -q`: with pipefail a SIGPIPE'd lsblk turns a match into a
  # failure, i.e. a refusal check that silently passes.
  if grep -q . <<<"$(lsblk -no MOUNTPOINT "$d" 2>/dev/null)"; then
    echo "REFUSE $d: has mounted partition(s)" >&2
    return 0
  fi
  # ext4 anywhere (L1 root signature)
  if grep -qx ext4 <<<"$(lsblk -no FSTYPE "$d" 2>/dev/null)"; then
    echo "REFUSE $d: has ext4 filesystem (likely L1 root)" >&2
    return 0
  fi
  # also refuse if root/boot is on this disk via findmnt
  local src
  src=$(findmnt -no SOURCE / 2>/dev/null || true)
  if [ -n "$src" ] && [ "$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)" = "$(basename "$d")" ]; then
    echo "REFUSE $d: hosts mounted root $src" >&2
    return 0
  fi
  return 1
}

lsblk_has() { # COLUMN VALUE DISK -> 0 if any row of DISK (disk or partition) has COLUMN == VALUE
  grep -qxF -- "$2" <<<"$(lsblk -no "$1" "$3" 2>/dev/null | sed 's/[[:space:]]*$//')"
}

for d in $(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}'); do
  if is_refused "$d"; then continue; fi
  serial=$(udevadm info --query=property --name="$d" 2>/dev/null | awk -F= '/^ID_SERIAL_SHORT=/{print $2}')
  size=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)
  # One column per lsblk call: with "-no FSTYPE,LABEL,UUID" an empty LABEL collapses under `read`
  # and the UUID would be compared as the label.
  has_ntfs=0
  has_label=0
  has_uuid=0
  lsblk_has FSTYPE ntfs "$d" && has_ntfs=1
  [ -n "$prefer_label" ] && lsblk_has LABEL "$prefer_label" "$d" && has_label=1
  [ -n "$prefer_uuid" ] && lsblk_has UUID "$prefer_uuid" "$d" && has_uuid=1

  score=0
  w=""
  if [ "$serial" = "$prefer_serial" ]; then score=$((score+100)); w="${w}serial=$serial "; fi
  if [ "$has_uuid" = 1 ]; then score=$((score+50)); w="${w}uuid=$prefer_uuid "; fi
  if [ "$has_label" = 1 ]; then score=$((score+30)); w="${w}label=$prefer_label "; fi
  if [ "$has_ntfs" = 1 ] && [ "$size" -ge "$min_bytes" ] && [ "$size" -le "$max_bytes" ]; then
    score=$((score+20)); w="${w}ntfs+size=$size "
  fi
  if [ "$allow_blank" = 1 ] && [ "$serial" = "$prefer_serial" ] && [ "$has_ntfs" = 0 ] && is_blank "$d"; then
    blank["$d"]=1
    w="${w}blank(install) "
  fi
  if [ "$score" -gt 0 ]; then
    candidates+=("$score:$d")
    why["$d"]="$w"
  fi
done

if [ "${#candidates[@]}" -eq 0 ]; then
  echo "FATAL: no safe Windows disk candidate (fail closed)" >&2
  exit 90
fi

# pick highest score; fail if tie at top
mapfile -t sorted < <(printf '%s
' "${candidates[@]}" | sort -t: -k1 -nr)
top_score=${sorted[0]%%:*}
top=()
for c in "${sorted[@]}"; do
  s=${c%%:*}; d=${c#*:}
  [ "$s" = "$top_score" ] && top+=("$d")
done
if [ "${#top[@]}" -ne 1 ]; then
  echo "FATAL: ambiguous Windows disk candidates: ${top[*]} (fail closed)" >&2
  exit 92
fi

WD="${top[0]}"
# final refuse re-check
if is_refused "$WD"; then
  echo "FATAL: selected $WD failed final refuse check" >&2
  exit 91
fi
# must still look like Windows (or, for an install, be the blank disk with the exact serial)
if [ -z "${blank[$WD]:-}" ]; then
  grep -q ntfs <<<"$(lsblk -no FSTYPE "$WD")" || { echo "FATAL: $WD has no NTFS" >&2; exit 93; }
fi

echo "RESOLVED Windows disk=$WD score=$top_score (${why[$WD]})" >&2
printf '%s\n' "$WD"
