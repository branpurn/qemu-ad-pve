"""Scripts that run in L1 under `set -o pipefail` must not use `cmd | grep -q`.

grep -q exits at the first match; if the writer still has output to flush it dies of SIGPIPE
(rc 141) and pipefail turns a *match* into a failure. Live E2E 2026-10-06: `lsmod | grep -q
"^kvm_amd "` (lsmod output 4.6 KB > one stdio buffer) made `qad-l1.sh check-kvm` report
CHECK_KVM=FAIL on a correct L1 every time. Match on captured output (`grep -q x <<<"$(cmd)"`).
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[2]
GLOBS = ["setup/l1/*.sh", "scripts/l1-w10/*.sh", "scripts/qm-native-9200/*.sh"]
PIPE_GREP_Q = re.compile(r"\|\s*grep\s+(-[A-Za-z]*q[A-Za-z]*|--quiet)\b")


def _pipefail_scripts():
    for g in GLOBS:
        for p in sorted(ROOT.glob(g)):
            text = p.read_text()
            if "pipefail" in text:
                yield p, text


def test_globs_find_scripts():
    assert len(list(_pipefail_scripts())) >= 5


def test_no_pipe_into_grep_q_under_pipefail():
    hits = []
    for p, text in _pipefail_scripts():
        for n, line in enumerate(text.splitlines(), 1):
            code = line.split(" #", 1)[0]
            if code.lstrip().startswith("#"):
                continue
            if PIPE_GREP_Q.search(code):
                hits.append(f"{p.relative_to(ROOT)}:{n}: {line.strip()}")
    assert not hits, "SIGPIPE-prone `| grep -q` under pipefail:\n" + "\n".join(hits)
