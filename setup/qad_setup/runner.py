"""Command execution with logging, secret redaction and --dry-run.

In dry-run mode every host-changing command and file write is printed (prefixed DRY)
and nothing is executed. Read-only probes (``probe``) still run so preflight can show
real data; they never change anything.
"""
from __future__ import annotations

import hashlib
import os
import shlex
import subprocess
import sys
import time
from typing import IO, Dict, List, Optional, Sequence

from . import ui


class CommandError(RuntimeError):
    def __init__(self, argv: Sequence[str], rc: int, output: str):
        super().__init__(f"command failed (rc={rc}): {shlex.join(list(argv))}\n{output[-2000:]}")
        self.rc = rc
        self.output = output


class Runner:
    def __init__(self, dry_run: bool = False, log_path: Optional[str] = None, verbose: bool = False):
        self.dry_run = dry_run
        self.verbose = verbose
        self.secrets: List[str] = []
        self.log: Optional[IO[str]] = None
        self.log_path = log_path
        self.changes: List[str] = []  # what a dry run would change (or a real run did)
        if log_path:
            self.open_log(log_path)

    def open_log(self, log_path: str) -> None:
        """Start logging to a file (never in dry-run). Called only once the user has confirmed."""
        self.log_path = log_path
        if self.dry_run:
            return
        os.makedirs(os.path.dirname(log_path), mode=0o700, exist_ok=True)
        self.log = open(log_path, "a", encoding="utf-8")
        os.chmod(log_path, 0o600)

    # ------------------------------------------------------------------ helpers
    def redact(self, text: str) -> str:
        for s in self.secrets:
            if s:
                text = text.replace(s, "***")
        return text

    def _log(self, text: str) -> None:
        if self.log:
            self.log.write(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {self.redact(text)}\n")
            self.log.flush()

    def note(self, text: str) -> None:
        self._log(text)

    # ------------------------------------------------------------------ commands
    def probe(self, argv: Sequence[str], timeout: int = 60, input_text: Optional[str] = None) -> subprocess.CompletedProcess:
        """Read-only command: runs even in dry-run. Never raises on non-zero rc."""
        self._log(f"probe: {shlex.join(list(argv))}")
        try:
            p = subprocess.run(list(argv), input=input_text, capture_output=True, text=True, timeout=timeout)
        except FileNotFoundError:
            return subprocess.CompletedProcess(list(argv), 127, "", f"{argv[0]}: not found")
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(list(argv), 124, "", "timeout")
        if self.verbose:
            self._log(f"  rc={p.returncode} out={p.stdout[-500:]!r} err={p.stderr[-500:]!r}")
        return p

    def run(self, argv: Sequence[str], desc: str = "", check: bool = True, timeout: Optional[int] = None,
            input_text: Optional[str] = None, stream: bool = False, change: bool = True,
            env: Optional[Dict[str, str]] = None, display: Optional[str] = None) -> subprocess.CompletedProcess:
        """Run a command that may change something. In dry-run it is only printed.

        ``display`` replaces the printed form (e.g. "[L1] qad-l1.sh dkms" instead of the long ssh argv)."""
        shown = self.redact(display or shlex.join(list(argv)))
        if self.dry_run:
            print(f"  {ui.c('DRY', 'magenta')} {shown}" + (f"   # {desc}" if desc else ""))
            if change:
                self.changes.append(shown)
            return subprocess.CompletedProcess(list(argv), 0, "", "")
        self._log(f"run: {shown}" + (f"  # {desc}" if desc else ""))
        if self.verbose:
            print(ui.c(f"    $ {shown}", "dim"))
        full_env = None
        if env:
            full_env = dict(os.environ)
            full_env.update(env)
        if stream:
            # Live output (long L1 steps), also teed into the log.
            proc = subprocess.Popen(list(argv), stdin=subprocess.PIPE if input_text is not None else None,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=full_env)
            if input_text is not None and proc.stdin:
                proc.stdin.write(input_text)
                proc.stdin.close()
            out_lines = []
            assert proc.stdout is not None
            for line in proc.stdout:
                line = self.redact(line.rstrip("\n"))
                out_lines.append(line)
                self._log(f"  | {line}")
                print(ui.c("    | ", "dim") + line)
            rc = proc.wait(timeout=timeout)
            out = "\n".join(out_lines)
            p = subprocess.CompletedProcess(list(argv), rc, out, "")
        else:
            try:
                p = subprocess.run(list(argv), input=input_text, capture_output=True, text=True, timeout=timeout,
                                   env=full_env)
            except subprocess.TimeoutExpired as exc:
                raise CommandError(argv, 124, f"timeout after {timeout}s: {exc}") from None
            self._log(f"  rc={p.returncode}\n  stdout: {p.stdout[-4000:]}\n  stderr: {p.stderr[-4000:]}")
        if change:
            self.changes.append(shown)
        if check and p.returncode != 0:
            raise CommandError(argv, p.returncode, self.redact((p.stdout or "") + (p.stderr or "")))
        return p

    # ------------------------------------------------------------------ files
    def write_file(self, path: str, content: str, mode: int = 0o644, desc: str = "") -> str:
        """Write (atomically) and return sha256. Dry-run prints the path and a preview."""
        digest = hashlib.sha256(content.encode()).hexdigest()
        if self.dry_run:
            print(f"  {ui.c('DRY', 'magenta')} write {path} (mode {oct(mode)}, {len(content)} bytes)"
                  + (f"   # {desc}" if desc else ""))
            if self.verbose:
                for line in self.redact(content).splitlines()[:40]:
                    print(ui.c(f"        {line}", "dim"))
            self.changes.append(f"write {path}")
            return digest
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.tmp.{os.getpid()}"
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
        self._log(f"wrote {path} sha256={digest}")
        self.changes.append(f"write {path}")
        return digest

    def mkdir(self, path: str, mode: int = 0o700) -> bool:
        """Create a directory; return True if it was created by this call (or would be)."""
        if os.path.isdir(path):
            return False
        if self.dry_run:
            print(f"  {ui.c('DRY', 'magenta')} mkdir -p {path}")
            self.changes.append(f"mkdir {path}")
            return True
        os.makedirs(path, mode=mode, exist_ok=True)
        self._log(f"mkdir {path}")
        return True


def sha256_file(path: str) -> Optional[str]:
    h = hashlib.sha256()
    try:
        with open(path, "rb") as fh:
            for chunk in iter(lambda: fh.read(1 << 20), b""):
                h.update(chunk)
    except OSError:
        return None
    return h.hexdigest()


def eprint(*a: object) -> None:
    print(*a, file=sys.stderr)
