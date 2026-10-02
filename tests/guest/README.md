# Guest-side checks

Scripts here run **inside a Windows test guest** (PowerShell 7 or 5.1). They do not hold any
host, VM, network or credential details; pass those in from the harness that calls them.

| Script | Purpose | Guest changes |
| --- | --- | --- |
| `vm-indicators.ps1` | Lists what the guest can see that reveals a VM (hypervisor flag, firmware strings, ACPI/PCI IDs, guest agent, paravirtual drivers, MAC OUI, hardware plausibility, timing probe). Prints `[LEAK]`/`[MASKED]`/`[INFO]`/`[ERROR]` per signal; a failed query is `[ERROR]`, never `[MASKED]`. `-Strict` exits 1 on any LEAK or ERROR. | None (read-only). |
| `capture-desktop.ps1` | Captures the logged-in console user's desktop to a PNG from a remote session. | Creates `-OutDir` and writes a helper `cap.ps1` (removed afterwards) and `desktop.png` (kept). Registers, runs and unregisters a one-shot scheduled task that runs `powershell.exe -ExecutionPolicy Bypass` on that helper only. |

Which leaks are expected depends on the guest image and QEMU configuration, so they are not listed here.
Both scripts must have their `param(...)` block as the first statement; run them as files (`pwsh -File`) or
pipe them without prepending code.
