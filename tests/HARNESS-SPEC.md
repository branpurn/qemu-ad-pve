# qemu-ad-pve test-harness spec

Target: `branpurn/qemu-ad-pve`. Originally written against PR #1 (branch `fix/wrapper-robustness`, commit `2b6a4e6`); the case list and runner (`tests/tier2.sh`) have since been exercised against later commits. The sections below keep the original PR #1 numbers as history; the **current** way to run things is in `tests/README.md`.

> **Update notes (stale parts corrected):**
> - **Pin full SHAs.** Always test an exact, full 40-hex commit (`REF=<sha>`). `tests/tier2.sh` verifies `git rev-parse HEAD == REF` after checkout. Short SHAs in the history below (`2b6a4e6`, `2af5813`) are for reference only.
> - **dpkg locks are fcntl (POSIX) locks, not flock(1) locks.** dpkg takes fcntl locks on `/var/lib/dpkg/lock-frontend`, not `flock(1)` locks, so a `flock(1)` holder does not model dpkg faithfully. To hold the lock realistically use a small `python3` holder with `fcntl.lockf(f, fcntl.LOCK_EX)` (see `tests/tier15-lock.sh`). Where P2 below says `flock ...`, read it as that fcntl holder. Stock `dpkg-divert` does not take the dpkg lock at all, so uninstall may legitimately succeed while the lock is held.
> - **The missing-kvm watcher should use inotify where available** (`inotifywait -m -e delete -e moved_from -e create -e moved_to <dir>`; a rename-replace of `/usr/bin/kvm` is then visible as an event rather than missed between polls). The 50 ms busy-poll loop in S4 is only a fallback: it can miss a window shorter than the poll interval. `tests/tier1.sh` (C9r) already uses inotify with a poll fallback. Known low-severity finding from tier 1.5: `/usr/bin/kvm` can be absent for a few ms between `dpkg-divert --rename` and the final `mv`.
> - **The runner is `tests/tier2.sh`**; tier 1 is `tests/tier1.sh`; tier 1.5 are `tests/tier15-*.sh`.

## 0. BLUF

- Two tiers. **Tier 1** runs stubs on any Linux box, needs no root, no dpkg and no PVE, and takes about a second. It lives at `tests/tier1.sh`. **Tier 2** runs on a throwaway nested PVE and covers what stubs cannot: the real `dpkg-divert`, a real package upgrade, a real QEMU build, and real guest boots.
- Tier 1 results so far (stub dry run only):
  - Original `main`: 29 pass, 23 fail. This confirms the harness detects the original bugs.
  - PR commit `2b6a4e6`: 47 pass, **4 fail**. The `--purge` guard can be bypassed with `PREFIX=/opt/../usr`, `/opt/qemu-ad/../..`, `/usr/local/bin` and `/usr/local/../../etc`.
  - A follow-up commit `2af5813` exists locally and is **not pushed**. It closes the purge bypass, validates `--purge` before any uninstall action, and rolls the divert back if the final `mv` of the wrapper fails. It scores 53 pass, 0 fail. Pushing it to the PR branch needs the maintainer's approval, because only `2b6a4e6`. See Open questions.
- Tier 2 must run on a throwaway nested PVE with a snapshot taken before and a rollback after. It must never run on a host that carries VMs 110, 115, 200 or 245.

## 1. Scope and non-goals

In scope: the seven behaviors under test (below), plus a smoke test that a listed and a non-listed guest both boot.
Out of scope: live backup and live migration of side-binary guests (documented as unsupported), the device-identity patch's effectiveness, performance, and the findings held for the follow-up PR (tarball pinning, partial downloads, version-skew warning, `del-vm` atomicity).

## 2. Prerequisites (tier 2)

