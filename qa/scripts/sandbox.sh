#!/bin/bash
# Run a command with the whole real filesystem read-only; only /tmp (tmpfs) and $QA_WORK are writable.
# Usage: QA_WORK=/path/to/scratch sandbox.sh <command> [args...]   (needs bubblewrap)
: "${QA_WORK:?set QA_WORK to a scratch directory}"
mkdir -p "$QA_WORK"
exec bwrap --ro-bind / / --dev /dev --proc /proc --tmpfs /tmp --bind "$QA_WORK" "$QA_WORK" --unshare-pid --die-with-parent "$@"
