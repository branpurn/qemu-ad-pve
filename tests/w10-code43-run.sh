#!/usr/bin/env bash
# w10-code43-run.sh - run w10-code43-check.ps1 on a Windows 10 guest from a Linux machine.
#
# USAGE
#   w10-code43-run.sh <host> <user> [--key PATH] [--port 22] [--ssh-direct]
#
#   <host>         guest hostname / IP
#   <user>         Windows account name (e.g. Administrator)
#   --key PATH     private key file (key auth only). Omit to use ssh-agent / default keys.
#   --port N       SSH port (default 22)
#   --ssh-direct   don't use PSRemoting; scp the script to the guest's home dir and run
#                  `ssh user@host powershell -NoProfile -ExecutionPolicy Bypass -File ...`
#                  (use this when the OpenSSH server's default shell is cmd.exe or there is no
#                  `Subsystem powershell` line).
#   -h, --help     show this help
#
# Default mode = pwsh SSH remoting:
#   pwsh -NoProfile -Command  New-PSSession -HostName <host> -UserName <user> [-KeyFilePath <key>] -Port <port>
#   Invoke-Command -Session $s -FilePath <path to w10-code43-check.ps1> ; Remove-PSSession
#
# OUTPUT / EXIT CODE
#   JSON (pretty-printed via jq when available) goes to stdout; diagnostics go to stderr.
#   Invoke-Command does not return remote exit codes, so the exit code is derived from the
#   JSON 'result' field:  ok->0  code43->43  error_other->2  no_nvidia_device->3
#   Runner/transport failures: 1 (no valid JSON / connection failure), 64 usage error,
#   127 missing tool (pwsh / ssh / scp).
#
# ENVIRONMENT
#   W10_CHECK_PS1   path of the check script (default: w10-code43-check.ps1 in the same directory as this script)
#
# SECURITY: key auth / ssh-agent only. No password is accepted on the command line or stored.
#   BatchMode is requested so ssh never blocks on a password prompt.
#
# PREREQUISITES ON THE WINDOWS 10 GUEST (elevated PowerShell)
#   1. Install OpenSSH Server (Win10 1809+):
#        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
#        Set-Service sshd -StartupType Automatic; Start-Service sshd
#        (firewall rule 'OpenSSH-Server-In-TCP' for port 22 is normally created automatically)
#   2. Put your PUBLIC key in  C:\Users\<user>\.ssh\authorized_keys
#      (for Administrators group accounts: C:\ProgramData\ssh\administrators_authorized_keys, and
#       fix its ACL:  icacls <file> /inheritance:r /grant "SYSTEM:F" /grant "Administrators:F").
#      In C:\ProgramData\ssh\sshd_config make sure  PubkeyAuthentication yes  is set.
#   3. For PSRemoting over SSH (default mode) add this line to C:\ProgramData\ssh\sshd_config
#      (adjust the path if needed; the 8.3 'PROGRA~1' form avoids spaces):
#        Subsystem powershell c:/progra~1/powershell/7/pwsh.exe -sshs -NoLogo -NoProfile
#      (PowerShell 7 must be installed on the guest; Windows PowerShell 5.1 cannot be an SSH
#       remoting endpoint). Then:  Restart-Service sshd
#      With --ssh-direct only Windows PowerShell 5.1 is needed (no Subsystem line).
#   4. Optional: default shell for the OpenSSH server (registry HKLM:\SOFTWARE\OpenSSH, DefaultShell)
#      may be cmd.exe (the default) - fine for --ssh-direct, which works with either shell.
#   On the machine running this script: PowerShell 7 (`pwsh`) and an ssh client are required; jq is optional.
#
# EXAMPLES
#   w10-code43-run.sh win10-guest.example Administrator --key /path/to/private_key
#   w10-code43-run.sh win10-guest.example Administrator --port 2222 --ssh-direct

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1_FILE="${W10_CHECK_PS1:-$SCRIPT_DIR/w10-code43-check.ps1}"
REMOTE_NAME="w10-code43-check.ps1"   # copied to the remote user's home dir in --ssh-direct mode

usage() { sed -n '2,/^set -u/{/^set -u/d;s/^# \{0,1\}//;p}' "$0"; }
die()   { printf 'w10-code43-run: %s\n' "$1" >&2; exit "${2:-1}"; }

host="" user="" key="" port="22" direct=0
pos=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)     usage; exit 0 ;;
    --key)         [ $# -ge 2 ] || die "--key needs a path" 64; key="$2"; shift 2 ;;
    --key=*)       key="${1#--key=}"; shift ;;
    --port)        [ $# -ge 2 ] || die "--port needs a number" 64; port="$2"; shift 2 ;;
    --port=*)      port="${1#--port=}"; shift ;;
    --ssh-direct)  direct=1; shift ;;
    -*)            die "unknown option: $1 (see --help)" 64 ;;
    *)             pos+=("$1"); shift ;;
  esac