- **Platform:** a nested PVE VM (preferred) or a dedicated spare node. It must match the production major version. Record `pveversion -v` and make sure it shows `pve-qemu-kvm` 10.x and a current `qemu-server`. If production is on a different version, say so in the results.
- **Nested virtualization** on the outer host: `cat /sys/module/kvm_intel/parameters/nested` (or `kvm_amd`) must print `Y` or `1`. The outer VM uses CPU type `host`. Inside it, `egrep -c '(vmx|svm)' /proc/cpuinfo` must be greater than 0 and `/dev/kvm` must exist.
- **Size:** 8 vCPU, 16 GB RAM, 60 GB disk (the source tree and build take about 10 GB). Add 30 GB if the upgrade test caches debs.
- **Network:** outbound HTTPS for `download.qemu.org`, `github.com` and the Proxmox repos. Use the no-subscription repo on the test node. This matters because `apt-get update` returns 100 on the enterprise repo without a subscription, and install runs under `set -e`. That is a known issue held for the follow-up PR.
- **Isolation:** the node has no cluster membership, no shared storage, and no network path to production guests. Use VMIDs 9001-9003 for test guests, never any production VMID.
- **Build time:** the QEMU 10.2.2 build is about 15-30 minutes on 8 vCPU. Do it once in step P0 and reuse it. Cases P1-P7 need `SIDE_BIN` to exist, so they do not rebuild.
- **Tools on the node:** `git`, `socat`, `strace` (optional), `python3`, `inotify-tools` (optional, for the inotify watcher), `sha256sum`, and a tiny bootable image for the smoke test, such as the Alpine "virt" ISO uploaded to `local` storage.
- **Environment variables used below:**
  - `ADP=/root/qemu-ad-pve/qemu-ad-pve.sh`
  - Fetch with `git clone https://github.com/branpurn/qemu-ad-pve /root/qemu-ad-pve && git -C /root/qemu-ad-pve checkout <full-40-hex-sha>`
  - Record `sha256sum $ADP` in the results.

## 3. Setup, safety gate and teardown

### 3.1 Setup (S1-S4)

- **S1. Snapshot (run by the person with outer-host access).**
  - Stop any inner guests first.
  - If the test node is a PVE VM, run on the outer host: `qm shutdown <outer_vmid>`, then `qm snapshot <outer_vmid> pre-qemu-ad`.
  - Skip RAM state. A cold snapshot is the clean option.
  - Otherwise use the hypervisor's equivalent.
  - **Pass:** `qm listsnapshot <outer_vmid>` shows `pre-qemu-ad`.
- **S2. Safety gate.** Put this at the top of every tier-2 script. It must pass or the run stops.
  ```bash
  set -euo pipefail
  [[ $(hostname) == "$TEST_HOSTNAME" ]] || { echo ABORT: wrong host; exit 99; }
  if qm list | awk 'NR>1{print $1}' | grep -Eqx '110|115|200|245'; then echo ABORT: production VMID present; exit 99; fi
  ! pvecm status >/dev/null 2>&1 || { echo ABORT: node is in a cluster; exit 99; }
  ```
- **S3. Baseline capture.**
  - Run `dpkg-divert --list /usr/bin/kvm`, `readlink -f /usr/bin/kvm`, `sha256sum $(readlink -f /usr/bin/kvm)`, `pveversion -v > /root/pveversion.before`, and `dpkg -S /usr/bin/kvm`.
  - Run `qm create 9001 ...` as in 3.3 and capture the output of `qm showcmd 9001 --pretty > /root/showcmd.9001.before`.
- **S4. Continuous watcher.** Run this in a second shell for the whole session. It proves `/usr/bin/kvm` is never missing. (Preferred: `inotifywait -m -e delete -e moved_from /usr/bin --format '%e %f' | grep --line-buffered ' kvm$' >> /root/kvm-watch.log &`. The poll loop below is the fallback that `tests/tier2.sh` uses.)
  ```bash
  while :; do [[ -x /usr/bin/kvm ]] || echo "MISSING $(date -Is)" >> /root/kvm-watch.log; sleep 0.05; done &
  echo $! > /root/kvm-watch.pid
  ```
  Overall pass criterion for cases P1, P2 and P7: `/root/kvm-watch.log` is empty.

### 3.2 Teardown (every case, and again at the end)

```bash
for v in 9001 9002 9003; do qm stop $v --skiboot 2>/dev/null || true; qm destroy $v --purge 2>/dev/null || true; done
kill "$(cat /root/kvm-watch.pid)" 2>/dev/null || true
$ADP uninstall --purge || true     # only after the purge-guard cases are done
```

After teardown, the outer host rolls back: stop the nested VM, run `qm rollback <outer_vmid> pre-qemu-ad`, and start it. Roll back after each full run so the next run starts clean.

### 3.3 Test guests

Create these once, with a tiny ISO and no data disks:

