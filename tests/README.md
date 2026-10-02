# tests/

Test harness for `qemu-ad-pve.sh`. Docs and test scripts only; nothing here is used by the installer.

> **WARNING: never run `tier2.sh` on a production host.** It installs a QEMU build, diverts `/usr/bin/kvm`, creates and
> destroys VMs 9001-9003 and performs a real `--purge`. A bug in the code under test can leave `/usr/bin/kvm` missing,
> which stops every VM on that node. Run it only on a disposable (ideally nested, snapshotted) Proxmox VE node.
> The same applies to the `tier15-*` scripts, which run real `dpkg`/`dpkg-divert`: only inside a throwaway root.

| File | What it is |
|---|---|
| `tier1.sh` | Tier 1: stub-based tests (fake `dpkg-divert`, recording `rm`, fake binaries). No root, no dpkg, no PVE. |
| `tier15-real-dpkg.sh` | Tier 1.5: real `dpkg` + `dpkg-divert` against dummy `pve-qemu-kvm` debs (install, upgrade, uninstall, failure injection, purge guard). |
| `tier15-lock.sh` | Tier 1.5: uninstall while a process holds the dpkg locks (fcntl locks, as dpkg takes them). |
| `tier15-window.sh` | Tier 1.5: measures whether `/usr/bin/kvm` is briefly missing during install/uninstall. |
| `tier2.sh` | Tier 2: the full runner (cases P0-P8) for a disposable PVE node: real build, real guests. The **only** tier-2 runner; it supersedes the earlier pre-PR #3 draft (the P3b showcmd-parity case, argv[0] and strict showcmd checks, `INSTALL_RC` capture and a full-SHA pin are only in this version). |
| `HARNESS-SPEC.md` | The test plan: prerequisites, safety gate, per-case steps and pass criteria. Written against PR #1 and since lightly updated; see the notes at its top. |
| `w10-code43-check.ps1` | Read-only PowerShell check run *inside a Windows 10 guest*: reports NVIDIA display-adapter health (Code 43) as one JSON document. |
| `w10-code43-run.sh` | Runs the check on a guest over SSH from a Linux machine and maps the JSON result to an exit code. |

## Tier 1 (stubs)

```bash
bash tests/tier1.sh qemu-ad-pve.sh      # from the repo root; takes seconds
```

Passes when the last line is `TIER1 RESULT: pass=N fail=0 ...` and the exit code is 0. It works in a `mktemp` dir and never
touches the real `/usr/bin/kvm`, dpkg, or `rm`. Run it on the exact commit you intend to test; `tier2.sh` runs it first.

## Tier 1.5 (real dpkg, private rootfs)

`tier15-*.sh` need **root** and a **disposable root filesystem**, e.g. a container, a throwaway chroot copy, or a
mount-namespace sandbox with writable overlays on `/usr /var /etc /opt` that is discarded on exit (`unshare`/`bwrap`
with overlay mounts; unprivileged `unshare -Urm` is not enough on every kernel). What they do: build two dummy
`pve-qemu-kvm` debs (v1.0, v2.0, each shipping `/usr/bin/kvm -> qemu-system-x86_64`) into a temp dir, `dpkg -i` them, then
source `qemu-ad-pve.sh` (minus its final `main` call) and exercise `install_wrapper` / `uninstall` against the real
`dpkg-divert`.

Safety checks built in: the scripts exit 2 unless `QAD_T15_SANDBOX=1` is set (your confirmation that you are in a throwaway
root), unless run as root, and if `qm` exists (looks like a PVE node). Env: `QAD_SCRIPT` (default `../qemu-ad-pve.sh`).

```bash
# inside the disposable root, as root:
QAD_T15_SANDBOX=1 bash tests/tier15-real-dpkg.sh
```

These scripts print `PASS`/`FAIL`/`INFO` lines (or timing counts for `tier15-window.sh`) for a human to read; some results are
informational by design (e.g. a few-ms missing-kvm window is a known low-severity finding).

## Tier 2 (disposable Proxmox VE node)

