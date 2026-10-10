# One-command setup (`setup.sh`)

`setup.sh` runs **on the Proxmox VE host** and builds the whole nested stack from this repo:

```
PVE host (stock, unchanged)
└── L1 VM  (new; Debian 13 cloud image, q35 + OVMF + Intel vIOMMU, GPU behind a pcie-pci-bridge)
    ├── patched KVM (dkms/, boot default, apt-held kernel)
    ├── qemu-ad-pve (/opt/qemu-ad, copied from the host or built)
    └── Windows L2  (AHCI + e1000e, OVMF VARS built without the GPU, gets the GPU via vfio-pci)
```

> **Status: UNTESTED end to end.** Every piece is modelled on what the lab did by hand (docs/gpu-phase-*.md), but
> `setup.sh` itself has only been exercised by unit tests, `--dry-run` against stub PVE commands, and shellcheck. It
> has **not** been run on a PVE host, in an L1, or against Windows Setup. See [Tested vs untested](#tested-vs-untested).
>
> **Builds on PR #24 (`scripts/qm-native-9200/`)**, the lab's proven plain `qm start/shutdown 9200` setup. The L1 VM
> config, the GPU-guard hookscript and the L1 `w10-l2.service` + `l2-service.sh` are taken from there (rendered for
> your VMID/GPU, not copied by hand); see [Relation to qm-native-9200](#relation-to-qm-native-9200-pr-24).

## Quickstart

```bash
# on the PVE node, as root
git clone https://github.com/branpurn/qemu-ad-pve && cd qemu-ad-pve
./setup.sh preflight          # read-only: PASS/WARN/FAIL table with fixes
./setup.sh --dry-run          # = install --dry-run (also -n): prints every host change and every L1 command, executes nothing
./setup.sh                    # = ./setup.sh install: asks a few questions (Enter = default), then builds it all
```

Unattended:

```bash
cp setup/config.example.ini /root/qad.ini && chmod 600 /root/qad.ini && $EDITOR /root/qad.ini
./setup.sh install --config /root/qad.ini --yes
```

Single overrides work too: `./setup.sh --yes --set l2.windows_iso=local:iso/Win10.iso --set stage.nvidia_driver=/root/576.88-desktop-win10-win11-64bit-international-dch-whql.exe`.

What you need before starting:

* Nested KVM and the IOMMU enabled on the host (preflight checks; `setup.sh` never changes host modules or the kernel command line).
* The GPU not in use by a **running** VM (preflight lists every VM that references it, via `hostpciN`, a resource mapping or `args:`; `setup.sh` never stops other VMs).
* A Windows ISO in an `iso` storage (e.g. `local:iso/Win10_22H2_English_x64.iso`) **or** an existing Windows qcow2/raw that already boots on SATA/AHCI.
* Optional offline payload for the L2 (it has **no internet**): the NVIDIA Windows driver `.exe`, a `python-3.x-amd64.exe`, a wheelhouse directory (e.g. from `scripts/l1-w10/fetch-win-wheels.py`), `OpenSSH-Win64.zip` (only if the Windows image lacks the OpenSSH capability). Nothing proprietary is downloaded unless you pass `--download-proprietary` **and** list URLs with SHA-256 in `stage.downloads`.
* **Every GPU function already on `vfio-pci`** on the host (preflight FAILs otherwise and prints three ways to get
  there; `setup.sh` never binds drivers or changes host modprobe config). On a host where a `hostpci` VM used the GPU
  once, this is already the case.
* An **existing** storage with `snippets` content for the GPU-guard hookscript (preflight FAILs otherwise;
  `setup.sh` never changes `storage.cfg`; enable it yourself under Datacenter → Storage → Content, or set
  `l1.hookscript=no` to run unprotected).

## The UX flow

1. **Preflight** (always first, read-only): PVE version, root, CPU vendor, `svm`/`vmx`, nested, IOMMU, GPU picker
   (every display device with all its functions, IOMMU group, other group members, host driver, and which VMs
   reference it and whether they run), free VMID (`pvesh get /cluster/nextid`), disk storage + free space (thin
   storage is a WARN), seed-ISO storage, snippets storage, bridge, RAM (vfio pins all L1 RAM), host tools, qemu-ad
   source, Windows ISO/image, staging files. FAIL rows stop `install` before anything is changed.
2. **Questions** (skipped with `--yes`; anything given in `--config`/`--set` is not asked): GPU, VMID, name,
   storage, bridge, L1 RAM/cores, L2 source, Windows ISO or image, Windows disk size, L2 RAM, autounattend mode,
   product key (hidden input), NVIDIA driver path.
3. **Plan + confirm**: a list of exactly what will be created on the host. `--yes` skips the confirmation.
4. **Steps** (each idempotent, recorded in the state file; a re-run skips finished steps, `--redo STEP` repeats one):

   | Step | Where | What |
   | --- | --- | --- |
   | `host_dirs`, `ssh_key` | host | `/var/lib/qemu-ad/setup/{ssh,cache,logs}`, dedicated ed25519 key (only used for L1) |
   | `debian_image` | host | download `debian-13-generic-amd64.qcow2` + `SHA512SUMS`, verify (or use `l1.debian_image`) |
   | `seed_iso` | host | NoCloud seed ISO `qad-l1-<vmid>-seed.iso` in the iso storage (root SSH key, qemu-guest-agent, optional static IP) |
   | `hookscript` | host | `qad-l1-<vmid>-gpu-guard.pl` in the snippets storage: `scripts/qm-native-9200/9200-gpu-guard.pl` rendered for your VMID and GPU functions (only the VMID and the `@ids` line change). pre-start refuses unless every function is on `vfio-pci`, then takes a qemu-server PCI reservation so a `hostpci` VM is refused while L1 runs; post-stop releases it. It never binds drivers |
   | `vm_create` | host | `qm create` (see below) + `qm disk resize` + Windows disk + Windows ISO as `ide0` |
   | `vm_start` | host | `qm start <vmid>` (re-checks that no running VM uses the GPU) |
   | `l1_ip` | host | IP via `qm guest cmd network-get-interfaces`; L1's SSH host key read through the guest agent and pinned (no trust-on-first-use) |
   | `l1_ssh` | L1 | wait for SSH and `cloud-init status --wait` |
   | `l1_push` | L1 | copy `dkms/`, `scripts/l1-w10/`, `setup/l1/`, `tests/w10-code43-*`, `qemu-ad-pve.sh` to `/root/qemu-ad-pve`; write `/etc/qemu-ad/setup.env` |
   | `l1_packages` | L1 | kernel + headers, dkms, build tools, ovmf, dnsmasq-base, genisoimage, …; reboots L1 if a newer kernel was installed; `apt-mark hold` the kernel |
   | `l1_dkms` | L1 | patched KVM via `dkms/` (`l1.kvm_source=debian`: `arch/x86/kvm` + `virt/kvm` from the matching Debian `linux-source`, like the lab build; `upstream`: `dkms/fetch-kvm-source.sh`), modules-load, check that `modinfo kvm` resolves to `updates/dkms` |
   | `l1_qemu_ad` | L1 | `copy`: read-only `tar` of the host's `/opt/qemu-ad` into L1 (the lab method, docs/gpu-phase-patched-kvm-l1.md); `build`: `qemu-ad-pve.sh build` in L1 (new subcommand: deps, fetch, patch, build; no divert/wrapper) |
   | `l1_optional_qemu` | L1 | **default ON** (`l2.optional_patches` = `0001-acpi-omit-waet,0002-acpi-oem-id-table-id-revision,0003-atapi-inquiry-from-model`; `none` skips it; ~4 min): second QEMU built in L1 in `/opt/qemu-ad-optpatch` with the optional patches (docs/optional-qemu-patches.md); `/opt/qemu-ad` is not touched |
   | `l1_ovmf_identity` | L1 | **default ON** (`l2.ovmf_identity = yes`; `no` skips it; ~7 min): OVMF with another firmware identity built **in L1** (scripts/ovmf-identity, docs/ovmf-identity.md) to `/opt/ovmf-identity/OVMF_CODE.fd`; alternatively `l2.ovmf_identity_dir` copies a prebuilt `OVMF_CODE_4M.fd` (sha256-checked). New path; `/root/l2/OVMF_CODE.fd` and `VARS.fd` are kept |
   | `l1_vfio` | L1 | `vfio-pci ids=<GPU ids>` + softdeps, initramfs |
   | `l1_scripts` | L1 | `/root/w10` (start-l2.sh, resolve-windows-disk.sh, l2net-up/down.sh, qad-qmp.py, and `l2-service.sh` from `scripts/qm-native-9200`), `OVMF_CODE.fd`, `/etc/qemu-ad-l2.env`, `w10-l2.service` from `scripts/qm-native-9200` (installed, not enabled yet). Both are copied verbatim when the L1 GPU address is the lab's `02:01.0/.1`; otherwise only the GPU BDF list and the `ConditionPathExists` path are adapted |
   | `l1_reboot` | L1 | reboot and prove: kvm version matches the patched build, from `updates/dkms`, DMAR present, GPU on vfio-pci |
   | `l2_stage` | L1 | `stage.iso` (label QADSTAGE: `\qad\firstlogon.ps1`, `gpu-driver.ps1`, your files, `authorized_keys`) and `autounattend.iso` |
   | `l2_install` | L1 | Windows install/first boot **without the GPU** under qemu-ad-pve (systemd-run unit `qemu-ad-l2-install`, survives a disconnect); builds `VARS.fd` without the GPU. Progress is polled; the VNC hint (`ssh -L` to L1, display on 127.0.0.1 only) is printed |
   | `l2_enable` | L1 | delete `autounattend.iso` (holds the password), enable + start `w10-l2.service` (GPU) |
   | `verify` | L1→L2 | patched KVM, L2 running, GPU `ConfigManagerErrorCode` 0 over SSH into Windows, optional PyTorch CUDA check. The first SSH connect to L2 records its host key (`L1:/root/w10/l2_known_hosts` + fingerprint in `l2_hostkey.pinned`); every later L1→L2 SSH uses `StrictHostKeyChecking=yes`. A reinstall/wipe through `qad-l1.sh` forgets the key |

5. **Summary**: colourised step table, the generated Windows admin password (printed once; also root-only in
   `L1:/etc/qemu-ad/l2-secrets`), the SSH command for L1 and the log path.

Other subcommands:

* `./setup.sh status`: what the manifest lists, step states, `qm status`, and `qad-l1.sh status` from L1 (patched KVM, L2 state).
* `./setup.sh verify`: re-runs the L1/L2 checks; PASS/FAIL table; exit code 0 only on PASS.
* `./setup.sh audit` (also `verify --audit`): opt-in, read-only **bare-metal appearance audit**: L1 `systemd-detect-virt`/DMI, and in L2 the CPUID hypervisor bit, WAET/ACPI OEM ids, SMBIOS types 0-4/17 incl. chassis, MAC OUI, disk model/firmware, registry `SystemBiosVersion`, GPU Code. PASS/FAIL/INFO rows are compared with what this install's settings promise; exit 0 only on `AUDIT=PASS`. See [bare-metal-appearance.md](bare-metal-appearance.md).
* `./setup.sh uninstall [--dry-run] [--force]`: see [Rollback](#rollback--uninstall).

## Exactly what changes on the host

| Change | How it is removed |
| --- | --- |
| VM `<vmid>` (tag `qemu-ad-pve`, description starts with `qemu-ad-pve-setup:<install-id>`), its EFI disk, L1 disk (`scsi0`, imported from the Debian image) and Windows disk (`scsi1`, new or imported from your image) | `qm destroy <vmid> --purge 1 --destroy-unreferenced-disks 1`, **only if the marker is still in the description** |
| `<iso-storage>:iso/qad-l1-<vmid>-seed.iso` | `pvesm free`, only if unchanged (sha256) |
| `<snippets-storage>:snippets/qad-l1-<vmid>-gpu-guard.pl` (unless `l1.hookscript=no`) | `pvesm free`, only if unchanged |
| `/var/lib/qemu-ad/manifest.json`, `/var/lib/qemu-ad/setup/` (state.json, config.ini *without secrets*, logs, ssh key + pinned known_hosts, Debian image cache) | `rm` of the listed files (sha256-checked where recorded), then `rmdir` of directories setup created, only if empty |

The VM config uses the same shape as the lab's proven `samples/qm-native-9200/9200.conf.active-final`:

* `machine: q35,viommu=intel`: PVE itself adds `intel-iommu,intremap=on,caching-mode=on` and `kernel-irqchip=split`
  (no hand-written `intel-iommu` in `args:`).
* `args:` holds **only** the GPU topology and the OVMF aperture, in #24's order and with #24's ids:
  `-device pcie-pci-bridge,id=gpubr,bus=ich9-pcie-port-1,addr=0x0
  -device vfio-pci,host=<slot>.0,id=gpu-vga,bus=gpubr,addr=0x1.0,multifunction=on
  -device vfio-pci,host=<slot>.1,id=gpu-audio,bus=gpubr,addr=0x1.1
  -fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536` (further functions get `id=gpu-fnN`).
* **No `hostpciN`** (qm-native GPU topology fails with "group used in multiple address spaces",
  docs/gpu-phase-intel-viommu.md); the hookscript provides the exclusivity `hostpci` would.
* `hookscript: <snippets>:snippets/qad-l1-<vmid>-gpu-guard.pl`, `startup: down=240`, `onboot: 0`.
* `bios: ovmf`, `efidisk0: …,efitype=4m,pre-enrolled-keys=0` (Secure Boot off, so the unsigned DKMS modules load),
  `cpu: host`, `balloon: 0`, `scsihw: virtio-scsi-single`, `agent: 1`, `serial0: socket`.

## L2 hardware identity (software-compatibility lab setting)

Some lab software checks whether Windows looks like ordinary hardware. The L2 is configured, by default, to
report a plausible desktop (answers-file keys under `[l2]`, all optional):

| Key | Default | What the L2 sees |
|---|---|---|
| `cpu` | `host,-hypervisor,kvm=off` | CPUID leaf 1 bit 31 clear, KVM leaf 0x40000000 empty |
| `smbios` | `asus-am5` | SMBIOS types 0 (AMI BIOS), 1, 2 (ASUS board), 3, 4 (AM5 / Ryzen 9 7950X strings), 17 (Kingston DIMM) |
| `smbios_chassis` | `desktop` | `desktop`: the type 3 (chassis) is a raw structure with chassis type 3 (Desktop) and ASUSTeK strings, written to `/root/w10/smbios-type3.bin` in L1 and passed as `-smbios file=` (QEMU's own type 3 is chassis type 1 "Other" / "Default string" and `-smbios type=3` cannot change the type). `none` keeps the `type=3` fields. Needs `smbios = asus-am5` |
| `mac_oui` | `a4:bf:01` | an Intel OUI instead of QEMU's `52:54:00` |
| `disk_model` / `disk_serial` / `disk_firmware` | Samsung SSD 980 PRO 1TB / derived / 5B2QGXA7 | the Windows disk |
| `vga` | `std` | install-time VGA (QEMU PCI 1234:1111, watch the install over VNC); `none` removes it from the start |
| `vga_after_verify` | `none` | the `l2_finalize` step switches the VGA off after the first successful verify (one L2 restart, re-verify, automatic revert on failure); `keep` leaves it |
| `edid_monitor` | `none` | experimental registry EDID override (`asus-vg248qe`, `dell-s2421h`); no effect without an attached display (see docs/bare-metal-appearance.md), use an EDID emulator dongle |
| `cleanup_ghosts` | `yes` | same step removes stale (not present) CD-ROM / `ASUS HARDDISK` / Standard VGA device instance keys (exported to `/root/w10/ghost-backup/` in L1 first) |
| `cdrom_model` / `cdrom_firmware` | `ASUS DRW-24B1ST` / `1.00` | the optical drive Windows sees (empty model = patched QEMU default `ASUS ASUS DVD-ROM`); needs optional patch 0003 |
| `detach_stage_iso` | `yes` | after the first successful verify the staging ISO is ejected and stays detached across restarts (the file stays in L1) |
| `cleanup_unattend` | `yes` | after the first successful verify the `l2_finalize` step deletes `unattend.xml`, `UnattendGC`, `actionqueue` and the Setup/Panther logs in the L2 |
| `cleanup_staging` | `yes` | same step deletes the staged installers and one-shot first-boot scripts/logs in `C:\qad` (keeps `venv`, `py`, `audit`, `pytorch-offline-bench.py`, sshd, the admin account) |

These end up in `/etc/qemu-ad-l2.env` (`CPU`, `L2_MAC`, `DISK_*`, `VGA`, `SMBIOS_FILE`) and are applied by
`start-l2.sh`. Changing `mac_oui` on an installed L2 changes its MAC; `l2net-up.sh` drops a stale DHCP lease
that still holds the L2 address under the old MAC. Live-tested with GPU Code 0 and torch fp32 ~34.6 /
fp16 ~101 TFLOP/s. Not changeable from QEMU arguments: the ACPI WAET table (QEMU adds it unconditionally in
`hw/i386/acpi-build.c`; optional patch `0001-acpi-omit-waet`, see docs/optional-qemu-patches.md), the OVMF firmware vendor string in the registry
`SystemBiosVersion`, and the PCI/chipset device IDs (Q35/ICH9 Intel IDs, already rewritten by the
anti-detection patch).

## L1 looks like bare metal too (`l1.smbios`, `l1.hide_hypervisor`)

Some lab software also checks the machine it runs on (the L1 here). New L1 VMs are created with the same ASUS
AM5 identity as the L2 (own serials) and without the hypervisor CPUID bit:

* `cpu: host,hidden=1` and `-cpu host,-hypervisor,kvm=off` in `args:`;
* `smbios1:` (type 1: ASUS / System Product Name), and `-smbios` entries in `args:` for types 2 (ROG STRIX
  X670E-E GAMING WIFI), 4 (Ryzen 9 7950X, AM5) and 17 (Kingston DIMM);
* types 0 and 3 as raw `-smbios file=/var/lib/qemu-ad/setup/smbios/qad-l1-<vmid>-smbios-type{0,3}.bin`
  (written by the `l1_smbios` step, recorded in the manifest, removed by `uninstall`). QEMU cannot do this with
  `-smbios` fields: it always sets the BIOS-extension "virtual machine" bit (byte 2 bit 4), which
  `systemd-detect-virt` reports as `vm-other` ("DMI BIOS Extension table indicates virtualization") even when
  the CPUID bit is hidden, and it writes chassis type 1 (Other) instead of 3 (Desktop).

Live result (phase C, L1 = VM 9300): `systemd-detect-virt` = `none`, `/dev/kvm` and `kvm_amd` fine, `w10-l2.service`
autostarts, GPU Code 0, `verify` PASS, torch fp32 34.7 / fp16 101.0 TFLOP/s. Only affects L1s created by this
version; an existing L1 keeps its config (`qm set` the same lines by hand to match, then `qm shutdown` / `qm start`).
`l1.smbios = none` / `l1.hide_hypervisor = no` restore the previous VM shape.

## Use Shutdown, not Stop

Once installed, L1 is driven exactly like 9200 in docs/gpu-phase-qm-native-9200.md:

* **Start**: `qm start <vmid>` or the GUI *Start* button. L1 boots and `w10-l2.service` starts the Windows L2 with the GPU.
* **Stop**: `qm shutdown <vmid>` or the GUI **Shutdown** button. L1 runs `w10-l2.service`'s `ExecStop`
  (`l2-service.sh stop`: ACPI `system_powerdown` to Windows over QMP, waits up to 150 s), then powers off; PVE waits
  up to `startup: down=240` s. Host shutdown/reboot uses the same path.
* **Never `qm stop` / GUI *Stop*** except as a last resort: it is a hard power cut of L1 **and** the Windows L2 inside it
  (no Windows shutdown, so NTFS damage is possible and Windows may run a disk check on the next boot).
* Only Windows: `systemctl stop w10-l2` / `systemctl start w10-l2` inside L1.

Timeout chain: L2 ACPI wait 150 s (`L2_STOP_WAIT`) < `TimeoutStopSec=180` of `w10-l2.service` < `startup: down=240`
(`l1.shutdown_timeout`, minimum 200). Difference from 9200: setup's L1 keeps `agent: 1` (it needs the guest agent for
IP discovery and SSH host-key pinning), so `qm shutdown` asks the agent to power off instead of sending ACPI. Both end
in a systemd poweroff that runs the same `ExecStop`; the agent path is **untested**.

**Never touched:** host packages, kernel, kernel command line, modprobe/modules config, `/usr`, `/etc/pve/storage.cfg`,
other VMs (not even stopped ones), the host's `/opt/qemu-ad` (only read), the host network config.

## Rollback / uninstall

```bash
./setup.sh uninstall --dry-run    # prints the exact plan
./setup.sh uninstall              # asks you to type the VMID (or --yes)
```

* The plan comes only from the manifest. A VM is destroyed only if its description still has the install marker
  (a reused VMID is never touched, not even with `--force`). A running L1 gets `qm shutdown --timeout <l1.shutdown_timeout> --forceStop 1`
  first (L1 shuts the L2 down via ACPI through `w10-l2.service`; the force stop happens only after the timeout).
* Files that changed since setup wrote them are skipped unless `--force`.
* If anything fails, the manifest is kept, so `uninstall` can be re-run.
* `qm destroy … --purge` also removes the VM from backup jobs/HA/replication, which is what a full rollback wants. The Windows disk is
  destroyed with it; back it up first if you want to keep it (`vzdump <vmid>`).
* Partial install: run `uninstall` at any point; whatever was recorded is removed.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| Preflight `GPU in use` FAIL | `qm shutdown <vmid>` of the listed VM (setup never stops VMs for you). Only one VM can use the GPU at a time. |
| Preflight `GPU on vfio-pci` FAIL | A GPU function is on a host driver (or none). If it is the display function and the host uses it (`nvidia`/`amdgpu`/`nouveau`), pick another GPU. Otherwise, any of: start and **shut down** once a VM that has the GPU as `hostpciN` (qm binds it and leaves it on vfio-pci); `echo vfio-pci > /sys/bus/pci/devices/<bdf>/driver_override` + unbind + `drivers_probe` (runtime only); or your own `vfio-pci ids=` modprobe config. setup.sh does none of these for you. |
| Preflight `GPU-guard hookscript` FAIL | No storage has `snippets` content. Enable it yourself (Datacenter → Storage → local → Content → Snippets) and re-run, or `--set l1.hookscript=no` (WARN: then nothing stops a `hostpci` VM from grabbing the GPU while L1 runs). |
| `qm start` refused with `<vmid>-gpu-guard: …` | The task log says which function is not on vfio-pci, or which VM holds the reservation. Shut that VM down (Shutdown, not Stop). |
| `vm_start` fails with a vfio error | `journalctl -u pvedaemon`/the task log; check `readlink /sys/bus/pci/devices/<bdf>/driver` for every GPU function. The same config shape boots 9200 in the lab (docs/gpu-phase-qm-native-9200.md); fallback: `tools/gen-launch.py`. |
| L2 does not start after L1 boots | In L1: `systemctl status w10-l2`, `journalctl -u w10-l2`, `/root/w10/l2-service.log`. |
| `l1_ip` times out | `qm terminal <vmid>` (serial console) to watch cloud-init; check DHCP on `l1.bridge` or set `l1.ip`/`l1.gateway`. |
| `l1_dkms` fails | `ssh -i /var/lib/qemu-ad/setup/ssh/id_ed25519 root@<L1>`; log `/var/log/qemu-ad-setup/dkms.log`. Try `--set l1.kvm_source=upstream --redo l1_dkms`. |
| `l1_reboot` check fails | `qad-l1.sh check-kvm` in L1 prints `KVM_VERSION`, `KVM_FILE`, `DMAR`, GPU driver/group. |
| Windows install hangs | Watch over VNC (`ssh -L 5900:127.0.0.1:5900 …` to L1). Log `/var/log/qemu-ad-setup/l2-create.log`. Edition not found → set `l2.windows_edition` to the exact install.wim image name. Then `--wipe-l2-disk --redo l2_install`. |
| `verify` GPU Code 43 / no NVIDIA device | `w10-code43-run.sh` notes in docs/gpu-phase-windows-l2.md; check `-rtc base=localtime`, the VARS were built without the GPU, the driver was staged. |
| Resume after Ctrl-C / reboot | `./setup.sh install` again; finished steps are skipped. The Windows install keeps running inside L1 while setup is disconnected. |

Logs: host `/var/lib/qemu-ad/setup/logs/install-*.log` (secrets redacted); L1 `/var/log/qemu-ad-setup/<step>.log`.

## Defaults and assumptions

Assumptions (please review):

Decisions (Brandon's defaults, now built in):

* **One patched KVM package**: `dkms/` (`kvm-l1`, `l1-dkms-0.1`) is the canonical one; setup's L1 refuses to build it
  if another kvm DKMS package (e.g. the lab's `kvm-patched`) is registered. See
  [Aligning the lab's kvm-patched/1.0](#aligning-the-labs-kvm-patched10-to-dkms).
* **No `storage.cfg` changes**: snippets must already exist.
* **Windows key**: your own product key or none.
* **Isolated L2 network**: `brl2` in L1, no NAT/internet for the L2.
* **Sizes**: L1 12 GiB / 8 vCPU / 48 GiB disk; L2 6 GiB / 4 vCPU / 128 GiB.
  (Lab sample `samples/qm-native-9200/9200.conf.active-final` is smaller: L1 30G / L2 80G — that is a capture, not the setup.sh default.)
* **L1 `onboot: 0`**: not started with the host.

Assumptions:

1. **GPU via `args:`, not `hostpciN`**, exactly as 9200 (PR #24). `ich9-pcie-port-1` exists on every q35 VM
   (qemu-server's `pve-q35-4.0.cfg`). qm does not bind drivers for `args:` devices, so the GPU must already be on
   vfio-pci (preflight), and the #24 guard hookscript supplies the exclusivity.
2. **Snippets**: PVE's `local` storage does not have `snippets` content by default; `setup.sh` will not enable it.
3. **L1 image**: Debian 13 *generic* (standard kernel, like the lab's `6.12.x+deb13-amd64`), not *genericcloud*.
4. **Patched KVM**: the repo's `dkms/` package (`kvm-l1`, version string `l1-dkms-0.1`) built from the Debian
   `linux-source` of the running L1 kernel by default. setup's L1 sets `KVM_PATCH_RE='l1-dkms'`; `start-l2.sh`'s
   built-in default still also accepts the lab's `kvmpatch` until 9200 is realigned (below). The kernel is
   `apt-mark hold`-ed because `dkms.conf` has `AUTOINSTALL=no`.
5. **qemu-ad-pve**: copied read-only from the host's `/opt/qemu-ad` when present (exactly the lab method; PVE 9 and
   Debian 13 share the userland), else built in L1 with `qemu-ad-pve.sh build`. It has no SLIRP, so the L2 network is
   an isolated `brl2` bridge in L1 (`10.254.77.0/24`, dnsmasq with a fixed lease for the L2 MAC, **no NAT/internet**).
6. **L2 devices**: AHCI disk (`ide-hd` on `ide.1`) + `e1000e`, because qemu-ad-pve rewrites virtio vendor IDs;
   `-rtc base=localtime`; `X-PciMmio64Mb=65536`; `-cpu host`; OVMF VARS built in the no-GPU install run with a dummy
   `pcie-root-port,id=rpg,chassis=11,slot=1`, so the GPU run uses the same topology.
7. **Windows disk selection in L1** uses `resolve-windows-disk.sh` (serial `drive-scsi1`, then label/NTFS+size; an NTFS
   UUID is scored only if `WIN_DISK_UUID` is set, which setup.sh never does: the lab 9200 value lives in
   `scripts/l1-w10/qemu-ad-l2.env.lab-9200.example`; refuses
   mounted or ext4 disks, ambiguity fails closed). For the install only, `WIN_DISK_ALLOW_BLANK=1` also accepts a
   completely blank disk whose serial is exactly `drive-scsi1`.
8. **Autounattend**: wipes disk 0 of the L2 (the only disk the L2 sees), creates a local admin (random password unless
   set), no product key unless you give one (Setup may stop at the key page for some media; use `l2.autounattend=none`
   and VNC then). Windows 11 adds the LabConfig TPM/SecureBoot/RAM bypass (no vTPM; untested).
9. **Windows first logon** (`setup/l1/windows/firstlogon.ps1`): copies `\qad` to `C:\qad`, disables sleep, power button
   = shutdown (clean ACPI stop), enables OpenSSH (capability or staged zip) with the setup key, installs Python + wheels
   offline into `C:\qad\venv`, registers a one-shot task that installs the NVIDIA driver at the first boot that sees
   the GPU, then shuts down.
10. **Shutdown via the guest agent** (`agent: 1`, see [Use Shutdown, not Stop](#use-shutdown-not-stop)).

## Aligning the lab's kvm-patched/1.0 to dkms/

The lab L1 (9200) runs the older `kvm-patched/1.0` DKMS package (`6.12.111-kvmpatch1`, `patch_tag` on `kvm_amd`);
`dkms/` is now the single canonical package (`build_tag` `l1-dkms-0.1` on `kvm`). To move 9200 over (inside L1, with
a maintenance window; nothing on the PVE host changes):

```bash
systemctl stop w10-l2                         # clean Windows shutdown first
dkms status                                   # note the kvm-patched/1.0 entry
dkms remove -m kvm-patched -v 1.0 --all && mv /usr/src/kvm-patched-1.0 /root/kvm-patched-1.0.bak
# copy this repo to /root/qemu-ad-pve, then either (setup.env as written by setup.sh, l1.kvm_source=debian):
/root/qemu-ad-pve/setup/l1/qad-l1.sh dkms
# or by hand: stage the sources and run dkms/scripts/l1-dkms.sh (see dkms/README.md)
reboot
cat /sys/module/kvm/version                   # expect l1-dkms-0.1
modinfo -F filename kvm                       # expect …/updates/dkms/…
sed -i "s/^KVM_PATCH_RE=.*/KVM_PATCH_RE='l1-dkms'/" /etc/qemu-ad-l2.env   # add the line if missing
systemctl start w10-l2                        # start-l2.sh refuses to start if the patched KVM is not loaded
```

Rollback: `dkms remove -m kvm-l1 -v 0.1.0 --all`, `mv /root/kvm-patched-1.0.bak /usr/src/kvm-patched-1.0`,
`dkms install -m kvm-patched -v 1.0`, reboot, and put `kvmpatch` back into `KVM_PATCH_RE`. The tags differ:
kvm-patched exposes `patch_tag` on `kvm_amd`, dkms/ exposes `build_tag` on `kvm`. This procedure is **untested** on 9200.

## Relation to qm-native-9200 (PR #24)

PR #24 proved the plain `qm start/shutdown 9200` stack live. setup.sh reuses it instead of duplicating it:

| From #24 | Used by setup.sh as |
| --- | --- |
| `samples/qm-native-9200/9200.conf.active-final` VM shape | the `qm create` arguments and `args:` (a unit test asserts the generated `args:` equals the sample's apart from host BDFs) |
| `scripts/qm-native-9200/9200-gpu-guard.pl` | rendered to `qad-l1-<vmid>-gpu-guard.pl` (VMID + `@ids` only; rendering fails if the template changes shape) |
| `scripts/qm-native-9200/w10-l2.service`, `l2-service.sh` | installed in L1 (adapted only when the L1 GPU BDFs differ) |
| docs/gpu-phase-qm-native-9200.md | the Shutdown-not-Stop rules above |

PR #23 (this tool) contains #24 through a merge commit. Merge #24 first; #23's diff then shrinks to setup.sh's own
changes.

All settings (`setup/config.example.ini` has the same list with comments):

| Key | Default | Meaning |
| --- | --- | --- |
| `l1.vmid` | `auto` | VMID of the new L1 VM (auto = next free VMID from pvesh) (asked interactively) |
| `l1.name` | `qad-l1` | Name of the L1 VM (asked interactively) |
| `l1.storage` | `auto` | Storage for the L1 disks (needs content 'images') (asked interactively) |
| `l1.iso_storage` | `auto` | Storage for the cloud-init seed ISO (needs content 'iso') |
| `l1.bridge` | `vmbr0` | Host bridge for the L1 NIC (L1 needs internet for apt/DKMS) (asked interactively). Linux bridges and Open vSwitch bridges are both detected (sysfs, `ovs-vsctl list-br`, `ovs_type OVSBridge` in `/etc/network/interfaces` + `ip link`) |
| `l1.memory_mb` | `12288` | L1 RAM in MiB (must hold the L2 RAM plus ~4 GiB) (asked interactively) |
| `l1.cores` | `8` | L1 vCPUs (asked interactively) |
| `l1.disk_gb` | `48` | L1 root disk size in GiB (DKMS sources, QEMU, staging ISOs) |
| `l1.ip` | `dhcp` | L1 address: 'dhcp' or CIDR like 192.168.1.50/24 |
| `l1.gateway` | `(empty)` | Gateway when l1.ip is static |
| `l1.dns` | `(empty)` | DNS server when l1.ip is static (default: the gateway) |
| `l1.debian_image_url` | `https://cloud.debian.org/images/cloud...` | Debian 13 *generic* cloud image (standard kernel; genericcloud's cloud kernel is untested) |
| `l1.debian_image` | `(empty)` | Use this local qcow2 instead of downloading (path on the PVE host) |
| `l1.hold_kernel` | `yes` | apt-mark hold the L1 kernel (DKMS AUTOINSTALL is off in dkms/) |
| `l1.kvm_source` | `debian` | Source for the patched KVM: debian (linux-source of the L1 kernel, like the lab build) or upstream (dkms/fetch-kvm-source.sh) |
| `l1.qemu_ad` | `auto` | qemu-ad-pve binary for L2: copy (host /opt/qemu-ad, read-only), build (qemu-ad-pve.sh build inside L1) or auto (copy if present on host, else build) |
| `l1.hookscript` | `auto` | Install the GPU-guard hookscript from scripts/qm-native-9200 (refuses start unless the GPU is on vfio-pci; reserves it via qemu-server so hostpci VMs are refused while L1 runs). auto = yes. no = unprotected (not recommended) |
| `l1.snippets_storage` | `auto` | Existing storage with content 'snippets' for the hookscript (setup.sh never changes storage.cfg) |
| `l1.smbios` | `asus-am5` | SMBIOS identity of the L1 (bare-metal look, `systemd-detect-virt` = none): asus-am5 \| none (QEMU/Proxmox defaults) |
| `l1.hide_hypervisor` | `yes` | Hide the hypervisor from the L1 (no CPUID hypervisor bit, kvm=off); nested KVM and the GPU keep working |
| `l1.onboot` | `no` | Start L1 when the host boots (GPU is then taken from other VMs) |
| `l1.shutdown_timeout` | `240` | startup down= : seconds `qm shutdown`/host shutdown wait for L1 (L2 ACPI wait 150 s < w10-l2.service TimeoutStopSec 180 s < this); minimum 200 |
| `gpu.slot` | `auto` | Host PCI slot of the GPU, e.g. 0000:01:00 (all functions are passed) (asked interactively) |
| `gpu.mmio64_mb` | `65536` | OVMF 64-bit MMIO aperture (X-PciMmio64Mb) for L1 and L2 |
| `l2.source` | `iso` | How to create the Windows L2: iso (install from a Windows ISO), image (existing qcow2/raw), none (L1 only) (asked interactively) |
| `l2.windows_iso` | `(empty)` | Windows ISO: PVE volid (local:iso/Win10.iso) or absolute path (asked interactively) |
| `l2.image` | `(empty)` | Existing Windows disk image (qcow2/raw) on the PVE host; must boot on SATA/AHCI (asked interactively) |
| `l2.disk_gb` | `128` | Windows disk size in GiB (iso source) (asked interactively) |
| `l2.memory_mb` | `6144` | L2 RAM in MiB (asked interactively) |
| `l2.cores` | `4` | L2 vCPUs |
| `l2.autounattend` | `generate` | generate (unattended install), none (interactive via VNC) or a path to your own autounattend.xml (asked interactively) |
| `l2.windows_version` | `10` | 10 or 11 (11 adds the TPM/SecureBoot setup bypass; untested) |
| `l2.windows_edition` | `auto` | Image name in install.wim (auto: 'Windows <ver> Pro') |
| `l2.product_key` | `(empty)` | Your own product key (empty = none; Setup may ask, see docs) (asked interactively) (secret, never saved) |
| `l2.admin_user` | `qad` | Local administrator created by autounattend |
| `l2.admin_password` | `(empty)` | Password for admin_user (empty = random, shown once at the end) (secret, never saved) |
| `l2.computer_name` | `QAD-L2` | Windows computer name |
| `l2.timezone` | `UTC` | Windows time zone id (e.g. 'Eastern Standard Time') |
| `l2.locale` | `en-US` | Windows UI/input locale |
| `l2.cpu` | `host,-hypervisor` | L2 -cpu value; `-hypervisor` clears CPUID leaf 1 ECX bit 31 so Windows reports HypervisorPresent=False (NVIDIA Code 0 + CUDA verified; plain `host` also gave Code 0) |
| `l2.net_cidr` | `10.254.77.0/24` | Isolated L1<->L2 network (no NAT, no internet for L2) |
| `l2.install_timeout_min` | `240` | Max minutes to wait for the Windows install/first boot |
| `l2.vnc` | `127.0.0.1:0` | VNC display of the L2 *inside L1* during install (reach it with ssh -L) |
| `stage.nvidia_driver` | `(empty)` | NVIDIA Windows driver .exe on the PVE host (installed at first GPU boot) (asked interactively) |
| `stage.python_installer` | `(empty)` | python-3.x-amd64.exe on the PVE host |
| `stage.wheelhouse` | `(empty)` | Directory of Windows wheels (*.whl, optional SHA256SUMS*) on the PVE host |
| `stage.openssh_zip` | `(empty)` | OpenSSH-Win64.zip (Win32-OpenSSH release) for offline sshd in L2 |
| `stage.extra_files` | `(empty)` | Comma-separated extra files copied to the staging ISO root |
| `stage.downloads` | `(empty)` | Only with --download-proprietary: 'url sha256 [name]' entries separated by ';'. Downloaded INSIDE L1, sha256-checked, put on the staging ISO |
| `verify.cuda` | `auto` | Run the PyTorch CUDA check in L2: auto (if torch was staged), yes, no |

## Tested vs untested

| Area | Status |
| --- | --- |
| Config parsing/validation, GPU/IOMMU/VM-reference parsing (lspci, sysfs, `qm list`, `pvesm status`, mappings, guest-agent JSON), preflight rules, `qm` command and `args:` generation, cloud-init, L1 env file, manifest + uninstall planning, autounattend XML well-formedness/escaping, step resume logic | unit-tested (`tests/setup`, CI on Python 3.9 and 3.13) |
| `setup.sh install --dry-run`, `preflight`, `uninstall --dry-run` | smoke-tested against stub `qm`/`pvesm`/`pvesh`/`lspci` and a fake sysfs |
| `resolve-windows-disk.sh` blank-disk mode and refusals | tested against stub `lsblk`/`udevadm`/`wipefs` |
| Rendering of #24's guard hookscript; adaptation of #24's `w10-l2.service`/`l2-service.sh` to other GPU BDFs | unit-tested (the bash function is extracted from `qad-l1.sh` and run) |
| All shell (setup.sh, setup/l1, scripts/l1-w10, scripts/qm-native-9200, dkms) | shellcheck clean; PowerShell files parse (pwsh parser only) |
| `qm start`/`qm shutdown` of this VM shape + guard hookscript + `w10-l2.service` | **proven live on 9200 (PR #24)**; untested as generated by setup.sh, with another VMID/GPU, and via the guest-agent shutdown path |
| cloud-init seed, guest-agent IP + host-key pinning | **untested** |
| `dkms/` (`kvm-l1`) build in a real L1, Debian `linux-source` staging, the kvm-patched → dkms/ realignment | **untested** (the lab used `kvm-patched/1.0`) |
| `qemu-ad-pve.sh build` inside L1 | **untested** (the `install` path it reuses is the tested one) |
| Windows unattended install, sendkey boot, OpenSSH/Python/NVIDIA offline installs, image source, Windows 11 | **untested** |
| Intel hosts | **untested** (lab: AMD 7950X) |
| Clean default install of `main` end to end on the lab host (2026-10-09, VM 9310 and 9320 on AMD 7950X + RTX 4080), `verify`, shutdown/start cycle, `audit` | **live-tested** (see docs/bare-metal-appearance.md) |
