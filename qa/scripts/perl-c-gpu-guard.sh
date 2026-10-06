#!/usr/bin/env bash
# Syntax-check scripts/qm-native-9200/9200-gpu-guard.pl and a setup.sh-rendered copy.
# Uses stub PVE::QemuServer::* modules (not available off a PVE host).
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
stub=$(mktemp -d)
trap 'rm -rf "$stub"' EXIT
mkdir -p "$stub/PVE/QemuServer"
cat >"$stub/PVE/QemuServer/Helpers.pm" <<'PM'
package PVE::QemuServer::Helpers;
use Exporter qw(import);
our @EXPORT_OK = qw(vm_running_locally);
sub vm_running_locally { 0 }
1;
PM
cat >"$stub/PVE/QemuServer/PCI.pm" <<'PM'
package PVE::QemuServer::PCI;
use Exporter qw(import);
our @EXPORT_OK = qw(reserve_pci_usage remove_pci_reservation);
sub reserve_pci_usage { }
sub remove_pci_reservation { }
1;
PM
perl -I"$stub" -c "$root/scripts/qm-native-9200/9200-gpu-guard.pl"
export PYTHONPATH="${root}/setup${PYTHONPATH:+:${PYTHONPATH}}"
python3 - "$root" "$stub/guard-rendered.pl" <<'PY'
import sys
from pathlib import Path
from qad_setup import plan

class F:
    def __init__(self, bdf):
        self.bdf = bdf

class G:
    slot = "0000:01:00"
    functions = [F("0000:01:00.0"), F("0000:01:00.1")]

root = Path(sys.argv[1])
out = plan.hookscript((root / plan.GUARD_TEMPLATE).read_text(), "9301", G())
Path(sys.argv[2]).write_text(out)
PY
perl -I"$stub" -c "$stub/guard-rendered.pl"
