#!/bin/bash
# Host initialization for the Middle-earth GPU runner VM. Run as root; safe to
# re-run.
#
#   git clone git@github.com:dirac-institute/middle-earth-gpu.git && cd middle-earth-gpu
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
# This service's directory on the root_squash NFS share: the whole mount,
# which is this VM's own export. Runner registrations go under
# runner-state/<org>/ (see SECRETS.md).
SHIRE_DIR=/service/shire
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
# It comes from NVIDIA's CUDA repo, which PACS configures alongside the
# driver (/etc/yum.repos.d/PACS/cuda-rhel10.repo); no extra repo is added.
if ! command -v nvidia-ctk >/dev/null; then
    dnf install -y nvidia-container-toolkit \
        || die "could not install nvidia-container-toolkit; is NVIDIA's CUDA repo configured? (DEPLOY.md, \"GPU driver\")"
else
    echo "nvidia-container-toolkit already installed"
fi
# The CDI spec lists driver files by version, so regenerate it on every run;
# after a driver update, re-running init.sh is enough.
mkdir -p /etc/cdi
# It logs a line per driver file it looks for (many "not found" warnings for
# display libraries a headless VM doesn't have); show them only on failure.
cdi_log="$(nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>&1)" \
    || { echo "$cdi_log" >&2; die "nvidia-ctk cdi generate failed"; }
nvidia-ctk cdi list 2>/dev/null | grep -q 'nvidia.com/gpu=all' \
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

# Boot order. podman-restart.service starts the runners at boot, and waits
# only for the network. The runners also need:
# - The NFS share (SHIRE_DIR), which holds their registrations. fstab mounts
#   it (_netdev), but nothing orders podman after that: on 2026-11-19 podman
#   tried to start a runner 9 ms before the share was mounted, that runner
#   failed to start, podman-restart.service failed, and systemd then killed
#   the other containers' conmon. WantsMountsFor= mounts it and waits.
# - The container toolkit's nvidia-cdi-refresh.service, which creates the
#   GPU's control device nodes and writes the CDI spec podman actually uses
#   (/var/run/cdi/nvidia.yaml; /run is empty after a reboot). NVIDIA orders
#   docker, containerd and crio after it, but not podman.
# Wants, not Requires: if either fails, podman still tries to start the
# containers, as it would without this.
BOOT_ORDER_DIR=/etc/systemd/system/podman-restart.service.d
BOOT_ORDER_FILE="$BOOT_ORDER_DIR/10-middle-earth-gpu.conf"
want="# Written by middle-earth-gpu's init.sh; edit it there, not here.
[Unit]
WantsMountsFor=$SHIRE_DIR"
if systemctl list-unit-files nvidia-cdi-refresh.service >/dev/null 2>&1; then
    want="$want
After=nvidia-cdi-refresh.service"
else
    warn "nvidia-cdi-refresh.service not found; runners may start before the GPU is ready at boot"
fi
if [ "$(cat "$BOOT_ORDER_FILE" 2>/dev/null)" != "$want" ]; then
    install -d -m 0755 "$BOOT_ORDER_DIR"
    printf '%s\n' "$want" > "$BOOT_ORDER_FILE"
    systemctl daemon-reload
fi
shire_mount="$(systemd-escape --path --suffix=mount "$SHIRE_DIR")"
systemctl show -p After podman-restart.service | grep -q "$shire_mount" \
    || die "podman-restart.service is not ordered after $shire_mount; check $BOOT_ORDER_FILE"
echo "  ok   podman-restart.service starts after $SHIRE_DIR is mounted ($shire_mount)"
if [[ "$want" == *nvidia-cdi-refresh* ]]; then
    systemctl show -p After podman-restart.service | grep -q 'nvidia-cdi-refresh.service' \
        || die "podman-restart.service is not ordered after nvidia-cdi-refresh.service; check $BOOT_ORDER_FILE"
    echo "  ok   podman-restart.service starts after nvidia-cdi-refresh.service"
fi

# ── SELinux ─────────────────────────────────────────────────────────────────
echo
echo "== SELinux =="
# Lets GPU containers reach nvidia-persistenced's socket, which the CDI spec
# mounts into them; see selinux/middle_earth_gpu.te. Rebuilt and reloaded on
# every run (loading a module again replaces it), so editing the .te file and
# re-running init.sh is enough. SELinux mode itself is IT's setting and is
# not changed here.
SELINUX_MODULE=middle_earth_gpu
if selinuxenabled 2>/dev/null; then
    command -v checkmodule >/dev/null || dnf install -y checkpolicy
    selinux_tmp="$(mktemp -d)"
    checkmodule -M -m -o "$selinux_tmp/$SELINUX_MODULE.mod" \
            "$REPO_DIR/selinux/$SELINUX_MODULE.te" >/dev/null \
        || die "could not compile selinux/$SELINUX_MODULE.te"
    semodule_package -o "$selinux_tmp/$SELINUX_MODULE.pp" \
            -m "$selinux_tmp/$SELINUX_MODULE.mod" \
        || die "could not package selinux/$SELINUX_MODULE.te"
    semodule -i "$selinux_tmp/$SELINUX_MODULE.pp" \
        || die "could not load SELinux module $SELINUX_MODULE"
    rm -rf "$selinux_tmp"
    echo "  ok   SELinux module $SELINUX_MODULE loaded ($(getenforce))"
else
    echo "SELinux is disabled; skipping module $SELINUX_MODULE"
fi

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
