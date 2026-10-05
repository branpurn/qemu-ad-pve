#!/usr/bin/env python3
"""Tiny QMP client (stdlib only) used inside L1 for the Windows L2.

    qad-qmp.py SOCK status                 -> prints the run state (running, paused, ...)
    qad-qmp.py SOCK powerdown              -> ACPI power button (clean Windows shutdown)
    qad-qmp.py SOCK quit                   -> hard stop of QEMU (last resort)
    qad-qmp.py SOCK sendkey KEY [N] [SEC]  -> press KEY N times, SEC apart (e.g. "ret" to get past
                                              "Press any key to boot from CD or DVD")
Exit status 0 on success, 2 if the socket is not there / not answering.
"""
import json
import socket
import sys
import time


class Qmp:
    def __init__(self, path, timeout=10.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = b""
        self._recv()  # greeting
        self.cmd("qmp_capabilities")

    def _recv(self):
        while b"\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("QMP socket closed")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\n", 1)
        return json.loads(line)

    def cmd(self, name, **args):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        self.sock.sendall(json.dumps(msg).encode() + b"\n")
        while True:
            r = self._recv()
            if "return" in r or "error" in r:
                if "error" in r:
                    raise RuntimeError(r["error"].get("desc", str(r["error"])))
                return r["return"]
            # asynchronous events are skipped


def connect(path, retries=1):
    last = None
    for _ in range(max(1, retries)):
        try:
            return Qmp(path)
        except OSError as exc:
            last = exc
            time.sleep(1)
    raise last


def main(argv):
    if len(argv) < 3:
        print(__doc__, file=sys.stderr)
        return 64
    path, op = argv[1], argv[2]
    try:
        q = connect(path, retries=30 if op == "sendkey" else 1)
    except OSError as exc:
        print(f"qmp: cannot connect to {path}: {exc}", file=sys.stderr)
        return 2
    try:
        if op == "status":
            print(q.cmd("query-status").get("status", "unknown"))
        elif op == "powerdown":
            q.cmd("system_powerdown")
        elif op == "quit":
            try:
                q.cmd("quit")
            except ConnectionError:
                pass
        elif op == "sendkey":
            key = argv[3] if len(argv) > 3 else "ret"
            count = int(argv[4]) if len(argv) > 4 else 1
            gap = float(argv[5]) if len(argv) > 5 else 1.0
            for _ in range(count):
                q.cmd("send-key", keys=[{"type": "qcode", "data": key}])
                time.sleep(gap)
        else:
            print(f"qmp: unknown op {op}", file=sys.stderr)
            return 64
    except (ConnectionError, OSError) as exc:
        print(f"qmp: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
