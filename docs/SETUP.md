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

## Quickstart

```bash
# on the PVE node, as root
git clone https://github.com/branpurn/qemu-ad-pve && cd qemu-ad-pve
./setup.sh preflight          # read-only: PASS/WARN/FAIL table with fixes
./setup.sh --dry-run          # prints every host change and every L1 command, executes nothing
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
* A storage with `snippets` content for the hookscript (see [Assumptions](#defaults-and-assumptions)); without it, preflight FAILs if the GPU is not already on `vfio-pci`.

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
   | `hookscript` | host | `qad-l1-<vmid>-hook.sh` in the snippets storage (pre-start: refuse if another running VM uses the GPU; bind functions to vfio-pci like qm does for hostpci; refuse if the host uses the display function) |
   | `vm_create` | host | `qm create` (see below) + `qm disk resize` + Windows disk + Windows ISO as `ide0` |
   | `vm_start` | host | `qm start <vmid>` (re-checks that no running VM uses the GPU) |
   | `l1_ip` | host | IP via `qm guest cmd network-get-interfaces`; L1's SSH host key read through the guest agent and pinned (no trust-on-first-use) |
   | `l1_ssh` | L1 | wait for SSH and `cloud-init status --wait` |
   | `l1_push` | L1 | copy `dkms/`, `scripts/l1-w10/`, `setup/l1/`, `tests/w10-code43-*`, `qemu-ad-pve.sh` to `/root/qemu-ad-pve`; write `/etc/qemu-ad/setup.env` |
   | `l1_packages` | L1 | kernel + headers, dkms, build tools, ovmf, dnsmasq-base, genisoimage, …; reboots L1 if a newer kernel was installed; `apt-mark hold` the kernel |
   | `l1_dkms` | L1 | patched KVM via `dkms/` (`l1.kvm_source=debian`: `arch/x86/kvm` + `virt/kvm` from the matching Debian `linux-source`, like the lab build; `upstream`: `dkms/fetch-kvm-source.sh`), modules-load, check that `modinfo kvm` resolves to `updates/dkms` |
   | `l1_qemu_ad` | L1 | `copy`: read-only `tar` of the host's `/opt/qemu-ad` into L1 (the lab method, docs/gpu-phase-patched-kvm-l1.md); `build`: `qemu-ad-pve.sh build` in L1 (new subcommand: deps, fetch, patch, build; no divert/wrapper) |
   | `l1_vfio` | L1 | `vfio-pci ids=<GPU ids>` + softdeps, initramfs |
   | `l1_scripts` | L1 | `/root/w10` (start-l2.sh, resolve-windows-disk.sh, stop-l2.sh, l2net-up/down.sh, qad-qmp.py), `OVMF_CODE.fd`, `/etc/qemu-ad-l2.env`, `qemu-ad-l2.service` (installed, not enabled yet) |
   | `l1_reboot` | L1 | reboot and prove: kvm version matches the patched build, from `updates/dkms`, DMAR present, GPU on vfio-pci |
   | `l2_stage` | L1 | `stage.iso` (label QADSTAGE: `\qad\firstlogon.ps1`, `gpu-driver.ps1`, your files, `authorized_keys`) and `autounattend.iso` |
   | `l2_install` | L1 | Windows install/first boot **without the GPU** under qemu-ad-pve (systemd-run unit `qemu-ad-l2-install`, survives a disconnect); builds `VARS.fd` without the GPU. Progress is polled; the VNC hint (`ssh -L` to L1, display on 127.0.0.1 only) is printed |
   | `l2_enable` | L1 | delete `autounattend.iso` (holds the password), enable + start `qemu-ad-l2.service` (GPU) |
   | `verify` | L1→L2 | patched KVM, L2 running, GPU `ConfigManagerErrorCode` 0 over SSH into Windows, optional PyTorch CUDA check |

5. **Summary**: colourised step table, the generated Windows admin password (printed once; also root-only in
   `L1:/etc/qemu-ad/l2-secrets`), the SSH command for L1 and the log path.

Other subcommands:

* `./setup.sh status`: what the manifest lists, step states, `qm status`, and `qad-l1.sh status` from L1 (patched KVM, L2 state).
* `./setup.sh verify`: re-runs the L1/L2 checks; PASS/FAIL table; exit code 0 only on PASS.
* `./setup.sh uninstall [--dry-run] [--force]`: see [Rollback](#rollback--uninstall).

## Exactly what changes on the host

| Change | How it is removed |
| --- | --- |
| VM `<vmid>` (tag `qemu-ad-pve`, description starts with `qemu-ad-pve-setup:<install-id>`), its EFI disk, L1 disk (`scsi0`, imported from the Debian image) and Windows disk (`scsi1`, new or imported from your image) | `qm destroy <vmid> --purge 1 --destroy-unreferenced-disks 1`, **only if the marker is still in the description** |
| `<iso-storage>:iso/qad-l1-<vmid>-seed.iso` | `pvesm free`, only if unchanged (sha256) |
| `<snippets-storage>:snippets/qad-l1-<vmid>-hook.sh` (if a snippets storage exists) | `pvesm free`, only if unchanged |
| `/var/lib/qemu-ad/manifest.json`, `/var/lib/qemu-ad/setup/` (state.json, config.ini *without secrets*, logs, ssh key + pinned known_hosts, Debian image cache) | `rm` of the listed files (sha256-checked where recorded), then `rmdir` of directories setup created, only if empty |

The VM config itself carries `args:` with `-fw_cfg name=opt/ovmf/X-PciMmio64Mb,string=65536` and the GPU topology
(`pcie-pci-bridge,id=gpubr,bus=ich9-pcie-port-1` + one `vfio-pci,host=…,bus=gpubr,addr=0x1.N` per function, the
first with `multifunction=on`), `machine: q35,viommu=intel` (qm then emits `intel-iommu,intremap=on,caching-mode=on`
and `kernel-irqchip=split`), `bios: ovmf`, `efidisk0: …,efitype=4m,pre-enrolled-keys=0` (Secure Boot off, so the
unsigned DKMS modules load), `cpu: host`, `balloon: 0`, `scsihw: virtio-scsi-single`, `agent: 1`, `serial0: socket`,
`onboot: 0` (configurable), `startup: down=300`.

**Never touched:** host packages, kernel, kernel command line, modprobe/modules config, `/usr`, `/etc/pve/storage.cfg`,
other VMs (not even stopped ones), the host's `/opt/qemu-ad` (only read), the host network config.

## Rollback / uninstall

```bash
./setup.sh uninstall --dry-run    # prints the exact plan
./setup.sh uninstall              # asks you to type the VMID (or --yes)
```

* The plan comes only from the manifest. A VM is destroyed only if its description still has the install marker
  (a reused VMID is never touched, not even with `--force`). A running L1 gets `qm shutdown --timeout <l1.shutdown_timeout> --forceStop 1`
  first (L1 shuts the L2 down via ACPI through `qemu-ad-l2.service`).
* Files that changed since setup wrote them are skipped unless `--force`.
* If anything fails, the manifest is kept, so `uninstall` can be re-run.
* `qm destroy … --purge` also removes the VM from backup jobs/HA/replication, which is what a full rollback wants. The Windows disk is
  destroyed with it; back it up first if you want to keep it (`vzdump <vmid>`).
* Partial install: run `uninstall` at any point; whatever was recorded is removed.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| Preflight `GPU in use` FAIL | `qm shutdown <vmid>` of the listed VM (setup never stops VMs for you). Only one VM can use the GPU at a time. |
| Preflight `GPU host driver` FAIL | The host itself drives the display function (e.g. `nvidia`/`amdgpu`/`nouveau`). Bind it to `vfio-pci` yourself or pick another GPU. |
| Preflight `Hookscript` FAIL | No storage has `snippets` content and the GPU is not on `vfio-pci`. Enable snippets (Datacenter → Storage → local → Content) and re-run. |
| `vm_start` fails with a vfio error | `journalctl -u pvedaemon`/the task log; check `readlink /sys/bus/pci/devices/<bdf>/driver` for every GPU function, and the hookscript output in the task log. `qm start` with the GPU only in `args:` is the main **untested** assumption (the lab started L1 from a generated script, see docs/gpu-phase-gen-launch-e2e.md); fallback: `tools/gen-launch.py`. |
| `l1_ip` times out | `qm terminal <vmid>` (serial console) to watch cloud-init; check DHCP on `l1.bridge` or set `l1.ip`/`l1.gateway`. |
| `l1_dkms` fails | `ssh -i /var/lib/qemu-ad/setup/ssh/id_ed25519 root@<L1>`; log `/var/log/qemu-ad-setup/dkms.log`. Try `--set l1.kvm_source=upstream --redo l1_dkms`. |
| `l1_reboot` check fails | `qad-l1.sh check-kvm` in L1 prints `KVM_VERSION`, `KVM_FILE`, `DMAR`, GPU driver/group. |
| Windows install hangs | Watch over VNC (`ssh -L 5900:127.0.0.1:5900 …` to L1). Log `/var/log/qemu-ad-setup/l2-create.log`. Edition not found → set `l2.windows_edition` to the exact install.wim image name. Then `--wipe-l2-disk --redo l2_install`. |
| `verify` GPU Code 43 / no NVIDIA device | `w10-code43-run.sh` notes in docs/gpu-phase-windows-l2.md; check `-rtc base=localtime`, the VARS were built without the GPU, the driver was staged. |
| Resume after Ctrl-C / reboot | `./setup.sh install` again; finished steps are skipped. The Windows install keeps running inside L1 while setup is disconnected. |

Logs: host `/var/lib/qemu-ad/setup/logs/install-*.log` (secrets redacted); L1 `/var/log/qemu-ad-setup/<step>.log`.

## Defaults and assumptions

Assumptions (please review):

1. **GPU via `args:`, not `hostpciN`** (qm-native topology fails with "group used in multiple address spaces",
   docs/gpu-phase-intel-viommu.md). `ich9-pcie-port-1` exists on every q35 VM (qemu-server's `pve-q35-4.0.cfg`).
   Because qm does not know about the device, the **hookscript** does what qm would do for hostpci (bind to vfio-pci) and
   adds a GPU-exclusivity guard. This is also the item another work stream (`qm start/shutdown 9200` drives the stack) is
   addressing; the two should be consolidated.
2. **Snippets**: PVE's `local` storage does not have `snippets` content by default. `setup.sh` will not enable it
   (that is a `storage.cfg` change outside the allowed host changes); it installs the hookscript only where snippets
   already exist.
3. **L1 image**: Debian 13 *generic* (standard kernel, like the lab's `6.12.x+deb13-amd64`), not *genericcloud*.
4. **Patched KVM**: the repo's `dkms/` package (`kvm-l1`, version string `l1-dkms-0.1`) built from the Debian
   `linux-source` of the running L1 kernel by default. The lab ran `kvm-patched/1.0` (`6.12.111-kvmpatch1`);
   the start guard accepts both (`KVM_PATCH_RE='l1-dkms|kvmpatch'`). The kernel is `apt-mark hold`-ed because
   `dkms.conf` has `AUTOINSTALL=no`.
5. **qemu-ad-pve**: copied read-only from the host's `/opt/qemu-ad` when present (exactly the lab method; PVE 9 and
   Debian 13 share the userland), else built in L1 with `qemu-ad-pve.sh build`. It has no SLIRP, so the L2 network is
   an isolated `brl2` bridge in L1 (`10.254.77.0/24`, dnsmasq with a fixed lease for the L2 MAC, **no NAT/internet**).
6. **L2 devices**: AHCI disk (`ide-hd` on `ide.1`) + `e1000e`, because qemu-ad-pve rewrites virtio vendor IDs;
   `-rtc base=localtime`; `X-PciMmio64Mb=65536`; `-cpu host`; OVMF VARS built in the no-GPU install run with a dummy
   `pcie-root-port,id=rpg,chassis=11,slot=1`, so the GPU run uses the same topology.
7. **Windows disk selection in L1** uses `resolve-windows-disk.sh` (serial `drive-scsi1`, then UUID/label; refuses
   mounted or ext4 disks, ambiguity fails closed). For the install only, `WIN_DISK_ALLOW_BLANK=1` also accepts a
   completely blank disk whose serial is exactly `drive-scsi1`.
8. **Autounattend**: wipes disk 0 of the L2 (the only disk the L2 sees), creates a local admin (random password unless
   set), no product key unless you give one (Setup may stop at the key page for some media; use `l2.autounattend=none`
   and VNC then). Windows 11 adds the LabConfig TPM/SecureBoot/RAM bypass (no vTPM; untested).
9. **Windows first logon** (`setup/l1/windows/firstlogon.ps1`): copies `\qad` to `C:\qad`, disables sleep, power button
   = shutdown (clean ACPI stop), enables OpenSSH (capability or staged zip) with the setup key, installs Python + wheels
   offline into `C:\qad\venv`, registers a one-shot task that installs the NVIDIA driver at the first boot that sees
   the GPU, then shuts down.
10. **L1 sizing**: 12 GiB / 8 vCPU / 48 GiB disk; L2 6 GiB / 4 vCPU / 128 GiB (lab values except disk sizes).

All settings (`setup/config.example.ini` has the same list with comments):

| Key | Default | Meaning |
| --- | --- | --- |
| `l1.vmid` | `auto` | VMID of the new L1 VM (auto = next free VMID from pvesh) (asked interactively) |
| `l1.name` | `qad-l1` | Name of the L1 VM (asked interactively) |
| `l1.storage` | `auto` | Storage for the L1 disks (needs content 'images') (asked interactively) |
| `l1.iso_storage` | `auto` | Storage for the cloud-init seed ISO (needs content 'iso') |
| `l1.bridge` | `vmbr0` | Host bridge for the L1 NIC (L1 needs internet for apt/DKMS) (asked interactively) |
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
| `l1.hookscript` | `auto` | Install a pre-start hookscript (GPU exclusivity + vfio-pci bind) into a snippets storage: auto/yes/no |
| `l1.snippets_storage` | `auto` | Storage with content 'snippets' for the hookscript |
| `l1.onboot` | `no` | Start L1 when the host boots (GPU is then taken from other VMs) |
| `l1.shutdown_timeout` | `300` | Seconds qm/host shutdown waits for L1 (L2 shuts down first) |
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
| `l2.cpu` | `host` | L2 -cpu value (plain host gave Code 0 in the lab) |
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
| All shell (setup.sh, setup/l1, hookscript, scripts/l1-w10, dkms) | shellcheck clean; PowerShell files parse (pwsh parser only) |
| `qm start` of an L1 with the GPU only in `args:` | **untested** (the lab used a generated launch script) |
| Hookscript on a real host | **untested** |
| cloud-init seed, guest-agent IP + host-key pinning | **untested** |
| `dkms/` (`kvm-l1`) build in a real L1, Debian `linux-source` staging | **untested** (the lab used `kvm-patched/1.0`) |
| `qemu-ad-pve.sh build` inside L1 | **untested** (the `install` path it reuses is the tested one) |
| Windows unattended install, sendkey boot, OpenSSH/Python/NVIDIA offline installs, image source, Windows 11 | **untested** |
| Intel hosts | **untested** (lab: AMD 7950X) |
