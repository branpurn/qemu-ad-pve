#!/bin/bash
# Resolve the Windows L2 disk at runtime. Prefer stable identity over device name.
# Priority: ID_SERIAL_SHORT=drive-scsi1 -> NTFS LABEL=Windows / UUID -> size~80G+ntfs.
# Refuse: any mountpoint under the disk, any ext4 partition, ambiguous multi-match.
set -euo pipefail

prefer_serial="${WIN_DISK_SERIAL:-drive-scsi1}"
prefer_label="${WIN_DISK_LABEL:-Windows}"
prefer_uuid="${WIN_DISK_UUID:-762491EA2491AE1D}"
min_bytes=$((70*1024*1024*1024))
max_bytes=$((90*1024*1024*1024))

candidates=()
declare -A why

is_refused() {
  local d="$1"
  # mounted anywhere on this disk?
  if lsblk -no MOUNTPOINT "$d" 2>/dev/null | grep -q .; then
    echo "REFUSE $d: has mounted partition(s)" >&2
    return 0
  fi
  # ext4 anywhere (L1 root signature)
  if lsblk -no FSTYPE "$d" 2>/dev/null | grep -qx ext4; then
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

for d in $(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}'); do
  if is_refused "$d"; then continue; fi
  serial=$(udevadm info --query=property --name="$d" 2>/dev/null | awk -F= '/^ID_SERIAL_SHORT=/{print $2}')
  size=$(blockdev --getsize64 "$d" 2>/dev/null || echo 0)
  has_ntfs=0
  has_label=0
  has_uuid=0
  while read -r fs lab uuid; do
    [ "$fs" = "ntfs" ] && has_ntfs=1
    [ "$lab" = "$prefer_label" ] && has_label=1
    [ "$uuid" = "$prefer_uuid" ] && has_uuid=1
  done < <(lsblk -no FSTYPE,LABEL,UUID "$d" 2>/dev/null)

  score=0
  w=""
  if [ "$serial" = "$prefer_serial" ]; then score=$((score+100)); w="${w}serial=$serial "; fi
  if [ "$has_uuid" = 1 ]; then score=$((score+50)); w="${w}uuid=$prefer_uuid "; fi
  if [ "$has_label" = 1 ]; then score=$((score+30)); w="${w}label=$prefer_label "; fi
  if [ "$has_ntfs" = 1 ] && [ "$size" -ge "$min_bytes" ] && [ "$size" -le "$max_bytes" ]; then
    score=$((score+20)); w="${w}ntfs+size=$size "
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
# must still look like Windows
lsblk -no FSTYPE "$WD" | grep -q ntfs || { echo "FATAL: $WD has no NTFS" >&2; exit 93; }

echo "RESOLVED Windows disk=$WD score=$top_score (${why[$WD]})" >&2
printf '%s\n' "$WD"