```bash
qm create 9001 --name qad-listed   --memory 512 --cores 1 --machine pc-q35-10.1 --cpu host --ostype l26 --serial0 socket --vga serial0 --cdrom local:iso/alpine-virt.iso --net0 virtio,bridge=vmbr0 --onboot 0
qm create 9002 --name qad-unlisted --memory 512 --cores 1 --machine pc-q35-10.1 --cpu host --ostype l26 --serial0 socket --vga serial0 --cdrom local:iso/alpine-virt.iso --net0 virtio,bridge=vmbr0 --onboot 0
qm create 9003 --name qad-unversioned --memory 512 --cores 1 --machine q35 --cpu host --ostype l26 --serial0 socket --vga serial0 --cdrom local:iso/alpine-virt.iso --net0 virtio,bridge=vmbr0 --onboot 0
```

9001 is a listed guest, 9002 is a non-listed control, and 9003 is a listed guest on an unversioned machine type. qemu-server may expand `q35` to a `pc-q35-X.Y+pveN` string, which the wrapper must strip.

## 4. Tier 1: stub tier (no PVE, any Linux box, no root)

`bash tests/tier1.sh /path/to/qemu-ad-pve.sh`

- It copies the script into a temp dir, stubs `dpkg-divert` (with real semantics: `--rename` refuses to overwrite), and substitutes recording `real` and `side` binaries.
- It never touches the real `/usr/bin/kvm`, dpkg or `rm`. The purge tests replace `rm` with a recorder.
- **Pass criterion:** exit 0, with the last line `pass=N fail=0`.
- Run it against the exact commit that tier 2 will test. Tier 2 must not start if tier 1 fails.

| Case | Tier-1 IDs | What it proves |
|---|---|---|
| 1 install atomicity | C1a-C1h | Injected write failure, `/dev/full` (ENOSPC), and a wrapper failing `bash -n` all leave `kvm` intact and create no divert. Reinstall is idempotent. |
| 2 uninstall order | C2a-C2d | A failed divert removal restores the wrapper. A clean uninstall restores the vendor file. |
| 3 `-id` | C3a-C3f | Listed guests go to side with the `-id` pair dropped. Unlisted guests go to vendor with `-id` intact. VMID 2000 does not match 200. The fake VMID `-1` probe goes to vendor. |
| 4 pass-through | C4a-C4e | Non-listed argv is byte-identical (spaces, embedded newline, empty arg, `+pve` in a path). `--version` goes to vendor. A missing or CRLF list falls back to vendor. A missing side binary fails loudly for listed guests only. |
| 5 purge guard | C5 | Rejects `/`, `/usr`, `/etc`, `/opt`, `/usr/local`, `/srv`, `/home/x`, relative paths, and traversal. Allows `/opt/qemu-ad`. A refused purge changes nothing. |
| 6 `+pveN` | C6a-C6f | Stripped only after `-machine` and `-M`. Untouched in names, smbios strings and paths. |
| 7 upgrade | C7 | Only the simulated half: the wrapper is untouched when the vendor file changes. The real upgrade is P7. |

Known limits of tier 1:
- Stubs model `dpkg-divert` but not the real dpkg database or lock.
- Tier 1 cannot test a real QEMU boot.
- C3f and C6f are INFO only. They document an arg whose value looks like an option. Not a bug in practice.

## 5. Tier 2: nested PVE cases

Common precondition for every case: S1-S4 done, the node is in the post-P0 state (installed, `SIDE_BIN` built), and `/root/kvm-watch.log` is empty at the start of the case.

### P0. Clean install (also supplies the build)

- **Preconditions:** a fresh snapshot state. `dpkg-divert --list /usr/bin/kvm` prints nothing.
- **Steps:**
  1. `time $ADP install 2>&1 | tee /root/install.log`
  2. `$ADP add-vm 9001 && $ADP add-vm 9003`
  3. `$ADP status`
- **Expected:**
  - `/opt/qemu-ad/bin/qemu-system-x86_64 --version` prints QEMU 10.2.2.
  - `/usr/bin/kvm` is the generated wrapper.
  - `/usr/bin/kvm.pve` is the vendor binary or symlink.
  - `/etc/qemu-ad/vms` contains 9001 and 9003.
- **Pass:** all four hold and the install exits 0. It must also have pulled `libaio-dev` and `liburing-dev`, and `/opt/qemu-ad/bin/qemu-system-x86_64 -drive help` or `ldd` shows `liburing` and `libaio`.
- **Teardown:** none. Later cases reuse this state.

