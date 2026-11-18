# Shared by the job hooks and the entrypoint. Sourced, not executed.
#
# The lock is a directory: mkdir is atomic, so only one runner container can
# create it, and unlike flock it outlives the hook process that took it.
# Inside it, `owner` names the runner (LOCK_OWNER, set per service in
# compose.yaml) and `info` says which job holds it.

GPU_LOCK="/gpu-lock/held"
: "${LOCK_OWNER:?LOCK_OWNER must be set in compose.yaml}"

lock_owner() { cat "$GPU_LOCK/owner" 2>/dev/null || true; }
lock_info()  { cat "$GPU_LOCK/info"  2>/dev/null || true; }

# Seconds since the lock was taken (or 0 if it doesn't exist).
lock_age() {
    local t
    t="$(stat -c %Y "$GPU_LOCK" 2>/dev/null)" || { echo 0; return; }
    echo $(( $(date +%s) - t ))
}

# Record that this runner holds the lock, for which job.
lock_claim() {
    touch "$GPU_LOCK"
    printf '%s\n' "$LOCK_OWNER" > "$GPU_LOCK/owner"
    printf '%s run %s job %s since %s\n' \
        "${GITHUB_REPOSITORY:-?}" "${GITHUB_RUN_ID:-?}" "${GITHUB_JOB:-?}" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$GPU_LOCK/info"
}

# Release the lock only if this runner holds it.
lock_release_if_mine() {
    if [ "$(lock_owner)" = "$LOCK_OWNER" ]; then
        rm -rf "$GPU_LOCK"
        echo "Released GPU lock held by $LOCK_OWNER."
    fi
}
