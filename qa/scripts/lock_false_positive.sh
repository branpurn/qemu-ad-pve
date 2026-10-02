#!/bin/bash
# Usage: lock_false_positive.sh /path/to/qemu-ad-pve.sh   (checks dpkg_lock_held for a cross-filesystem inode collision)
SCRIPT=${1:?usage: $0 /path/to/qemu-ad-pve.sh}
TREE=$(dirname "$(readlink -f "$SCRIPT")")
sed '$d' "$SCRIPT" > /tmp/l.sh
# lock files on tmpfs until one has an inode number that also exists on the workspace fs
for i in $(seq 1 400); do : > /tmp/lk$i; done
python3 - <<'PY' &
import fcntl,os,time
fs=[]
for i in range(1,401):
    f=open('/tmp/lk%d'%i,'w'); fcntl.lockf(f,fcntl.LOCK_EX); fs.append(f)
open('/tmp/rdy','w').write('1'); time.sleep(8)
PY
sleep 1.5
for i in $(seq 1 400); do n=$(stat -c %i /tmp/lk$i); d=$(find "$TREE" -xdev -inum $n 2>/dev/null | head -1); [[ -n $d ]] && { echo "tmpfs locked inode $n collides with different-fs file $d"; bash -c "source /tmp/l.sh; dpkg_lock_held $d && echo 'dpkg_lock_held says HELD for an UNLOCKED file on a different fs (false positive)' || echo no-fp"; break; }; done
wait
