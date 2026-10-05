# dkms/ - out-of-tree kvm + kvm-amd + kvm-intel for the nested L1 guest

Skeleton for building `kvm.ko`, `kvm-amd.ko` and `kvm-intel.ko` from a kernel source tag, plus local patches, against **one given kernel version**.

## Host impact: none

* **Target is the nested L1 guest kernel only** (VM 9200 today: Debian 13, `6.12.111+deb13-amd64`). The bare-metal PVE host keeps its stock kernel and stock `kvm`/`kvm-amd`; nothing here is ever installed or loaded there.
* `scripts/l1-dkms.sh` refuses to run if `/etc/pve` or `pveversion` exists, or if `systemd-detect-virt --vm` says it is not a VM (override only with `KVM_L1_FORCE=i-know-this-is-not-the-pve-host`).
* Everything this directory writes stays under `dkms/src/`, `dkms/build/` (both git-ignored), and, inside the L1 only, `/usr/src/kvm-l1-0.1.0` (symlink), `/var/lib/dkms/kvm-l1/` and `/lib/modules/<kver>/updates/dkms/`.
* The stock modules in `/lib/modules/<kver>/kernel/` are never modified. The DKMS copies sit in `updates/dkms/`, which depmod searches first (default `search` order in depmod.d(5); not re-verified by us), so removing them restores the stock ones.

## Layout

| File | Purpose |
| --- | --- |
| `fetch-kvm-source.sh <kver>` | Shallow-fetch tag `v<kver>`, copy `arch/x86/kvm` and `virt/kvm` to `src/<kver>/`, record `SOURCE-INFO` (repo, tag, commit, date) and `SOURCE-SHA256SUMS` (sha256 of every file). `--verify` re-checks offline. |
| `patches/*.patch` | `-p1` patches applied to the staged copy, in name order. Shipped: `0001-kvm-add-build-tag-and-module-version.patch` (benign: `MODULE_VERSION("l1-dkms-0.1")` and a read-only `build_tag` parameter on `kvm.ko`). |
| `scripts/stage.sh` | Verify sums, copy to `build/`, apply patches, point `arch/x86/kvm/Makefile` at the copy. |
| `Makefile` | `make KVER=<release> [KDIR=...]`: stage + kbuild (`M=`) of the three modules. |
| `dkms.conf` | DKMS package `kvm-l1/0.1.0`, installs to `updates/dkms`, `AUTOINSTALL="no"`. |
| `scripts/l1-dkms.sh` | `install` / `uninstall` / `status`, with the host guard above. |

## Use (inside the L1 guest)

```
sudo apt install dkms build-essential pahole linux-headers-$(uname -r)   # pahole: kernel BTF step
./fetch-kvm-source.sh 6.12.111           # <kver> = UPSTREAM version, not the distro release string
sudo scripts/l1-dkms.sh install          # dkms add/build/install, loads nothing
# stop every L2 guest, then:
sudo modprobe -r kvm_amd kvm && sudo modprobe kvm_amd    # or reboot the L1
cat /sys/module/kvm/version /sys/module/kvm/parameters/build_tag   # l1-dkms-0.1 / example
modinfo -F filename kvm                  # expect .../updates/dkms/kvm.ko*
```

Without DKMS, `make KVER=... KDIR=...` alone just builds into `build/arch/x86/kvm/` (nothing installed).

`<kver>` mapping: Debian's `6.12.111+deb13-amd64` is upstream `6.12.111` plus Debian patches, so mainline/stable source is close but not byte-identical to what Debian built; any difference in `arch/x86/kvm`/`virt/kvm` is a risk (compare the Debian source package before trusting a build). A Proxmox kernel (`7.0.x-pve`, Ubuntu-derived) needs its own source (`pve-kernel.git`), not a mainline tag: the fetch script is not yet able to do that (TODO).

## Signing / Secure Boot (MOK)

Only relevant if the L1 boots with Secure Boot (VM 9200 currently does not use OVMF Secure Boot: not verified for the current VM config).

* The Debian kernel has `CONFIG_MODULE_SIG=y` (confirmed in the 6.12.111 headers' `.config`). With Secure Boot / lockdown on, an unsigned `kvm.ko` is rejected and the L1 loses KVM (its L2 guests, including the GPU one, will not start).
* DKMS signs modules automatically when it finds a key pair: default `/var/lib/dkms/mok.key` + `/var/lib/dkms/mok.pub` (Debian creates it on first use) or `mok_signing_key` / `mok_certificate` in `/etc/dkms/framework.conf`.
* Enroll the public key: `sudo mokutil --import /var/lib/dkms/mok.pub`, set a one-time password, reboot the **L1** and confirm in the MOK manager on the L1's console (VNC/serial of the L1; no host console needed).
* Check: `mokutil --sb-state`, `mokutil --test-key /var/lib/dkms/mok.pub`, `modinfo kvm | grep -E 'signer|sig_key'`.
* Keep the private key in the L1 only, never commit it.

## Rollback

1. `sudo scripts/l1-dkms.sh uninstall` (`dkms remove --all`, delete the `/usr/src` symlink, `depmod -a`).
2. Stop all L2 guests, `sudo modprobe -r kvm_amd kvm && sudo modprobe kvm_amd` (or reboot the L1) to run the stock modules again.
3. If the L1 will not boot to a working KVM: boot its previous kernel entry, or restore the L1's cold snapshot (take one before `install`; never snapshot the L1 with RAM while an L2 runs, per `docs/feasibility.md` 5.1). Removing `/lib/modules/<kver>/updates/dkms/` by hand plus `depmod -a` has the same effect.
4. Nothing on the PVE host needs reverting, because nothing was changed there.

## Verification status

* `fetch-kvm-source.sh 6.12.111` run for real against `github.com/gregkh/linux`: 105 files, commit `e2acc2211022` (tag `v6.12.111`), `--verify` OK.
* The patch applies to v6.12.111 and the three modules **compile and link** against the unmodified Debian `linux-headers-6.12.111+deb13-amd64` (+ common + kbuild packages, gcc 14, pahole 1.30), `vermagic=6.12.111+deb13-amd64`, `version=l1-dkms-0.1`, `parm: build_tag`. The build was done as an ordinary user on the Grok Bot box, not inside VM 9200.
* **Not done:** `dkms add/build/install` itself, module signing, loading/unloading the modules, running an L2 with them, other kernel versions, `AUTOINSTALL`, Proxmox kernels, a rebase of `0001` onto other tags.
* The shell scripts are `shellcheck`-clean (CI runs it on every push).
