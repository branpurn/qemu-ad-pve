"""Resumable step state (/var/lib/qemu-ad/setup/state.json)."""
from __future__ import annotations

import json
import os
import time
from typing import Dict, Optional

DONE, FAILED, RUNNING, SKIPPED = "done", "failed", "running", "skipped"


class State:
    def __init__(self, path: str, data: Optional[dict] = None):
        self.path = path
        self.data = data or {"steps": {}, "facts": {}}

    @classmethod
    def load(cls, path: str) -> "State":
        try:
            with open(path, encoding="utf-8") as fh:
                return cls(path, json.load(fh))
        except FileNotFoundError:
            return cls(path)

    def save(self) -> None:
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(self.data, fh, indent=2, sort_keys=True)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)

    @property
    def steps(self) -> Dict[str, dict]:
        return self.data.setdefault("steps", {})

    @property
    def facts(self) -> Dict[str, str]:
        """Values discovered during install that later steps (and status/verify) need."""
        return self.data.setdefault("facts", {})

    def status(self, step: str) -> Optional[str]:
        return self.steps.get(step, {}).get("status")

    def is_done(self, step: str) -> bool:
        return self.status(step) in (DONE, SKIPPED)

    def mark(self, step: str, status: str, detail: str = "", persist: bool = True) -> None:
        self.steps[step] = {"status": status, "at": time.strftime("%Y-%m-%d %H:%M:%S %Z"), "detail": detail}
        if persist:
            self.save()

    def reset(self, step: str) -> None:
        self.steps.pop(step, None)
