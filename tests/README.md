# tests/

Test harness for `qemu-ad-pve.sh`. Docs and test scripts only; nothing here is used by the installer.
Nothing in here is specific to one site: node names, VMIDs, storage and bridge names are all parameters with neutral defaults.

> **WARNING: never run `tier2.sh` on a production host.** It installs a QEMU build, diverts `/usr/bin/kvm`, creates and
> destroys the three test VMs, reinstalls/downgrades `pve-qemu-kvm` via apt, edits `/etc/qemu-ad/`, deletes its own work
> dir and performs a real `--purge`. A bug in the code under test can leave `/usr/bin/kvm` missing, which stops every VM
> on that node. Run it only on a disposable (ideally nested, snapshotted) Proxmox VE node.
> The same applies to the `tier15-*` scripts, which run real `dpkg`/`dpkg-divert`: only inside a throwaway root.

| File | What it is |
|---|---|
| `tier1.sh` | Tier 1: stub-based tests (fake `dpkg-divert`, recording `rm`, fake binaries). No root, no dpkg, no PVE. |
| `tier15-real-dpkg.sh` | Tier 1.5: real `dpkg` + `dpkg-divert` against dummy `pve-qemu-kvm` debs (install, upgrade, uninstall, failure injection, purge guard). |
| `tier15-lock.sh` | Tier 1.5: uninstall while a process holds the dpkg locks (fcntl locks, as dpkg takes them); asserts the outcome is one of the two acceptable ones. |
| `tier15-window.sh` | Tier 1.5: polls whether `/usr/bin/kvm` is briefly missing during install/uninstall (INFO by default, see below). |
| `tier15-common.sh` | Sourced by the three `tier15-*.sh`: safety guard, dummy-deb builder, result counting. |
| `tier15-guard-test.sh` | Tests of that guard (unprivileged, touches nothing). |
| `tier2.sh` | Tier 2: the full runner (cases P0-P8) for a disposable PVE node: real build, real guests. The **only** tier-2 runner; it supersedes the earlier pre-PR #3 draft. |
| `tier2-gate-test.sh` | Tests of the tier-2 safety gate against stub `qm`/`hostname`/`pvecm` binaries (never touches a real node). |
| `NODE-SETUP.md` | How to set up a disposable nested PVE node for tier 2: requirements, nested virtualization, cold snapshot and rollback, repositories and ISO, and what the safety gate expects. |
| `HARNESS-SPEC.md` | The test plan: prerequisites, safety gate, per-case steps and pass criteria. Written against PR #1 and since updated; see the notes at its top. |
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
with overlay mounts). What they do: build dummy `pve-qemu-kvm` debs into a private temp dir (`tier15-real-dpkg.sh`: v1.0 and
v2.0; `tier15-lock.sh` and `tier15-window.sh`: v2.0 only; each ships `/usr/bin/kvm -> qemu-system-x86_64` like the real
package), `dpkg -i` them, then source `qemu-ad-pve.sh` (minus its final `main` call) and exercise `install_wrapper` /
`uninstall` against the real `dpkg-divert`.

Safety checks built in (`tier15-common.sh`, exit 2 with a `refusing:` message): `QAD_T15_SANDBOX=1` must be set (your
confirmation that you are in a throwaway root), `/etc/pve` must not exist, `qm` must not exist anywhere (PATH or
`/usr/sbin`, `/usr/bin`, ...), a real `pve-qemu-kvm` package must not be installed, and you must be root. This is a tripwire,
not a sandbox: you still have to provide the disposable root. Env: `QAD_SCRIPT` (default `../qemu-ad-pve.sh`).

```bash
# inside the disposable root, as root:
QAD_T15_SANDBOX=1 bash tests/tier15-real-dpkg.sh
```

Pass criteria: every script ends with `TIER15 RESULT: pass=N fail=M info=K` and **exits non-zero if any line is `FAIL`**.
`INFO` lines are informational by design (e.g. `dpkg -r` while diverted, or that `dpkg-divert` ignores the dpkg locks).
`tier15-window.sh` and `tier15-lock.sh` report a few-ms missing-`/usr/bin/kvm` window as `INFO` (a known low-severity finding);
set `STRICT_WINDOW=1` to make it a `FAIL`. An empty `PREFIX` is *not* a purge-reject case: it means the default `/opt/qemu-ad`.

