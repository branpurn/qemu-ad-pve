# setup.sh live end-to-end run on the bare-metal PVE host, 2026-10-06

Record of the first full `setup.sh install` -> `verify` -> restart -> `uninstall` cycle on the real
host (AMD, RTX 4080 at `0000:02:00`, PVE 9). Fix PR: #30 (`fix/setup-e2e-live-20261006`).
Times are host-local EDT (UTC-4) and come from `/root/setup-e2e/0*.log` and the setup logs
(`/var/lib/qemu-ad/setup/logs/*.log`, kept as copies in `/root/setup-e2e/setup-logs/`).

## Settings

`--set l1.vmid=9300 --set gpu.slot=0000:02:00 --set l1.bridge=vmbr1`, Windows ISO
`iso_images:iso/Win10_22H2_English_x64v1.iso`, staged NVIDIA 576.88 (DCH WHQL), Python 3.12.10,
OpenSSH-Win64.zip and an offline wheelhouse (torch 2.6.0+cu124). The GPU's usual VM 9102 was shut down
cleanly for the test (preflight correctly FAILs "GPU in use ... 9102" while it runs); VM 9200 was not touched.
Host baseline captured at 08:39 with `/root/setup-e2e/capture.sh` (VM list/configs, storage, volumes, LVs,
`/var/lib/qemu-ad`, `/etc/qemu-ad`, `dpkg -l` hash, kernel/cmdline/GRUB, modprobe/modules-load,
diversions, `/usr/bin/kvm`, `/opt/qemu-ad` tree hash, systemd units, GPU drivers, root ssh files, kvm/vfio modules).

## Runs

| # | Log | Commit | Start-end | Result |
|---|-----|--------|-----------|--------|
| 01 | 01-preflight-defaults | 885d23a | 08:40, 5 s | FAIL rows as expected: no GPU selected (3 candidates), RAM 4.6 GiB free < 13 GiB (9102 running) |
| 02 | 02-preflight-e2e | 885d23a | 08:40, 5 s | only FAIL: GPU in use by 9102 (expected; 9102 then stopped) |
| 03 | 03-dryrun-* | 885d23a | 08:40, 6 s | dry run (`install -n` and top-level `-n`) list every change; nothing executed |
| 04 | 04-install | 885d23a | 08:41:47-08:47:41 | host steps + VM 9300 OK; Debian image 4.5 min (a dead mirror stalled the SHA512SUMS fetch 2 min); `l1_packages`, `l1_dkms` OK; **`l1_qemu_ad` FAILED** (bug 1, 3) |
| 05 | 05-install-resume1 | c7c09a6 | 08:50:47-08:51:21 | `l1_qemu_ad` (libs installed) OK, `l1_vfio`, `l1_scripts`, L1 reboot; **`l1_reboot` check-kvm FAILED on a correct L1** (bug 2) |
| 06 | 06-install-resume2 | 9904f00 | 08:57:15-09:05:55 (8m40s) | `l1_reboot` PASS (patched KVM default, GPU on vfio-pci in L1), `l2_stage` OK; **`l2_install` FAILED**: Windows Setup rejected the answer file (bug 4) |
| 07 | 07-install-resume3 | e325586 | 09:06:34-09:33:33 (26m59s) | Windows installed unattended in 10.6 min (09:06:51-09:17:27), `l2_enable` OK; **verify timed out (15 min)**: sshd in L2 not running (bug 5) |
| 08 | 08-install-resume4 | 4fe4f4b | 09:38:52-10:06:28 (27m36s) | wiped + reinstalled Windows (09:39:09-09:50:16, 11.1 min), `l2_enable` OK, L2 reachable, CUDA PASS, but **verify timed out**: `GPU_CODE=unknown` (bug 6) |
| 09 | 09-install-resume5 | 3176590 | 10:09:12-10:09:34 (22 s) | `--redo l1_push --redo l1_scripts`; **verify PASS -> install Done** |
| 10 | 10-verify | 3176590 | 10:10, 19 s | `setup.sh verify` PASS (numbers below) |
| 11/12 | 11-shutdown-9300, 12-start-9300 | - | 10:11:29-10:12:56 | `qm shutdown 9300` 11 s (L2 ACPI powerdown, exited cleanly after 9 s; guard released the GPU); `qm start 9300` 2.5 s (guard reserved the GPU) |
| 13 | 13-verify-after-restart | 3176590 | 10:15, 29 s | `setup.sh verify` PASS again (L2 brought up by `w10-l2.service` at L1 boot) |
| 14/15 | 14-uninstall-dryrun, 15-uninstall | 3176590 | 10:16, 11 s | VM 9300 shut down + destroyed with all 3 disks, seed ISO + guard snippet freed, all manifest files removed; **left `/var/lib/qemu-ad/setup/logs/verify-*.log`** (bug 7) |
| 16 | 16-start-9102 | - | 10:17:14-10:17:58 | 9102 restarted: RTX 4080 + HDMI audio Code 0, nvidia-smi 576.88 |

Clean install wall time without the bugs: roughly 5 min host + L1 (image download dominates),
~1 min L1 packages/DKMS/libs/reboot, ~11 min unattended Windows, then first GPU boot + verify (<1 min once ssh works).

## Results

