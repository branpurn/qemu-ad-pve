# Setting up a disposable nested PVE test node

Tier 2 (`tests/tier2.sh`) needs a real Proxmox VE node with real `qm`, real `dpkg-divert` and a real `/dev/kvm`. This page
describes how to get one that is safe to break: a **throwaway PVE installation running as a VM** (nested virtualization) on
some outer host, with a **cold snapshot** you roll back to after every run.

> **Never run `tier2.sh` on a node you care about.** It installs a QEMU build, diverts `/usr/bin/kvm`, creates and destroys
> its own test guests, reinstalls `pve-qemu-kvm` with apt and runs a real purge. A bug in the code under test can leave
> `/usr/bin/kvm` missing, which stops every VM on that node. The safety gate (below) refuses most wrong nodes, but it is a
> tripwire, not a sandbox: the disposable node and the snapshot are what actually protect you.

Everything here is a template. Replace each `<placeholder>` with your own value. Nothing in this repo should name your
hosts, VM IDs, addresses, storages, bridges or credentials, and that includes your own notes about the test node: keep them
outside the repo.

## 1. What the test node must be

| Requirement | Why |
|---|---|
| A PVE installation inside a VM (or on spare hardware) that exists only for testing | The runner changes `/usr/bin/kvm`, `/opt`, `/etc/qemu-ad` and the dpkg divert table, and runs a purge |
| `/dev/kvm` present inside it (nested virtualization) | The test guests are real QEMU guests; the gate aborts without it |
| Not a member of a cluster | The gate aborts if `pvecm status` succeeds |
| No guests other than the three test guests | The gate aborts on **any** VMID outside the test range (see section 6) |
| Outbound HTTPS to the QEMU download site, GitHub and your apt mirrors | The side QEMU is built from a downloaded tarball and a cloned patch repo; `setup` also installs a few tools with apt |
| A tiny Linux live ISO (the default expects an Alpine "virt" image) in an ISO-capable storage | The test guests boot it; there are no data disks |
| A network bridge the test guests can attach to | `qm create` gives each guest one NIC on it (it does not need to reach anything) |
| Root access | The runner must run as root on the node |

## 2. Create the outer VM (nested virtualization)

On the **outer** host, which you do not run the tests on:

1. Enable nested virtualization for your CPU vendor and make it persistent. On an outer PVE host this is the `nested`
   parameter of the `kvm_amd` or `kvm_intel` module, set through a file in `/etc/modprobe.d/` and applied by reloading the module
   (no running guests) or rebooting. Check it with `cat /sys/module/kvm_amd/parameters/nested` (or `kvm_intel`): it must print
   `1` or `Y`.
2. Create the VM that will hold the test node. Use CPU type `host` (not a named model), so the virtualization flags are passed
   through: `qm set <outer_vmid> --cpu host`.
3. Size it small. A few vCPUs, several GB of RAM and a few tens of GB of disk are enough; the disk mostly holds the QEMU
   source tree, the build and the install prefix. Disable ballooning for this VM, so the guest's memory is not reclaimed in the middle of a build.
   More cores shorten the build (a first build takes tens of minutes on a small node; see the README).
4. Give it a NIC on a bridge that has outbound internet access. Keep it off any network where you would mind a mistake.
5. Install PVE in it from the official installer, as a standalone node (do not join or create a cluster). Use a throwaway
   root password and keep it out of the repo.

Inside the new node, check the prerequisites before going on:

```bash
ls -l /dev/kvm                                 # must exist
grep -E -c '(vmx|svm)' /proc/cpuinfo           # must be non-zero
pvecm status                                   # must FAIL (not in a cluster)
qm list                                        # must succeed and list nothing (or only test guests)
hostname                                       # remember this; it becomes TEST_HOSTNAME
```

## 3. Package repositories

PVE ships with the enterprise repository enabled, which fails `apt update` without a subscription. On a test node, disable it and
enable the no-subscription repository instead. (If an extra repository is broken, `qemu-ad-pve.sh install` warns and carries on
from the existing package lists, but fixing it avoids confusing logs.) Update the node once, **before** the snapshot, so the
snapshot already has the packages you want to test against.

Record what you test against: `pveversion -v`. The runner saves it as a baseline. Do not assume the test node runs the same
`pve-qemu-kvm` or `qemu-server` as production: tier 2 exists to show how the script behaves against whatever the test node has,
and the README's version-skew section explains what differs from the side build. Do not apply newer packages
mid-run: case P7 deliberately reinstalls the vendor package, and you want to know which one it started with.

## 4. ISO and bridge

Upload the live ISO to an ISO-capable storage on the node. The runner refers to it as `<storage>:iso/<image>.iso`. The
defaults are the stock PVE storage and bridge names and a file called `alpine-virt.iso`; override them with the `ISO` and
`BRIDGE` environment variables if yours differ (see `tests/README.md`). If the ISO is missing, `setup` only warns, and the guests
simply will not boot, so P8 will not pass.