### P1. Install atomicity (case 1)

- **Preconditions:** P0 done. Run `$ADP uninstall` first so `kvm` is the vendor file again and `SIDE_BIN` still exists. Take note of `sha256sum /usr/bin/kvm`.
- **Steps (inject an ENOSPC-like failure on the staged file):**
  1. `ln -s /dev/full /usr/bin/kvm.qemu-ad-new`
  2. `$ADP install; echo rc=$?`
  3. `rm -f /usr/bin/kvm.qemu-ad-new`
  4. Second injection: `mkdir /usr/bin/kvm.qemu-ad-new`, run `$ADP install; echo rc=$?`, then `rmdir /usr/bin/kvm.qemu-ad-new`.
  5. Third injection, optional, fills the filesystem: use a loop-mounted small filesystem bound over `/usr/bin` only if the node can be rolled back. Otherwise skip.
  6. Recovery check: run `$ADP install` with no injection.
- **Expected:** after steps 2 and 4, rc is not 0, `/usr/bin/kvm` is byte-identical to before (same sha256), `dpkg-divert --list /usr/bin/kvm` prints nothing, and `qm start 9002` still works. After step 6, the install succeeds and the divert exists.
- **Pass:** sha256 unchanged, no divert, the watcher log is empty, and a vendor guest starts.
- **Teardown:** remove any `kvm.qemu-ad-new` leftovers. The state after step 6 is the standard installed state.

### P2. Uninstall order and dpkg lock failure (case 2)

- **Preconditions:** installed state. Save `sha256sum /usr/bin/kvm` (the wrapper) as `W`.
- **Steps:**
  1. **Deterministic failure.** Put a shim on PATH. It makes `dpkg-divert --remove` fail with exit 2 and forwards everything else to the real binary:
     ```bash
     mkdir -p /root/shim && cat > /root/shim/dpkg-divert <<'S'
     #!/bin/bash
     case "$*" in *--remove*) echo "dpkg: error: dpkg frontend lock held (injected)" >&2; exit 2;; esac
     exec /usr/sbin/dpkg-divert "$@"
     S
     chmod +x /root/shim/dpkg-divert
     PATH=/root/shim:$PATH $ADP uninstall; echo rc=$?
     ```
  2. Verify: `sha256sum /usr/bin/kvm` equals `W`, `dpkg-divert --list /usr/bin/kvm` still lists the divert, `/usr/bin/kvm.pve` exists, and `ls /usr/bin/kvm.qemu-ad-removed` fails.
  3. **Real lock.** Hold the dpkg lock and run uninstall:
     ```bash
     python3 -c 'import fcntl,time; f=open("/var/lib/dpkg/lock-frontend","w"); fcntl.lockf(f, fcntl.LOCK_EX); time.sleep(90)' &   # fcntl lock, like dpkg (flock(1) would not be seen)
     $ADP uninstall; echo rc=$?
     ```
     Whether a stock `dpkg-divert` honors that lock varies by dpkg version. Record what happened. Either outcome (a clean uninstall or a failure with the wrapper restored) is acceptable. `kvm` must exist at every moment either way.
  4. Release the lock (`wait`), then run the clean uninstall: `$ADP uninstall; echo rc=$?`
  5. `qm start 9002` works.
- **Expected:**
  - After step 1: rc is 1, the wrapper is restored, and nothing is changed.
  - After step 4: rc is 0, `/usr/bin/kvm` is the original vendor file, `dpkg-divert --list /usr/bin/kvm` prints nothing, and `kvm.pve` is gone.
- **Pass:** the watcher log is empty throughout, the hash checks hold, and the final state has `kvm` as vendor.
- **Teardown:** reinstall with `$ADP install` and re-add VM 9001 and 9003 (`add-vm`) to restore the installed state.

### P3. `-id` handling for listed VMs (case 3)