### `T15_FS_ROOT` (test hook for the guard)

| | |
|---|---|
| What | A path prefix that `t15_guard` (in `tier15-common.sh`) puts in front of the **filesystem** probes it makes: `/usr/sbin/qm`, `/usr/bin/qm`, `/sbin/qm`, `/bin/qm`, `/usr/local/bin/qm`, `/usr/local/sbin/qm` and `/etc/pve`. With `T15_FS_ROOT=/x` the guard looks for `/x/usr/sbin/qm`, `/x/etc/pve`, and so on. |
| Default | Unset or empty, so the probes look at the real `/`. This is the only value to use for a real tier-1.5 run. |
| What it does **not** change | The other guard checks: `QAD_T15_SANDBOX=1`, `qm` on `PATH` (use `PATH` to control that), the installed `pve-qemu-kvm` package (looked up with `dpkg-query` on `PATH`), and `id -u` = 0. |
| Who uses it | Only `tier15-guard-test.sh`, which points it at a fake root so the guard's refusals can be tested without a PVE node and without root. `tier1.sh`, `tier2.sh` and the three `tier15-*.sh` scripts do not use it or set it. |

**Do not set it in a real run.** Pointing it at an empty directory makes the guard stop looking at the real `/usr/sbin/qm` and
`/etc/pve`, which disables the "this looks like a PVE node" tripwire.

Hermetic usage (what `tier15-guard-test.sh` does; runs unprivileged and touches only the temp dir). The guard is *called*, never
the tier-1.5 scripts:

```bash
fake=$(mktemp -d); mkdir -p "$fake/fs/usr/sbin" "$fake/fs/etc" "$fake/stub"
: > "$fake/fs/usr/sbin/qm"                       # pretend this root is a PVE node
env -i PATH="$fake/stub:/usr/bin:/bin" T15_FS_ROOT="$fake/fs" QAD_T15_SANDBOX=1 \
  bash -c 'source tests/tier15-common.sh; t15_guard; echo GUARD-PASSED'
# -> refusing: /usr/sbin/qm exists, this looks like a PVE node      (exit 2, no GUARD-PASSED)
rm -rf "$fake"
```

`bash tests/tier15-guard-test.sh` tests the guard itself (using `T15_FS_ROOT`, see above) and needs no privileges.

## Tier 2 (disposable Proxmox VE node)

Runs **on** the test node, as root. Prerequisites: PVE with `/dev/kvm` (nested virtualization if the node is a VM), no cluster
membership, outbound HTTPS (download.qemu.org, github.com, apt), and an Alpine "virt" ISO in the `ISO` storage (default
`local:iso/alpine-virt.iso`; `local` and `vmbr0` are the stock PVE names, override with `ISO` / `BRIDGE`). Take a cold
snapshot of the node before and roll back after (see the header of `tier2.sh`). **To build such a node, see [`NODE-SETUP.md`](NODE-SETUP.md)** (nested virtualization, `cpu=host`, cold snapshot and rollback, repositories, ISO, and how the gate treats the node).

**Required environment (the script refuses to start without it):**

| Variable | Meaning |
|---|---|
| `TEST_HOSTNAME` | Must equal the node's `hostname`. No default. Unset/empty => exit 1 immediately. |
| `QAD_PROTECTED_VMIDS` | Space-separated VMIDs that must **not** exist on this node. No default; empty/unset => refuse (exit 99). Write the word `none` to state deliberately that there are none. |
| `REF` | For `setup`/`all`: the full 40-hex commit to test (verified against `HEAD` after checkout). No default, so you never test a stale commit by accident. |

**Safety gate** (`gate`, run at the start of every case and of `teardown`; any failure aborts with **exit 99**):

- `hostname` equals `TEST_HOSTNAME`; `qm` exists; `QAD_PROTECTED_VMIDS` is set and numeric (or `none`) and does not overlap the test range.
- `qm list` must succeed (it is captured first; if it fails, the gate fails closed) and be parseable.
- **Every VMID on the node must be inside the test range.** A protected VMID present => abort; *any other* VMID outside the
  test range present => abort too (auto-protected). So the node must carry nothing but (optionally) the three test VMs.
