#!/usr/bin/env bash
# qemu-ad-pve one-command setup. Run as root ON the Proxmox VE host:
#
#   ./setup.sh                 # = ./setup.sh install (interactive, with defaults)
#   ./setup.sh preflight       # read-only checks
#   ./setup.sh install --config my.ini --yes
#   ./setup.sh --dry-run       # print every host change, execute nothing
#   ./setup.sh status | verify | uninstall
#
# The logic is Python 3 stdlib only (PVE ships python3); see setup/qad_setup/ and docs/SETUP.md.
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! command -v python3 >/dev/null 2>&1; then
  echo "setup.sh: python3 not found (it ships with Proxmox VE)" >&2
  exit 2
fi
if ! python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
  echo "setup.sh: needs python3 >= 3.9 (found $(python3 -V 2>&1))" >&2
  exit 2
fi
export PYTHONPATH="${here}/setup${PYTHONPATH:+:${PYTHONPATH}}"
export PYTHONDONTWRITEBYTECODE=1
exec python3 -m qad_setup "$@"