You do not need to install anything else by hand: `setup` installs the few tools it needs (`git`, `socat`, `strace`) itself.

## 5. Take the cold snapshot, and how to revert

Take the snapshot when the node is fully prepared (updated, ISO uploaded, no qemu-ad install, no divert) and **before the first test run**.
Take it cold, with no RAM state, so a rollback gives a clean boot:

```bash
# on the OUTER host
qm shutdown <outer_vmid>
qm snapshot <outer_vmid> pre-qemu-ad
qm start <outer_vmid>
qm listsnapshot <outer_vmid>        # confirm that pre-qemu-ad is listed
```

After a run (or after anything odd), revert from the outer host:

```bash
# on the OUTER host
qm stop <outer_vmid>
qm rollback <outer_vmid> pre-qemu-ad
qm start <outer_vmid>
```

Roll back after every full run so the next one starts from the same state. Use a rollback, not a reboot from inside the node, to reset it: the divert
and the side QEMU install survive a reboot, and tier 2 leaves them installed on purpose after the last case. If you are not using PVE as the outer host, use your
hypervisor's equivalent of a cold snapshot and revert. `tier2.sh` never touches the outer host; the snapshot and rollback are done by
whoever owns it.

## 6. How `tier2.sh` gates the node

Every case, and `teardown`, `setup` and `table`, start with the same gate. Any failure aborts before anything is created
or changed. Put these in the environment (details and the full variable list are in `tests/README.md`):

| Variable | Meaning |
|---|---|
| `TEST_HOSTNAME` | Required. Must equal the node's `hostname`, so the script cannot run on the wrong machine by accident. |
| `QAD_PROTECTED_VMIDS` | Required, no default. Space-separated VMIDs that must **not** exist on this node, or the word `none` to say deliberately that there are none. Empty or unset is refused. A protected VMID inside the test range is a configuration error. |
| `REF` | Required for `setup` and `all`: the full-length commit hash to test. It is checked against `HEAD` after checkout, so you never test a stale commit by accident. |
| `TEST_VMID_BASE` | Optional. The first of the three test VMIDs (the default is in the README); `base`, `base` plus one and `base` plus two are the **only** VMIDs the script creates, starts, stops or destroys. Any existing guest with one of those IDs is destroyed by `setup` without a prompt. |

What the gate refuses:

- the hostname does not match `TEST_HOSTNAME`, or `qm` is missing (not a PVE node);
- `QAD_PROTECTED_VMIDS` is unset, empty or malformed, or overlaps the test range;
- `qm list` fails or cannot be parsed (the gate fails closed);
- **any VMID is present that is not one of the three test VMIDs.** Protected VMIDs are named in the message, and everything else outside the range is treated as protected too. So the node must carry nothing but, optionally, the test guests: do not share a test node with other VMs;
- the node is in a cluster, or `/dev/kvm` does not exist.

If the gate refuses, that is the tool working. Fix the node (or, if it is the wrong node, stop), do not weaken the gate. The gate is
itself tested without any PVE node by `tests/tier2-gate-test.sh`.

## 7. Run it

```bash
export TEST_HOSTNAME=<test-node> QAD_PROTECTED_VMIDS="<ids or none>"
bash tests/tier2.sh gate                                  # just check the gate; changes nothing
REF=<full commit hash> bash tests/tier2.sh all            # setup, all cases, teardown, table
```

`setup` clones the repository to `WORK_DIR` (default `$HOME/qad-work`), checks out `REF`, and runs tier 1 on that exact commit first.
Results end up in `OUT` (default under `WORK_DIR`): `results.tsv`, `results.md`, `run.log` and per-case evidence files, and the `/usr/bin/kvm`
watcher log must be empty. Copy the results off the node **before** you roll back, because the rollback erases them.

## 8. Pitfalls

- **Roll back between runs.** A second run on a node that still has the divert installed is refused by `setup`; that is intended.
- **A shared node is not a test node.** Other guests on it will make the gate abort, and a gate that did not abort could not guarantee they survive.
- **Nested virtualization off.** Symptom: no `/dev/kvm` in the node, or guests that never start. Fix the outer host's module parameter and the outer VM's CPU type, not the tests.
- **Build time.** The first `install` builds QEMU from source and takes a while. You can take the snapshot after one successful build to make reruns faster, but then P0 is no longer a from-scratch install, so know which of the two you are testing. `P0_VERIFY_ONLY` re-checks an existing install log; it is not a replacement for a clean run.
- **Serial console.** The test guests use a serial socket and a serial VGA, so there is no graphics to look at. A boot check reads the serial socket.
- **Do not store credentials in the repo.** Keep the node's root password or SSH key in a file outside any git working tree, readable only by you.
- **Time to reset.** If anything about the node feels wrong, roll back instead of repairing it by hand. That is what the snapshot is for.
