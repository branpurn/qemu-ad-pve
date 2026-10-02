# qa/ : generic QA harness scripts and review reports

Docs and scripts only. Nothing here is used by `qemu-ad-pve.sh` or by the existing `tests/`.
Everything is **sandbox-only**: scripts use stub binaries (a stub `qm`, C stubs for QEMU), temp dirs,
a throwaway `dpkg-divert --admindir`, or QEMU in TCG mode. None of them needs, or should be run
against, a real PVE node, a real `/usr/bin/kvm`, or real VM configs.
All site-specific values (VM IDs, node names, addresses, paths) have been replaced by placeholders.

## Layout

| Path | What it is |
|---|---|
| `reports/QA-REPORT-cumulative.md` | Cumulative review notes for PR #3 to PR #8 (verdicts, findings, mutation results). |
| `reports/REPORT-PR9-summary.md` | Condensed summary of the two review rounds on the tier1.5/tier2 harness PR. |
| `reports/REPORT-stub-qm-test-technique.md` | Generic description of the stub-`qm` technique and the classes of findings it exposes. |
| `scripts/run_tests.sh` | Independent harness for `qemu-ad-pve.sh` (wrapper rendering, argv handling, list-file parsing, install/uninstall helpers, purge guards). |
| `scripts/sandbox.sh` | Runs a command under `bwrap` with the real filesystem read-only. |
| `scripts/parse_cmdline_e2e.sh` | End-to-end check that the generated wrapper's process is recognised by a PVE-style `parse_cmdline`. |
| `scripts/lock_false_positive.sh` | Repro for `dpkg_lock_held` inode collisions across filesystems. |
| `scripts/uninstall_after_vendor_removed.sh` | Repro for `uninstall` after the vendor binary vanished (simulated package removal). |
| `stubs/qm` | Stub `qm` with state in a temp dir and env-var failure injection (see header comment). |

## How to run

Requirements: bash, cc, python3, perl; optional: `bwrap`, `dpkg-divert`, `qemu-system-x86_64` (TCG).

```sh
# main harness (required argument: the script under test); safest inside the read-only sandbox
QA_WORK=$(mktemp -d) qa/scripts/sandbox.sh qa/scripts/run_tests.sh ./qemu-ad-pve.sh
# or directly (everything still happens in a mktemp dir)
qa/scripts/run_tests.sh ./qemu-ad-pve.sh

# sections 14/15 diff against older script revisions: taken from git history of the checkout
# (commits 5bc973c and 08ce424) or from BASE_PR6_SCRIPT / BASE_PR7_SCRIPT if you set them

qa/scripts/parse_cmdline_e2e.sh ./qemu-ad-pve.sh
qa/scripts/lock_false_positive.sh ./qemu-ad-pve.sh
qa/scripts/uninstall_after_vendor_removed.sh ./qemu-ad-pve.sh
```

Using the stub `qm` against a script that calls `qm`:

```sh
export STUB=$(mktemp -d); printf 'name: <vmname>\ncpu: host\n' > "$STUB/conf"; echo running > "$STUB/status"
PATH=$PWD/qa/stubs:$PATH FAIL_ON=shutdown your-script.sh   # inspect "$STUB/conf" and "$STUB/calls" afterwards
```

All scripts are plain bash and can be syntax-checked with `bash -n`.
