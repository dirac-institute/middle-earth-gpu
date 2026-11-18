#!/bin/bash
# Host initialization for the Middle-earth GPU runner VM. Run as root; safe to
# re-run.
#
#   git clone <this repo> && cd middle-earth-gpu-runner
#   sudo ./init.sh
#   sudo ./register.sh <org>        # once per GitHub org; see DEPLOY.md
#   podman compose up -d --build
#
# Only host-level concerns live here (checking the service account from IT's
# /root/VM.set, podman packages, NVIDIA container support, the GPU lock
# directory, .env). Everything else belongs in the container image. The
# service account, SSH, SELinux and the NVIDIA driver are provisioned outside
# this script; it checks them but does not change them.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$REPO_DIR/.env"
# Written by IT when the VM is provisioned and authoritative for the service
# account. tcsh syntax: `set VMUSER=astro-myservice`.
VM_SET=/root/VM.set
# Where this service's files live on the root_squash NFS share. Runner
# registrations go under runner-state/<org>/ (see SECRETS.md).
# TODO: confirm this path with PACS before first deploy.
SHIRE_DIR=/service/shire/gpu-runner
# Local (not NFS) directory shared by both runner containers for the GPU lock.
LOCK_DIR=/var/lib/middle-earth-gpu-runner/gpu-lock
# One directory per GitHub org this VM serves. Must match compose.yaml.
ORGS=(dirac-institute lincc-frameworks)

