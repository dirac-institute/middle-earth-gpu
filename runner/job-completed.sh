#!/bin/bash
# Runs after every job (ACTIONS_RUNNER_HOOK_JOB_COMPLETED), including failed
# and cancelled ones. Output appears in the job log as "Complete runner".
set -euo pipefail
source /opt/gpu-runner/gpu-lock-lib.sh
lock_release_if_mine