done
[ "${#pos[@]}" -eq 2 ] || { usage >&2; exit 64; }
host="${pos[0]}"; user="${pos[1]}"

case "$host" in -*|"") die "invalid host: '$host'" 64 ;; esac
case "$user" in -*|"") die "invalid user: '$user'" 64 ;; esac
case "$port" in ''|*[!0-9]*) die "invalid port: '$port'" 64 ;; esac
[ -r "$PS1_FILE" ] || die "check script not readable: $PS1_FILE"
if [ -n "$key" ]; then
  # expand a leading ~ (quoted args are not tilde-expanded by the caller's shell)
  # shellcheck disable=SC2088  # literal "~/" prefix is deliberately matched
  case "$key" in "~/"*) key="$HOME/${key#"~/"}" ;; esac
  [ -r "$key" ] || die "key file not readable: $key"
fi

raw="" rc=0

if [ "$direct" -eq 0 ]; then
  command -v pwsh >/dev/null 2>&1 || die "pwsh (PowerShell 7) is not installed on this machine; install it or use --ssh-direct" 127

  export W10_HOST="$host" W10_USER="$user" W10_PORT="$port" W10_KEY="$key" W10_SCRIPT="$PS1_FILE"
  # shellcheck disable=SC2016  # $-variables below are PowerShell, not bash
  pscmd='
$ErrorActionPreference = "Stop"
$sp = @{ HostName = $env:W10_HOST; UserName = $env:W10_USER; Port = [int]$env:W10_PORT }
if ($env:W10_KEY) { $sp.KeyFilePath = $env:W10_KEY }
# never block on a password prompt (the Options parameter exists in PowerShell 7.3+)
if ((Get-Command New-PSSession).Parameters.ContainsKey("Options")) {
    $sp.Options = @{ BatchMode = "yes"; ConnectTimeout = "20" }
}
$s = New-PSSession @sp
try {
    $out = Invoke-Command -Session $s -FilePath $env:W10_SCRIPT
} finally {
    Remove-PSSession -Session $s -ErrorAction SilentlyContinue
}
@($out) | ForEach-Object { [string]$_ }
'
  raw="$(pwsh -NoProfile -NonInteractive -Command "$pscmd")" || rc=$?
else
  command -v ssh >/dev/null 2>&1 || die "ssh client not found" 127
  command -v scp >/dev/null 2>&1 || die "scp not found" 127

  ssh_opts=(-o BatchMode=yes -o ConnectTimeout=20)
  [ -n "$key" ] && ssh_opts+=(-i "$key" -o IdentitiesOnly=yes)
  target="${user}@${host}"

  # 1) copy script into the remote user's home directory (works for cmd and PowerShell default shells)
  scp "${ssh_opts[@]}" -P "$port" -- "$PS1_FILE" "${target}:${REMOTE_NAME}" >&2 \
    || die "scp to ${target} failed" 1
  # 2) run it; stdout = JSON; ssh exit status = script exit code (unused: JSON 'result' is authoritative)
  raw="$(ssh "${ssh_opts[@]}" -p "$port" -- "$target" \
          powershell -NoProfile -ExecutionPolicy Bypass -File "$REMOTE_NAME")" || rc=$?
  # 3) best-effort cleanup; unquoted so it parses the same under cmd and PowerShell
  ssh "${ssh_opts[@]}" -p "$port" -- "$target" \
      powershell -NoProfile -Command Remove-Item -Force -ErrorAction SilentlyContinue "$REMOTE_NAME" \
      >/dev/null 2>&1 || true
fi

# Keep only the JSON document (drop any banner/noise before the first line starting with '{').
json="$(printf '%s\n' "$raw" | sed -n '/^[[:space:]]*{/,$p')"

result=""
if [ -n "$json" ]; then
  if command -v jq >/dev/null 2>&1; then
    result="$(printf '%s' "$json" | jq -r '.result // empty' 2>/dev/null)" || result=""
  elif command -v pwsh >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # PowerShell code, not bash
    result="$(printf '%s' "$json" | pwsh -NoProfile -NonInteractive -Command '$j = [Console]::In.ReadToEnd() | ConvertFrom-Json; $j.result' 2>/dev/null)" || result=""
  fi
fi

if [ -z "$result" ]; then
  [ -n "$raw" ] && printf '%s\n' "$raw"
  printf 'w10-code43-run: no valid JSON "result" in output (transport rc=%s)\n' "$rc" >&2
  exit 1
fi

if command -v jq >/dev/null 2>&1; then
  printf '%s' "$json" | jq . 2>/dev/null || printf '%s\n' "$json"
else
  printf '%s\n' "$json"
fi

case "$result" in
  ok)               exit 0 ;;
  code43)           exit 43 ;;
  error_other)      exit 2 ;;
  no_nvidia_device) exit 3 ;;
  *) printf 'w10-code43-run: unexpected result "%s"\n' "$result" >&2; exit 1 ;;
esac