- The test range is `TEST_VMID_BASE`, +1, +2 (default base `900`, i.e. 900, 901, 902; must be >= 100). It is the **only** set of VMIDs
  the script ever creates, starts, stops or destroys. **Any existing VM with a test VMID is destroyed by `setup` without a prompt.**
- `/dev/kvm` must exist and `pvecm status` must fail (node is not in a cluster).
- It never reboots or shuts down the node (it only starts/stops its own test guests) and never touches an outer host.
- Knobs that end up in shell strings (`REPO ISO BRIDGE OUT WORK_DIR REF SIDE_VERSION`) must match `[A-Za-z0-9._:/@+=-]*`.

```bash
export TEST_HOSTNAME=<test-node> QAD_PROTECTED_VMIDS="<ids or none>"
REF=<full 40-hex commit sha> bash tests/tier2.sh all     # setup, p0 p3 p3b p4 p6 p8 p1 p2 p7 p5, teardown, table
bash tests/tier2.sh gate                                 # just check the gate
bash tests/tier2.sh p3                                   # a single case (after setup)
```

Running with no environment set must refuse immediately (`TEST_HOSTNAME: set TEST_HOSTNAME to the throwaway node hostname`, exit 1).
Exit codes: 1 missing `TEST_HOSTNAME`; 2 usage; 97 tier 1 failed; 98 setup could not fetch/verify `REF` (or no tier1.sh); 99 gate refused.

Other env: `REPO` (default `https://github.com/branpurn/qemu-ad-pve`), `ISO`, `BRIDGE`, `WORK_DIR` (default `$HOME/qad-work`; clone, watcher
log and scratch files live here), `OUT` (default `$WORK_DIR/t2-out`), `SIDE_VERSION` (default `10.2.2`, the version the side binary must report),
`SKIP_T1` (skip the tier-1 run on the node), `P0_VERIFY_ONLY` (re-check an existing install log instead of rebuilding; the build takes 15-30 min),
`KVM_DEV` (test hook, default `/dev/kvm`).

Results: `$OUT/results.tsv` (ID, PASS/FAIL/INFO/SKIP, evidence, notes), `$OUT/results.md` (from `table`), `$OUT/run.log`, and
per-case evidence files (`p3.*.argv`, `p4.strace.txt`, `p5.table.txt`, ...). `INFO` never counts as a pass. The `/usr/bin/kvm`
watcher log is `$WORK_DIR/kvm-watch.log` and must be empty. Case P5 ends with a real purge, but only of a dummy prefix; the
real build and divert are left installed (run `uninstall` / restore the snapshot to clean up). `OUT` and `WORK_DIR` are created only after the gate passes.

### Testing the gate

```bash
bash tests/tier2-gate-test.sh      # no root, no PVE; last line `GATE TEST: pass=N fail=0`
```

Runs `tier2.sh gate` under `env -i` with a temp stub dir first on `PATH` (stub `qm` that only supports `list` and logs every call,
stub `hostname`, `pvecm`), after checking that `qm` resolves to the stub. Fixtures are made-up (`100 101 300`, test range 900-902).
It covers: failing `qm list`, a protected VMID first in a 500-row (>64 KiB) list run 50 times, each protected VMID, VMIDs
outside the test range, wrong hostname, unset/empty/invalid `QAD_PROTECTED_VMIDS`, `none`, `TEST_VMID_BASE`, unset `REF`, and the passing cases.
It also asserts that when the gate refuses, `gate`, `setup`, `teardown` and `table` create no file or directory (no `WORK_DIR`/`OUT`), and that `table` creates `OUT` only after the gate passes. `tier1.sh` (C24) runs this test too.

## W10 Code 43 check

Diagnoses the NVIDIA "Code 43" error in a Windows 10 guest with GPU passthrough. The PowerShell script is read-only and prints
one JSON document with `result` = `ok` | `code43` | `error_other` | `no_nvidia_device`. (The only hardware identifier it contains is
NVIDIA's PCI vendor ID `VEN_10DE`, which is what it looks for.)

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
full setup steps. Host, user, key and port are always arguments; there are no site-specific defaults.