- **Preconditions:** installed state. 9001 listed, 9002 not listed.
- **Step 0 (confirm the premise).** On this node, `qm showcmd 9001 | tr ' ' '\n' | grep -x -- -id` must print `-id`. If it does not, record that qemu-server on this version does not emit `-id`. The fix is then harmless but the premise of finding 1 is version-specific.
- **Steps:**
  1. `qm start 9001; sleep 5; qm status 9001`
  2. `pid=$(cat /var/run/qemu-server/9001.pid); readlink /proc/$pid/exe; tr '\0' ' ' < /proc/$pid/cmdline; echo`
  3. `tail -3 /var/log/qemu-ad-wrapper.log`
  4. `qm start 9002; sleep 5; pid2=$(cat /var/run/qemu-server/9002.pid); readlink /proc/$pid2/exe; tr '\0' ' ' < /proc/$pid2/cmdline; echo`
- **Expected:**
  - 9001: the exe is `/opt/qemu-ad/bin/qemu-system-x86_64`. The cmdline contains no `-id` token. The wrapper log has a `vmid=9001` line. `qm status` is running.
  - 9002: the exe is the vendor binary (resolves to `/usr/bin/qemu-system-x86_64`). The cmdline **does** contain `-id 9002`. The wrapper log has no 9002 line.
- **Pass:** every bullet holds.
- **Teardown:** `qm stop 9001; qm stop 9002`

### P4. Non-listed pass-through (case 4)

- **Preconditions:** installed state. 9002 not listed.
- **Steps:**
  1. Capture the vendor-view command line: `qm showcmd 9002 --pretty | sed 's/ \\$//' > /root/cmd.9002.vendor.txt`
  2. `qm start 9002; sleep 5`
  3. Capture the live argv: `tr '\0' '\n' < /proc/$(cat /var/run/qemu-server/9002.pid)/cmdline > /root/cmd.9002.live.txt`
  4. Compare: `qm showcmd 9002 | tr ' ' '\n'` against the live argv. Allow for the shell quoting that `showcmd` adds. A stricter check is to run `strace -f -e execve -s 2000 -o /root/exec.9002.txt qm start 9002` and diff the execve argv of `/usr/bin/kvm` against that of the vendor binary.
  5. Extra checks on odd args: add to 9002 `--args '-smbios type=1,product=x+pve1'` and a VM name with a space-free `+pve5` (for example `qad+pve5`). Start it and confirm those strings reach the live argv unchanged.
  6. `qm shutdown 9002 --timeout 20 || qm stop 9002`
- **Expected:** the live argv equals the vendor-view argv. `+pveN` appears unmodified wherever qemu-server put it. The exe is the vendor binary.
- **Pass:** zero differences after normalizing quoting, and the strace execve argv for `/usr/bin/kvm` (the wrapper) equals the argv the vendor binary receives. A 9002 start must work with the list file removed and with an empty list file, as well as with the file present.
- **Teardown:** `qm stop 9002; qm set 9002 --delete args; qm set 9002 --name qad-unlisted`

### P5. `--purge` guard (case 5)

- **Preconditions:** installed state. Create the sentinel dirs `mkdir -p /opt/qad-sentinel /usr/local/qad-sentinel`.
- **Steps:** run each of these and record rc and whether anything was removed. **Never use a real system path as `PREFIX` for an unguarded script.** Run this case only on a commit that has passed tier-1 C5, or shadow `rm` with a recorder:
  ```bash
  mkdir -p /root/shim2 && printf '#!/bin/bash\necho "RM $*" >> /root/rm.log\n' > /root/shim2/rm && chmod +x /root/shim2/rm
  for p in / /usr /etc /opt /opt/ /usr/local /srv /home/x relative/opt "" /opt/../usr /opt/qemu-ad/../.. /usr/local/bin /usr/local/../../etc; do
    : > /root/rm.log
    PATH=/root/shim2:$PATH PREFIX="$p" $ADP uninstall --purge; echo "PREFIX='$p' rc=$? rm=$(wc -l < /root/rm.log)"
  done
  ```
  Then the allow cases, also with `rm` shadowed: `/opt/qemu-ad`, `/usr/local/qemu-ad`, `/srv/qad`. Finally one real purge: `PREFIX=/opt/qemu-ad $ADP uninstall --purge`.
- **Expected:** every reject case has rc not 0 and 0 `rm` lines. Every allow case has rc 0 and one `rm -rf` line naming exactly that `PREFIX`. After the real purge, `/opt/qemu-ad` is gone and `/opt/qad-sentinel` is still there.
- **Pass:** all of the above, including a refused purge leaving the divert and wrapper in place.
- **Teardown:** `rm -rf /opt/qad-sentinel /usr/local/qad-sentinel /root/shim2`. The real purge removed `SIDE_BIN`, so the next case needs a reinstall (`$ADP install` rebuilds, so restore the snapshot or accept the rebuild time).

