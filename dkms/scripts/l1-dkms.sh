#!/usr/bin/env bash
# l1-dkms.sh install|uninstall|status
# Register / remove the kvm-l1 DKMS package. Runs only inside the nested L1
# guest. Refuses on a Proxmox host or on bare metal, so the PVE host's stock
# kernel modules cannot be touched by accident.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
name=kvm-l1
version=0.1.0
usrsrc="/usr/src/$name-$version"

guard() {
    if [ "${KVM_L1_FORCE:-}" = "i-know-this-is-not-the-pve-host" ]; then
        return 0
    fi
    if [ -d /etc/pve ] || command -v pveversion >/dev/null 2>&1; then
        echo "refusing: this looks like a Proxmox VE host (/etc/pve or pveversion present)." >&2
        echo "This DKMS package is for the nested L1 guest only." >&2
        exit 3
    fi
    if command -v systemd-detect-virt >/dev/null 2>&1 && ! systemd-detect-virt --quiet --vm; then
        echo "refusing: not running inside a VM (systemd-detect-virt --vm failed)." >&2
        exit 3
    fi
}

run() { echo "+ $*"; "$@"; }

case "${1:-}" in
    status)
        dkms status "$name" || true
        for m in kvm kvm_amd kvm_intel; do
            printf '%s: ' "$m"
            modinfo -F filename "$m" 2>/dev/null || echo "not found"
        done
        ;;
    install)
        guard
        [ "$(id -u)" -eq 0 ] || { echo "needs root (inside the L1)" >&2; exit 1; }
        run ln -sfn "$here" "$usrsrc"
        run dkms add "$name/$version"
        run dkms build "$name/$version"
        run dkms install "$name/$version"
        echo "Installed to /lib/modules/$(uname -r)/updates/dkms. Nothing is loaded yet:"
        echo "stop all L2 guests, then 'modprobe -r kvm_amd kvm && modprobe kvm_amd', or reboot the L1."
        ;;
    uninstall)
        guard
        [ "$(id -u)" -eq 0 ] || { echo "needs root (inside the L1)" >&2; exit 1; }
        run dkms remove "$name/$version" --all || true
        run rm -f "$usrsrc"
        run depmod -a
        echo "Removed. Reload the stock modules: stop all L2 guests, 'modprobe -r kvm_amd kvm && modprobe kvm_amd', or reboot the L1."
        ;;
    *)
        echo "usage: $0 install|uninstall|status" >&2
        exit 2
        ;;
esac
