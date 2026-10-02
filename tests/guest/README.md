# Guest-side checks

Scripts here run **inside a Windows test guest** (PowerShell 7 or 5.1) and are read-only
unless stated. They do not hold any host, VM, network or credential details; pass those in
from the harness that calls them.

| Script | Purpose |
| --- | --- |
| `vm-indicators.ps1` | Lists what the guest can see that reveals a VM (hypervisor flag, firmware strings, ACPI/PCI IDs, guest agent, paravirtual drivers, MAC OUI, hardware plausibility, timing probe). Prints `[LEAK]`/`[MASKED]`/`[INFO]` per signal. `-Strict` makes any LEAK a non-zero exit. |
| `capture-desktop.ps1` | Captures the logged-in console user's desktop to a PNG from a remote session, using a short-lived scheduled task. Changes the guest only by creating then removing that task and writing the PNG. |

Expected leaks today are tracked in the PR description, not here, since they depend on the guest image and QEMU config.