- **L1 KVM:** `KVM_VERSION=l1-dkms-0.1` (`/sys/module/kvm/version` and `modinfo -F version kvm`),
  srcversion `6ECC1E299D32E1AF0DE12F8`, module `/lib/modules/6.12.111+deb13-amd64/updates/dkms/kvm.ko.xz`,
  DKMS `kvm-l1/0.1.0`, `kvm_amd` loaded, DMAR yes, GPU `02:01.0/.1` on vfio-pci in L1 (group 11). CHECK_KVM PASS.
- **L2:** Windows 10 Pro 19045, `/opt/qemu-ad/bin/qemu-system-x86_64` (QEMU 10.2.2) under `w10-l2.service`
  (enabled), host key pinned. NVIDIA GeForce RTX 4080 `PnpStatus=OK`, **ConfigManagerErrorCode 0**,
  driver 32.0.15.7688 (= 576.88), nvidia-smi 576.88, 16376 MiB, PCIe gen4 x4 link as seen by L2.
- **CUDA / PyTorch (L2, C:\qad\venv):** Python 3.12.10, torch 2.6.0+cu124, CUDA 12.4 available, VRAM 15048/16375 MiB free;
  fp32 4096^3 matmul 34.63-34.74 TFLOP/s, fp16 8192^3 100.7-101.2 TFLOP/s, 12 GiB alloc OK,
  200 training steps in 3.4 s (58.6 steps/s, loss 3.341 -> 1.959). `RESULT PASS` in runs 08, 09, 10 and 13.
- **Restart:** `qm shutdown 9300` / `qm start 9300` through the GPU guard; L2 stopped cleanly and came back via the
  service; verify PASS with Code 0 after the restart.
- **Uninstall vs baseline** (`baseline-pre.txt` vs `baseline-post-uninstall-clean.txt`): only difference is the
  mtime of `/zfs_pool/iso_images/snippets/` (the guard snippet was created and removed there):
  `drwxr-xr-x 3 2026-10-05_16:35:15 .` -> `drwxr-xr-x 3 2026-10-06_10:16:15 .`. `dpkg -l` identical, no
  host packages/kernel/GRUB/modprobe/storage.cfg changes; the Debian cloud image was removed by uninstall too.
  Before the manual clean-up of bug 7, `/var/lib/qemu-ad/` additionally existed (2 verify logs).
- Host GPU `02:00.0/.1` on vfio-pci throughout; host `IO_PAGE_FAULT` count 53 before and after (unchanged);
  no AER/Xid/oops lines.

## Bugs found and fixed (PR #30)

1. **c7c09a6** `l1_qemu_ad` failed: the host's copied `/opt/qemu-ad` needs `libgcrypt.so.20` + `libiscsi.so.7`,
   absent from fresh Debian 13 L1 -> new `qad-l1.sh qemu-ad-libs` maps missing sonames to the host's Debian
   packages (`dpkg -S`) and installs them in L1. Same commit: Windows ISO auto-pick matched `virtio-win-*.iso`
   first (now only Win10/Win11-style names, never virtio/unattend); `wget --timeout=30 --tries=5` for the image.
2. **9904f00** `l1_reboot` reported `CHECK_KVM=FAIL` on a correct L1: `lsmod | grep -q` under `set -o pipefail`
   -> lsmod SIGPIPE (rc 141) -> false failure. Replaced in all L1 scripts (some refusal checks could also pass
   silently); lint test `tests/setup/test_shell_pipefail.py`.
3. **ad533fa** the step failure detail kept only the banner line (`=== qad-l1.sh qemu-ad-check <date>`) and hid
   `QEMU_AD=libs-missing ...`; the banner is now dropped.
4. **e325586** Windows Setup stopped at "cannot read the <ProductKey> setting" with no product key configured:
   autounattend now emits an empty `<ProductKey><Key/>` (installs unactivated, edition from /IMAGE/NAME).
5. **4fe4f4b** sshd never started in L2: `ssh-keygen -A` from the elevated first-logon session left
   `C:\ProgramData\ssh\ssh_host_*_key` owned by the qad user; sshd (LocalSystem) refuses them. firstlogon.ps1
   re-owns/re-ACLs the host keys before `Start-Service`, retries, and reports failure honestly. verify now says
   `CUDA=SKIP (L2 not reachable over SSH ...)` instead of "torch not staged" when ssh fails.
6. **3176590** verify reported `GPU_CODE=unknown (... no valid JSON "result" in output (transport rc=0))` although
   the guest returned `{"result":"ok",...}`: `tests/w10-code43-run.sh` parsed JSON only with jq or pwsh, and L1
   has neither. Added a python3 fallback (python3 is in L1 already).
7. **d793136** uninstall left `/var/lib/qemu-ad/setup/logs/verify-*.log` (and therefore `setup/` and
   `/var/lib/qemu-ad/`): only install logs were recorded, and `setup/logs/` itself never was (`open_log()` creates
   it before `s_host_dirs`, which then sees it as pre-existing). install and verify now record the run log and
   `setup/logs/`; test `test_verify_log_is_recorded_for_uninstall`. The two leftover logs of this run (identical
   copies kept in `/root/setup-e2e/setup-logs/`) were removed by hand, then `logs/`, `setup/`, `/var/lib/qemu-ad`.

Not changed (observations): the L2 gets its static `L2_IP=10.254.77.10` (dnsmasq on brl2 also offers
.252-.253 and ACKed the guest's request for .10); the restart verify needed ~2.5 min after `qm start` for the L1
boot + L2 Windows boot.

Not re-run after fixes 6 and 7 from scratch: fix 6 was exercised live (runs 09, 10, 13); fix 7 is covered by
the unit test only (a full reinstall was not repeated).
