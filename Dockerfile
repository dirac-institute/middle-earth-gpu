# GitHub Actions self-hosted runner with a GPU lock, for the DiRAC GPU VM.
#
# Based on GitHub's official runner image. Pinned by tag and digest, because
# GitHub re-pushes tags. To upgrade, replace both and `podman compose up -d
# --build`; DEPLOY.md, "Upgrading the runner", shows how to look up the
# digest. The runner also self-updates in place between rebuilds.
FROM ghcr.io/actions/actions-runner:2.338.2@sha256:4037925f16bd0626196684aff1853dabd242675c82efe08f0a2d376694738d19

USER root

ARG SVC_UID
ARG SVC_GID
ARG SVC_USER

# Run as the service account from VM.set, so the runner can read and write
# its registration on the root_squash NFS share. The image's own `runner`
# user has passwordless sudo; the service account deliberately does not, so
# jobs cannot install system packages (see DEPLOY.md).
RUN groupadd -g ${SVC_GID} ${SVC_USER} 2>/dev/null || true && \
    useradd -u ${SVC_UID} -g ${SVC_GID} -M -d /home/runner -s /bin/bash ${SVC_USER} 2>/dev/null || true && \
    chown -R ${SVC_UID}:${SVC_GID} /home/runner

COPY runner/ /opt/gpu-runner/
RUN chmod 0755 /opt/gpu-runner/*.sh

# Job hooks: take the GPU lock before every job and release it after. The
# completed hook runs even when a job fails or is cancelled.
ENV HOME=/home/runner \
    ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/gpu-runner/job-started.sh \
    ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/opt/gpu-runner/job-completed.sh

USER ${SVC_UID}:${SVC_GID}
WORKDIR /home/runner

ENTRYPOINT ["/opt/gpu-runner/entrypoint.sh"]
