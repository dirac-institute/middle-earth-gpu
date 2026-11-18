#!/bin/bash
# Register this VM's runner with one GitHub org. Run as root, once per org, and
# again only to re-register (e.g. after removing the runner in GitHub).
#
#   sudo ./register.sh dirac-institute
#   sudo ./register.sh lincc-frameworks
#
# Prompts for a registration token: in the org on GitHub, Settings → Actions →
# Runners → New runner → New self-hosted runner, and copy the token from the
# `config.sh` line shown there. Tokens expire after an hour and only allow
# registering, so it's fine for an org owner to send you one.
#
# The registration (.runner, .credentials, .credentials_rsaparams) is written
# to $SVC_SHIRE_DIR/runner-state/<org>/ as the service account, the only uid
# that can write there (root_squash). See SECRETS.md.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE=localhost/middle-earth-gpu-runner:latest
# Runner group to join. Must already exist in the org, set up as in DEPLOY.md.
GROUP="${RUNNER_GROUP:-gpu}"

die() { echo "FATAL: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "must run as root"
[ $# -eq 1 ] || die "usage: sudo ./register.sh <org>   (e.g. dirac-institute)"
ORG="$1"
[[ "$ORG" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "not a GitHub org name: '$ORG'"
grep -q "runner-state/$ORG:" "$REPO_DIR/compose.yaml" \
    || die "compose.yaml has no runner service for '$ORG'; add one first (DEPLOY.md, \"Adding an org\")"

[ -r "$REPO_DIR/.env" ] || die ".env not found: run sudo ./init.sh first"
set -a; source "$REPO_DIR/.env"; set +a

STATE="$SVC_SHIRE_DIR/runner-state/$ORG"
NAME="$SVC_SHORTNAME-$ORG"
as_svc() { setpriv --reuid="$SVC_UID" --regid="$SVC_GID" --clear-groups "$@"; }

# 0755 directories (so podman, as root, can bind-mount them through
# root_squash), 0600 files, as in SECRETS.md.
as_svc install -d -m 0755 "$SVC_SHIRE_DIR/runner-state" "$STATE" \
    || die "could not create $STATE as uid $SVC_UID; is $SVC_SHIRE_DIR there and owned by it?"

echo "Building the runner image..."
(cd "$REPO_DIR" && podman build -q -t "$IMAGE" \
    --build-arg SVC_UID="$SVC_UID" --build-arg SVC_GID="$SVC_GID" \
    --build-arg SVC_USER="$SVC_USER" .) >/dev/null

echo "Registering runner '$NAME' in https://github.com/$ORG (group '$GROUP')."
read -rsp "Registration token: " RUNNER_TOKEN; echo
[ -n "$RUNNER_TOKEN" ] || die "no token given"
export RUNNER_TOKEN   # passed by name below, so it never appears in `ps`

podman run --rm \
    --user "$SVC_UID:$SVC_GID" \
    -e RUNNER_TOKEN \
    -e LOCK_OWNER="$ORG" \
    -v "$STATE:/runner-state" \
    --entrypoint /opt/gpu-runner/register-in-container.sh \
    "$IMAGE" "$ORG" "$GROUP" "$NAME"

echo
echo "Done. Start or restart it with: podman compose up -d"
