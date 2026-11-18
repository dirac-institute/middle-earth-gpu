#!/bin/bash
# Container entrypoint: link this org's registration into the runner
# directory, clear any GPU lock this runner left behind, start the runner.
set -euo pipefail
source /opt/gpu-runner/gpu-lock-lib.sh

STATE=/runner-state
cd /home/runner
for f in .runner .credentials .credentials_rsaparams; do
    if [ ! -r "$STATE/$f" ]; then
        echo "FATAL: $STATE/$f is missing or unreadable." >&2
        echo "       Register this runner first: sudo ./register.sh ${RUNNER_ORG:-<org>} (DEPLOY.md)" >&2
        sleep 60   # don't spin: compose restarts the container
        exit 1
    fi
    ln -sf "$STATE/$f" "/home/runner/$f"
done

# Nothing can be running yet, so a lock in this runner's name is stale
# (container crashed or VM rebooted mid-job).
lock_release_if_mine

exec ./run.sh