WARNINGS=0
warn() { echo "WARNING: $*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { echo "FATAL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

# vmset NAME: the value of `set NAME=value` in VM.set, quotes removed. The
# file is parsed, never executed; lines of any other form are ignored.
vmset() {
    sed -n -E "s/^[[:space:]]*set[[:space:]]+$1=(\"([^\"]*)\"|'([^']*)'|([^[:space:]\"']*))[[:space:]]*\$/\2\3\4/p" \
        "$VM_SET" | tail -n 1
}
[ -r "$VM_SET" ] || die "$VM_SET not found. IT writes it when the VM is provisioned; it
       defines the service account (VMUSER, VMUID, VMGID). Ask PACS via help-astro@uw.edu."
SVC_USER="$(vmset VMUSER)"
SVC_UID="$(vmset VMUID)"
SVC_GID="$(vmset VMGID)"
VM_NAME="$(vmset VM)"
[[ "$SVC_USER" =~ ^[a-z_][a-z0-9_.-]*$ ]] || die "VMUSER in $VM_SET is missing or not a user name: '$SVC_USER'"
[[ "$SVC_UID" =~ ^[0-9]+$ ]] || die "VMUID in $VM_SET is missing or not a number: '$SVC_UID'"
[[ "$SVC_GID" =~ ^[0-9]+$ ]] || die "VMGID in $VM_SET is missing or not a number: '$SVC_GID'"

# ── Service account ────────────────────────────────────────────────────────
echo "== Service account =="
# The container runs as this uid. On a production VM the secrets directory is
# on a shared NFS mount exported with root_squash, meaning root cannot read
# mode-0600 files -- only the service account can. IT provisions the account
# and names it in VM.set; the two must agree. See SECRETS.md for the
# production story.
account_fail() {
    echo "FATAL: $*" >&2
    echo "$VM_SET and the accounts on this VM disagree; ask PACS via help-astro@uw.edu." >&2
    exit 1
}
have_user="$(getent passwd "$SVC_USER" || true)"
[ -n "$have_user" ] || account_fail "user $SVC_USER does not exist"
have_uid="$(echo "$have_user" | cut -d: -f3)"
have_gid="$(echo "$have_user" | cut -d: -f4)"
[ "$have_uid" = "$SVC_UID" ] \
    || account_fail "user $SVC_USER has uid $have_uid, VM.set says $SVC_UID"
[ "$have_gid" = "$SVC_GID" ] \
    || account_fail "user $SVC_USER has primary gid $have_gid, VM.set says $SVC_GID"
echo "  ok   user $SVC_USER ($SVC_UID:$SVC_GID) from $VM_SET exists"

# ── Packages ────────────────────────────────────────────────────────────────
echo
echo "== Packages =="
need=()
command -v podman >/dev/null || need+=(podman)
command -v podman-compose >/dev/null || need+=(podman-compose)
if [ ${#need[@]} -gt 0 ]; then
    rpm -q epel-release >/dev/null 2>&1 || dnf install -y epel-release
    dnf install -y "${need[@]}"
else
    echo "podman and podman-compose already installed"
fi
podman --version

# A compose restart policy only survives reboot if this unit is enabled.
systemctl enable --now podman-restart.service >/dev/null 2>&1 \
    && echo "podman-restart.service enabled" \
    || warn "could not enable podman-restart.service (containers won't restart at boot)"

# ── GPU ─────────────────────────────────────────────────────────────────────
echo
echo "== GPU =="
# The NVIDIA driver is a prerequisite, not installed here: it is tied to the
# kernel and is the one piece that most needs a human. See DEPLOY.md, "GPU
# driver".
command -v nvidia-smi >/dev/null \
    || die "nvidia-smi not found: install the NVIDIA driver first (DEPLOY.md, \"GPU driver\")"
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader \
    || die "nvidia-smi is installed but cannot talk to the GPU; is the driver loaded?"

# NVIDIA Container Toolkit, so podman can hand the GPU to containers via CDI.
if ! command -v nvidia-ctk >/dev/null; then
    curl -fsSL -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
        https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
    dnf install -y nvidia-container-toolkit
else
    echo "nvidia-container-toolkit already installed"
fi
# The CDI spec lists driver files by version, so regenerate it on every run;
# after a driver update, re-running init.sh is enough.
mkdir -p /etc/cdi
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml >/dev/null
nvidia-ctk cdi list | grep -q 'nvidia.com/gpu=all' \
    || die "CDI spec has no nvidia.com/gpu=all device; check 'nvidia-ctk cdi list'"
echo "  ok   CDI spec written to /etc/cdi/nvidia.yaml"

# Persistence mode keeps the driver initialised between jobs, so the first
# job after an idle period doesn't pay a startup cost in its timings. The
# daemon ships with the driver and survives reboots, unlike `nvidia-smi -pm 1`.
if systemctl list-unit-files nvidia-persistenced.service >/dev/null 2>&1; then
    systemctl enable --now nvidia-persistenced.service >/dev/null 2>&1 \
        && echo "  ok   nvidia-persistenced enabled" \
        || warn "could not enable nvidia-persistenced (first job after idle may be slower)"
else
    warn "nvidia-persistenced.service not found; persistence mode is off (see DEPLOY.md)"
fi
# GPU clock locking is deliberately not done here; see DEPLOY.md, "Clocks".

# ── GPU lock directory ──────────────────────────────────────────────────────
echo
echo "== GPU lock =="
# Both runner containers bind-mount this; only one may hold the GPU at a time.
install -d -m 0755 "$(dirname "$LOCK_DIR")"
install -d -m 0700 -o "$SVC_UID" -g "$SVC_GID" "$LOCK_DIR"
echo "  ok   $LOCK_DIR owned by $SVC_UID:$SVC_GID"

# ── Runner registrations ───────────────────────────────────────────────────
echo
echo "== Runner registrations =="
# Checked as the service account, since root cannot read them on the
# root_squash share. Missing ones are a warning: register.sh creates them.
as_svc() { setpriv --reuid="$SVC_UID" --regid="$SVC_GID" --clear-groups "$@"; }
for org in "${ORGS[@]}"; do
    if as_svc test -r "$SHIRE_DIR/runner-state/$org/.credentials_rsaparams"; then
        echo "  ok   $org registered"
    else
        warn "$org not registered: run 'sudo ./register.sh $org' (DEPLOY.md)"
    fi
done

# ── Compose environment ────────────────────────────────────────────────────
echo
echo "== Compose environment =="
FQDN="$(hostname -f 2>/dev/null || hostname)"
case "$FQDN" in
    *.*) ;;
    *)   warn "hostname '$FQDN' is not fully qualified; check DNS and /etc/hosts" ;;
esac
# VM.set's VM is IT's short name for this VM. Nothing here depends on it, but
# a mismatch means VM.set may have been copied from another VM.
SHORT="$(hostname -s | tr '[:upper:]' '[:lower:]')"
[ -z "$VM_NAME" ] || [ "$VM_NAME" = "$SHORT" ] \
    || warn "VM.set says VM=$VM_NAME but the hostname is $SHORT; is $VM_SET from this VM?"
# .env is gitignored and derived: rewritten on every run from VM.set and the
# hostname, so podman compose can read them. Re-run init.sh rather than
# editing it.
cat > "$ENV_FILE" <<EOF
# Written by init.sh on every run; don't edit.
SVC_USER=$SVC_USER
SVC_UID=$SVC_UID
SVC_GID=$SVC_GID
SVC_FQDN=$FQDN
SVC_SHORTNAME=$SHORT
SVC_SHIRE_DIR=$SHIRE_DIR
GPU_LOCK_DIR=$LOCK_DIR
EOF
echo "  ok   SVC_USER=$SVC_USER SVC_UID=$SVC_UID SVC_GID=$SVC_GID written to $ENV_FILE"
echo "  ok   SVC_FQDN=$FQDN written to $ENV_FILE"
echo "  ok   SVC_SHIRE_DIR=$SHIRE_DIR GPU_LOCK_DIR=$LOCK_DIR written to $ENV_FILE"

echo
if [ "$WARNINGS" -gt 0 ]; then
    echo "init complete with $WARNINGS warning(s)."
else
    echo "init complete."
fi
echo "Next: sudo ./register.sh <org> for any org reported above, then podman compose up -d --build"