### P6. `+pveN` stripping only on `-machine` and `-M` (case 6)

- **Preconditions:** installed state, 9003 listed.
- **Steps:**
  1. `qm showcmd 9003 | tr ' ' '\n' | grep -n 'pve[0-9]'` to see whether qemu-server emitted a `+pveN` machine type.
  2. `qm start 9003; sleep 5; tr '\0' '\n' < /proc/$(cat /var/run/qemu-server/9003.pid)/cmdline | grep -n 'pve[0-9]' || echo none`
  3. Put a `+pve` string where it must survive and start 9001: `qm set 9001 --args '-smbios type=1,product=prod+pve7'`, `qm set 9001 --name qad+pve5`. Start it and read the live argv.
- **Expected:**
  - 9003's live argv has no `+pveN` in the machine type (the guest boots, so QEMU accepted it).
  - 9001's live argv still contains `product=prod+pve7` and the name `qad+pve5`.
- **Pass:** both bullets hold and both guests are running.
- **Teardown:** `qm stop 9001 9003; qm set 9001 --delete args; qm set 9001 --name qad-listed`

### P7. `pve-qemu-kvm` upgrade and reinstall (case 7)

- **Preconditions:** installed state. Record `W=$(sha256sum /usr/bin/kvm)`, the divert listing, and `dpkg -l pve-qemu-kvm`.
- **Steps:**
  1. **Reinstall:** `apt-get install --reinstall -y pve-qemu-kvm`
  2. Check: `sha256sum /usr/bin/kvm` (equals `W`), `dpkg-divert --list /usr/bin/kvm`, `ls -l /usr/bin/kvm.pve`, `readlink -f /usr/bin/kvm.pve`, `dpkg -S /usr/bin/kvm`, and `grep -c 'Generated by qemu-ad-pve' /usr/bin/kvm`.
  3. **Real version change** (only if two versions are available from the repo): `apt-cache policy pve-qemu-kvm`, then `apt-get install -y pve-qemu-kvm=<older>` followed by `apt-get install -y pve-qemu-kvm` (newest). Repeat the checks in step 2 after each.
  4. Smoke after each package change: `qm start 9002` (unlisted, must start) and `qm start 9001` (listed). Record whether the listed guest still starts.
  5. `dpkg --verify pve-qemu-kvm` and `dpkg --audit`.
- **Expected:**
  - `/usr/bin/kvm` is still the wrapper with an identical hash.
  - The divert is still listed.
  - `/usr/bin/kvm.pve` is the new vendor file or symlink (`readlink -f` resolves to the packaged `qemu-system-x86_64`).
  - `dpkg --audit` is clean.
  - Unlisted guests start.
- **Pass:** all expected items hold. A listed guest failing after a **version change** is an INFO finding, not a failure of the PR. It is the version-skew risk (the side binary stays at 10.2.2 while qemu-server follows the vendor version), tracked as finding 9.
- **Teardown:** `qm stop 9001 9002`. Leave the newest package version installed.

### P8. Smoke: listed guest boots, non-listed guest boots

- **Preconditions:** installed state, 9001 listed (machine `pc-q35-10.1`), 9002 not listed, the Alpine ISO attached.
- **Steps:**
  1. `qm start 9001 && qm start 9002`
  2. Wait 60 seconds. For each guest: `qm status <id>`, `echo '{"execute":"qmp_capabilities"}{"execute":"query-status"}' | socat - UNIX-CONNECT:/var/run/qemu-server/<id>.qmp`, and read the serial console log: `timeout 20 socat - UNIX-CONNECT:/var/run/qemu-server/<id>.serial0`. Look for the Alpine/SeaBIOS boot banner.
  3. `qm shutdown 9001 --timeout 30; qm shutdown 9002 --timeout 30`, or `qm stop` if the shutdown times out (Alpine live ISO may ignore ACPI).
  4. Start both again to confirm restart works.
- **Expected:** both report `running`, query-status returns `{"status":"running"}`, and the serial log shows firmware or boot output. 9001's exe is the side binary and 9002's exe is the vendor binary.
- **Pass:** both guests boot twice, stop cleanly, and the exe check holds.
- **Teardown:** `qm stop 9001 9002`

