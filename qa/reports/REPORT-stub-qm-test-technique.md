# Stub-`qm` test technique and findings classes (generic)

Two private, single-purpose VM-configuration scripts (one changing CPU flags and extra QEMU args; one
changing the emulated storage controller, firmware strings and PCI layout) were reviewed in a sandbox. The
scripts and their site-specific values are not published. This note keeps only the technique and
the classes of findings, which apply to any script that edits a VM config through `qm`.

## Technique
1. Put a stub `qm` first in `PATH` (see `qa/stubs/qm`). It keeps state in a temp dir: a `conf` file of `key: value` lines, a `status` file and a `calls` log.
2. Implement only the subcommands the script uses: `config`, `status`, `shutdown`, `stop`, `start`, `snapshot`, `set` (including `--delete`), `showcmd`.
3. Inject failures through an env var (`FAIL_ON=shutdown,set,start,startall,snapshot,setargs1,...`) with per-call counters, so that "fails once, then succeeds" and "fails from the Nth call" are both expressible.
4. Run the script against many starting configs and assert on the final `conf`, `status` and the `calls` log (what was or was not called).
5. For emulated hardware layout questions, use a local QEMU in TCG mode with a PVE-like `-readconfig` file and compare `info pci` output between variants. No KVM, no passthrough, nothing touches a host.
6. Signals: start the script in its own session, pause it inside a stubbed `qm set`, send SIGTERM / SIGHUP / SIGINT and assert on rollback and final VM state.

## Scenarios worth covering
- dry-run: no mutating call, no backup directory created.
- apply, second apply (must refuse), revert (must restore exactly, including keys that were absent before).
- name / identity guard: wrong expected name must refuse.
- failure of each step (snapshot, set, shutdown, start, post-start verification) must roll back and leave the VM in its prior state.
- signals mid-run must roll back.
- revert when nothing was applied must refuse; a second revert must not reboot a running VM needlessly.
- `showcmd` output in its real multi-line, backslash, quoted form; with more than one `-cpu` option the last one wins.

## Findings classes seen
- Stale backup reuse: a backup of an earlier state is restored after the user edited the config in between.
- Dry-run side effects: a directory created before the dry-run check.
- Timeout path: a graceful shutdown timeout without a force flag still ended in a hard stop during rollback.
- Rollback itself failing: the VM is started with a half-applied config and the backup is deleted.
- Revert without failure handling: stop succeeds, restore fails, VM left stopped; start failure ignored but "reverted" printed.
- Unchecked writes: a backup write to a missing directory is ignored.
- No guard against already-applied flags when the backup is absent (duplicate options).
- Verification patterns that are too weak (match text that can appear for other reasons).
- Pre-flight gaps: no check that the guest is reachable before shutting it down; a TCP connect without a timeout.
- Side effects of the change: options such as an invariant TSC / non-migratable CPU block live migration, VM-state snapshots and suspend-to-disk; without paravirtual clock hints the guest clock relies on the TSC.
- Emulated machine layout: some "off" switches are no-ops on PVE machine types because the PVE readconfig defines those controllers explicitly; others do remove the function. Always test with a PVE-like config rather than the stock machine.
- PVE appends `args` last on the command line; the last occurrence of a repeated option is effective.

## Verdict history (generic)
Both scripts: PASS-with-changes in sandbox only; every finding above was Low or Medium and none required
changes to the host. Nothing was run on a real node.
