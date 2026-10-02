# QA summary: tests/add-harness PR (generic summary)

This is a condensed, environment-neutral summary of two QA rounds on the PR that added the
tier1.5 / tier2 harness, spec and a Windows Code 43 check. The original per-item evidence
referred to lab-specific values and local artifact paths and is intentionally not reproduced.

## Method (sandbox only)
- Every run was inside a bubblewrap sandbox (read-only root, tmpfs for /root, /opt, /tmp, no network, fake `/dev/kvm`).
- Stub `qm`, `pvecm`, `hostname`, `git`, `rm`, `dpkg*`, `ssh` placed first in `PATH`; each stub logs every call.
- No real PVE node was contacted and no real `qm` was run.
- Mutation testing: single-line mutants of the gate / guard code, each run against the PR's tests and an independent suite, to prove the tests are not vacuous.

## Round 1: verdict FAIL (narrow)
- B1 (Medium): the tier2 safety gate failed OPEN when `qm list` exited non-zero under `pipefail` (or when `grep -q` caused SIGPIPE on a large list).
- B2 (Low-Medium): a real lab node name was used as an example hostname in the README (site-specific value).
- B3 (Low): a purge-reject test case contradicted the script under test (empty PREFIX is the default), giving a false FAIL.
- B4 (Low-Medium): tier15 sandbox guard was attestation-only and its `qm` check was PATH-dependent.
- B5 (Low): tier15 scripts exited 0 regardless of FAIL; the lock test asserted nothing.
- D1-D6: documentation/spec mismatches (Low/Info).
- Everything else passed: scrub of addresses / hop paths / credentials, hostname and VMID gates, tier1, clean merges with the neighbouring PRs.

## Round 2: verdict PASS (no blockers)
- B1 fixed: the gate fails closed on every `qm list` failure mode (200/200 matrix cases closed, no flake).
- B2-B5 and D1-D6 fixed and verified by real sandboxed runs plus tamper/guard tests.
- 37 mutants (25 tier2, 12 tier15): all detected.
- Safety model after the fix: test hostname, protected-VMID list and git ref are required; "none" must be spelled out; every VMID outside the test range is auto-protected.

## Remaining non-blocking findings (classes)
- History: an earlier commit on the PR branch still contained a site-specific hostname and VM IDs (the default branch history was clean; squash-merge keeps it clean).
- A generic example VMID remained in files the PR did not touch.
- An undocumented test hook (`T15_FS_ROOT`) can disable filesystem probes.
- The `table` subcommand ran before the gate and created output files (harmless).
- The PR's own tests did not prove that every subcommand calls the gate; an independent suite covered this.
- Real `qm list` stderr noise merged via `2>&1` would make the gate abort (fails closed, safe).
- tier15-window can report INFO and exit 0 when every poll reports "missing" (vacuous in a broken environment).

## Unverified
- Behaviour against a real PVE `qm list` format and stderr.
- tier2 cases that need a real nested PVE node.
- The PowerShell Code 43 check and its remoting mode (no PowerShell / Windows guest in the sandbox).
- Real-root / kernel `dpkg` behaviour (tier15 used a user-namespace fake root).