## 6. Ordered run plan

1. Tier 1 against the PR commit. Stop if it fails.
2. S1 snapshot, S2 gate, S3 baseline, S4 watcher.
3. P0 clean install and build.
4. P3, P4, P6, P8 (non-destructive, repeatable).
5. P1, P2 (they tear down and reinstall the divert).
6. P7 upgrade and reinstall.
7. P5 purge guard last (the real purge destroys the build).
8. Collect `/root/kvm-watch.log`, `/root/install.log`, `/var/log/qemu-ad-wrapper.log` and the outputs above.
9. Final teardown, then outer-host rollback to `pre-qemu-ad`.

Estimated time: about 1 to 1.5 hours including the build, plus a rebuild if P5's real purge runs before a later re-run.

## 7. Risks and safety

- **Blast radius:** on the test node, a bug can leave `/usr/bin/kvm` missing, which stops every VM on that node. That is the reason for the throwaway node. The snapshot restores it.
- **Production isolation:** no cluster join, no shared storage, no route to production, test VMIDs 9001-9003 only. The S2 gate aborts if a production VMID shows up in `qm list`, if the hostname is wrong, or if the node is clustered. Nothing here is run on the hosts that carry 110, 115, 200 or 245.
- **Dangerous commands:** P5 is the only case that can delete a system path if a guard is broken. Shadow `rm` with a recorder (as shown) and run it only after tier-1 C5 passes.
- **Abort criteria:** stop the run and roll back if any of these happen:
  - `/root/kvm-watch.log` shows MISSING in any case other than a deliberate injection.
  - `dpkg --audit` reports a broken package state.
  - The S2 gate fails.
  - Any command output mentions a production VMID or hostname.
  - A step would need credentials or secrets. None are required, and none belong in logs or commits.
- **Known limits that are not failures:** backup, snapshot-with-RAM and live migration of a side-binary guest fail by design. The side binary is vanilla QEMU 10.2.2.
- **Data hygiene:** test logs contain only VMIDs and timestamps. Do not paste the wrapper log if it ever contains production IDs.

## 8. Results table template

| ID | Case | Commit tested | Result (PASS / FAIL / INFO) | Evidence (file or command output) | Notes |
|---|---|---|---|---|---|
| T1 | Tier-1 stub run | | | `tier1.out` | pass=__ fail=__ |
| P0 | Clean install and build | | | `install.log` | build time __ min |
| P1 | Install atomicity | | | sha256 before/after, `kvm-watch.log` | |
| P2 | Uninstall and dpkg lock | | | rc values, divert listings | real-lock behavior: __ |
| P3 | `-id` handling | | | `/proc/<pid>/cmdline`, wrapper log | qm showcmd emits -id: Y/N |
| P4 | Non-listed pass-through | | | argv diff | |
| P5 | Purge guard | | | rc and rm count per PREFIX | |
| P6 | `+pveN` only on -machine/-M | | | live argv | |
| P7 | pve-qemu-kvm reinstall/upgrade | | | hash, divert, dpkg audit | versions from/to: __ |
| P8 | Smoke: listed and non-listed boot | | | status, QMP, serial | |

Header fields to fill in once per run: date, tester, PVE version (`pveversion -v`), outer-host platform, `sha256sum $ADP`, snapshot name, rollback done (Y/N).

## 9. Open questions for the maintainer

1. **Where does tier 2 run?** A nested PVE VM on which outer host, or a spare physical node? Who has outer-host access to take the snapshot and roll back?
2. **PVE version to match.** Which `pveversion` and `pve-qemu-kvm` version is production on? The `-id` behavior depends on qemu-server's version, and P3 step 0 checks it on the test node.
3. **Push the follow-up commit `2af5813` to the PR branch?** It closes the purge-guard bypass found by tier 1 and adds a rollback if the final wrapper `mv` fails. Only `2b6a4e6` was approved so far. Alternatively merge PR #1 as is and put it in the follow-up PR.
4. **Is the no-subscription repo acceptable on the test node?** The enterprise repo makes `apt-get update` fail and aborts install (finding 10, deferred).
5. **Should P7 test a real older-to-newer package change?** It needs two available `pve-qemu-kvm` versions.
6. **Should tier 1 live in the repo** (for example `tests/tier1.sh`) or stay outside it? That would be another PR.
