"""Terminal output: colours (auto-off when not a TTY / NO_COLOR), tables, prompts."""
from __future__ import annotations

import os
import sys
from typing import Callable, List, Optional, Sequence

_COLOR = sys.stdout.isatty() and not os.environ.get("NO_COLOR") and os.environ.get("TERM") != "dumb"
CODES = {"red": "31", "green": "32", "yellow": "33", "blue": "34", "magenta": "35", "cyan": "36",
         "bold": "1", "dim": "2"}
STATUS_COLOR = {"PASS": "green", "OK": "green", "done": "green", "WARN": "yellow", "skipped": "yellow",
                "FAIL": "red", "failed": "red", "INFO": "cyan", "pending": "dim", "running": "blue",
                "DRY": "magenta"}


def set_color(enabled: bool) -> None:
    global _COLOR
    _COLOR = enabled


def c(text: str, color: str) -> str:
    if not _COLOR or color not in CODES:
        return text
    return f"\033[{CODES[color]}m{text}\033[0m"


def status(text: str) -> str:
    return c(text, STATUS_COLOR.get(text, "bold"))


def _visible_len(s: str) -> int:
    import re
    return len(re.sub(r"\033\[[0-9;]*m", "", s))


def table(headers: Sequence[str], rows: List[Sequence[str]], colorize_col: Optional[int] = None) -> str:
    rows = [[str(x) for x in r] for r in rows]
    widths = [len(h) for h in headers]
    for r in rows:
        for i, cell in enumerate(r):
            first = cell.split("\n")[0]
            widths[i] = min(max(widths[i], len(first)), 60 if i < len(headers) - 1 else 200)
    out = ["  ".join(c(h.ljust(widths[i]), "bold") for i, h in enumerate(headers))]
    out.append("  ".join("-" * w for w in widths))
    for r in rows:
        cells = []
        for i, cell in enumerate(r):
            text = cell if i == len(r) - 1 else cell.ljust(widths[i])
            if colorize_col is not None and i == colorize_col:
                text = status(cell) + " " * max(0, widths[i] - len(cell))
            cells.append(text)
        out.append("  ".join(cells).rstrip())
    return "\n".join(out)


def heading(text: str) -> None:
    print("\n" + c(f"== {text}", "bold"))


def info(text: str) -> None:
    print(c("  -> ", "cyan") + text)


def warn(text: str) -> None:
    print(c("  !! ", "yellow") + text, file=sys.stderr)


def error(text: str) -> None:
    print(c("  XX ", "red") + text, file=sys.stderr)


class Prompter:
    """Interactive questions. With assume_yes, every question returns its default."""

    def __init__(self, assume_yes: bool, interactive: Optional[bool] = None,
                 input_fn: Callable[[str], str] = input):
        self.assume_yes = assume_yes
        self.interactive = sys.stdin.isatty() if interactive is None else interactive
        self.input_fn = input_fn

    def ask(self, question: str, default: str, validate: Optional[Callable[[str], Optional[str]]] = None,
            secret: bool = False) -> str:
        if self.assume_yes or not self.interactive:
            return default
        while True:
            shown = ("(hidden)" if secret and default else default) or ""
            prompt = f"  {question} [{shown}]: " if shown else f"  {question}: "
            if secret:
                import getpass
                raw = getpass.getpass(prompt)
            else:
                raw = self.input_fn(prompt)
            val = raw.strip() or default
            problem = validate(val) if validate else None
            if problem is None:
                return val
            print(c(f"    {problem}", "red"))

    def confirm(self, question: str, default: bool = False) -> bool:
        if self.assume_yes:
            return True
        if not self.interactive:
            return default
        d = "Y/n" if default else "y/N"
        raw = self.input_fn(f"  {question} [{d}]: ").strip().lower()
        if not raw:
            return default
        return raw in ("y", "yes")

    def choose(self, question: str, options: List[str], default_index: int = 0) -> int:
        if self.assume_yes or not self.interactive:
            return default_index
        for i, o in enumerate(options, 1):
            print(f"    {i}) {o}")
        while True:
            raw = self.input_fn(f"  {question} [{default_index + 1}]: ").strip()
            if not raw:
                return default_index
            if raw.isdigit() and 1 <= int(raw) <= len(options):
                return int(raw) - 1
            print(c("    pick one of the numbers above", "red"))