Runs **on** the test node, as root. Prerequisites: PVE with `/dev/kvm` (nested virtualization if the node is a VM), no cluster
membership, outbound HTTPS (download.qemu.org, github.com, apt), and an Alpine "virt" ISO in `local` storage
(default `local:iso/alpine-virt.iso`). Take a cold snapshot of the node before and roll back after (see the header of `tier2.sh`).

**Safety gate** (`gate`, run at the start of every case; any failure aborts with exit 99):

- `TEST_HOSTNAME` is **required** (no default) and must equal the node's `hostname`; otherwise the script refuses to start.
  `pvetest` is just an example name.
- `qm` must exist, `/dev/kvm` must exist, and `pvecm status` must fail (node is not in a cluster).
- It refuses to run if any protected VMID exists: `110 115 200 245` are built in; add more with `PROTECTED_VMIDS="300 301"`.
  (The built-in list is a lab-specific default; edit it for your site.)
- It only ever creates/destroys VMIDs **9001-9003**.
- It never reboots or shuts down the node (it only starts/stops its own test guests) and never touches an outer host.

```bash
TEST_HOSTNAME=pvetest REF=<full 40-hex commit sha> bash tests/tier2.sh all   # setup, p0 p3 p3b p4 p6 p8 p1 p2 p7 p5, teardown, table
TEST_HOSTNAME=pvetest bash tests/tier2.sh gate                               # just check the gate
TEST_HOSTNAME=pvetest bash tests/tier2.sh p3                                 # a single case
```

Running with no environment set must refuse immediately (`TEST_HOSTNAME: set TEST_HOSTNAME to the throwaway node hostname`).

Env knobs: `TEST_HOSTNAME` (required), `REF` (default: the pinned full SHA in the script; setup verifies `HEAD == REF` for a
40-char SHA), `REPO` (default `https://github.com/branpurn/qemu-ad-pve`), `ISO`, `BRIDGE` (default `vmbr0`), `OUT` (default
`/root/qad-t2`), `PROTECTED_VMIDS`, `SKIP_T1` (skip the tier-1 run on the node), `P0_VERIFY_ONLY` (re-check an existing
install log instead of rebuilding; the build takes 15-30 min).

Results: `$OUT/results.tsv` (ID, PASS/FAIL/INFO/SKIP, evidence, notes), `$OUT/results.md` (from `table`), `$OUT/run.log`, and
per-case evidence files (`p3.*.argv`, `p4.strace.txt`, `p5.table.txt`, ...). `INFO` never counts as a pass. The `/usr/bin/kvm`
watcher log is `/root/kvm-watch.log` and must be empty. Case P5 ends with a real purge, but only of a dummy prefix; the
real build and divert are left installed (run `uninstall` / restore the snapshot to clean up).

## W10 Code 43 check

Diagnoses the NVIDIA "Code 43" error in a Windows 10 guest with GPU passthrough. The PowerShell script is read-only and prints
one JSON document with `result` = `ok` | `code43` | `error_other` | `no_nvidia_device`.

Directly in the guest: `powershell -NoProfile -ExecutionPolicy Bypass -File .\w10-code43-check.ps1 -Pretty`

From Linux over SSH:

```bash
bash tests/w10-code43-run.sh <host> <user> [--key PATH] [--port 22] [--ssh-direct]
```

Exit codes: ok 0, code43 43, error_other 2, no_nvidia_device 3; runner/transport failure 1, usage 64, missing tool 127.
Prerequisites: on the guest, OpenSSH Server running with key authentication (no passwords are accepted by the runner), and for the
default mode PowerShell 7 plus a `Subsystem powershell` line in `sshd_config`; `--ssh-direct` needs only Windows PowerShell 5.1.
On the machine running the script: `ssh`/`scp`, and `pwsh` (default mode) or `jq`. The check script is found next to
the runner; override with `W10_CHECK_PS1=/path/to/w10-code43-check.ps1`. `bash tests/w10-code43-run.sh --help` has the
full setup steps.
