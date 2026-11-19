#!/bin/bash
# Runs before every job (ACTIONS_RUNNER_HOOK_JOB_STARTED). Output appears in
# the job log as "Set up runner". A non-zero exit fails the job.
#
# 1. Wait for the GPU lock (first come, first served between the two orgs).
# 2. Check the GPU is actually idle, so benchmarks never run on a dirty card.
# 3. Print and export the GPU's state, for the benchmark record.
set -euo pipefail
source /opt/gpu-runner/gpu-lock-lib.sh

MAX_WAIT="${GPU_LOCK_MAX_WAIT_SECONDS:-10800}"   # give up after 3 h
STALE="${GPU_LOCK_STALE_SECONDS:-86400}"         # another runner's lock older than 24 h is stale
# "Idle" means at most this much GPU memory in use. This is the only check
# that sees the other runner's container: nvidia-smi doesn't list processes
# from another PID namespace, but memory use is per GPU. Measured on the L4:
# idle is 0 MiB, and a CUDA process holds ~190 MiB before allocating anything.
IDLE_MAX_MIB="${GPU_IDLE_MAX_MIB:-64}"
IDLE_GRACE="${GPU_IDLE_GRACE_SECONDS:-60}"       # how long to wait for the GPU to go idle
POLL=30

# ── 1. Lock ────────────────────────────────────────────────────────────────
waited=0
until mkdir "$GPU_LOCK" 2>/dev/null; do
    owner="$(lock_owner)"
    if [ "$owner" = "$LOCK_OWNER" ]; then
        # This runner takes one job at a time, so a lock in its own name is
        # left over from a job whose completed hook never ran.
        echo "Reclaiming a stale lock left by this runner's previous job ($(lock_info))."
        break
    fi
    age="$(lock_age)"
    if [ "$age" -gt "$STALE" ]; then
        echo "::warning::GPU lock held by '${owner:-unknown}' for ${age}s (over ${STALE}s); treating it as stale. Held by: $(lock_info)"
        rm -rf "$GPU_LOCK"
        continue
    fi
    if [ "$waited" -ge "$MAX_WAIT" ]; then
        echo "::error::Gave up waiting for the GPU after ${waited}s. Held by '${owner:-unknown}': $(lock_info)"
        exit 1
    fi
    echo "GPU in use by '${owner:-unknown}' ($(lock_info)); waited ${waited}s so far..."
    sleep "$POLL"
    waited=$(( waited + POLL ))
done
lock_claim
echo "Acquired GPU lock as '$LOCK_OWNER' after waiting ${waited}s."

# From here on, any failure must release the lock before failing the job.
trap 'status=$?; if [ "$status" -ne 0 ]; then lock_release_if_mine; fi' EXIT

# ── 2. Idle check ──────────────────────────────────────────────────────────
command -v nvidia-smi >/dev/null \
    || { echo "::error::nvidia-smi not found in the container: the GPU is not attached (check compose.yaml devices and init.sh CDI)"; exit 1; }

gpu_busy() {
    local apps mem
    apps="$(nvidia-smi --query-compute-apps=pid --format=csv,noheader | grep -c . || true)"
    mem="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | sort -n | tail -n 1)"
    echo "  compute processes: ${apps:-0}, max memory used: ${mem:-?} MiB"
    [ "${apps:-0}" -gt 0 ] || [ "${mem:-0}" -gt "$IDLE_MAX_MIB" ]
}
idle_waited=0
while gpu_busy; do
    if [ "$idle_waited" -ge "$IDLE_GRACE" ]; then
        echo "::error::The GPU is not idle even though this runner holds the lock. Something outside the runners (or an orphaned process) is using it; not running a benchmark on a busy card."
        nvidia-smi || true
        exit 1
    fi
    sleep 10
    idle_waited=$(( idle_waited + 10 ))
done
echo "GPU is idle."

# ── 3. Record GPU state ────────────────────────────────────────────────────
nvidia-smi --query-gpu=name,driver_version,persistence_mode,clocks.sm,clocks.mem,clocks.max.sm,temperature.gpu,power.draw \
    --format=csv
# Available to every step of the job, so benchmarks can store them with results.
{
    echo "GPU_LOCK_OWNER=$LOCK_OWNER"
    echo "GPU_LOCK_WAIT_SECONDS=$waited"
    echo "GPU_DRIVER_VERSION=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader | head -n 1)"
} >> "$GITHUB_ENV"
