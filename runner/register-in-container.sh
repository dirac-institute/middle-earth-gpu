#!/bin/bash
# Run by register.sh inside a throwaway container, as the service account.
# Registers a runner with GitHub and copies its credentials to /runner-state.
set -euo pipefail
ORG="$1"; GROUP="$2"; NAME="$3"
: "${RUNNER_TOKEN:?RUNNER_TOKEN must be passed in the environment}"

cd /home/runner
./config.sh --unattended --replace \
    --url "https://github.com/$ORG" \
    --token "$RUNNER_TOKEN" \
    --name "$NAME" \
    --runnergroup "$GROUP" \
    --labels gpu \
    --work _work

for f in .runner .credentials .credentials_rsaparams; do
    install -m 0600 "$f" "/runner-state/$f"
done
echo "Registered $NAME in $ORG (group: $GROUP); credentials saved."
