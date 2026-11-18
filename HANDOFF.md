# Handoff: finishing and deploying this repo

This repo was written outside the VM, from a copy of
`middle-earth-service-example`, without being able to run podman, the GPU or
GitHub. The design is settled; the details below are **unverified** and need
checking on the real VM. Delete this file once everything here is done.

## Ground rules for whoever finishes this (human or AI)

- Fix problems **in the repo**, then redeploy. Never patch the VM by hand.
- Keep the middle-earth conventions: `init.sh` is host-level only, identity
  from `/root/VM.set`, secrets on `/service/shire` read as the service uid,
  deploy is `podman compose up -d --build`.
- **Do not weaken these to make something work**; stop and ask instead:
  no container socket in the runners, no `sudo` for the service account in
  the image, and the GitHub-side runner group restrictions (DEPLOY.md,
  "GitHub-side setup"). They are what keeps untrusted pull request code off
  this VM.

## To verify, roughly in order

1. **Paths and names.** `SHIRE_DIR` at the top of `init.sh` is a guess
   (`/service/shire/gpu-runner`); confirm with PACS. Fill in the TODO table in
   DEPLOY.md, "GitHub-side setup", and the TODO in "GPU driver".
2. **`init.sh` on Rocky 10:** the NVIDIA Container Toolkit repo URL and
   install; `nvidia-ctk cdi list` output contains `nvidia.com/gpu=all`;
   `nvidia-persistenced.service` exists under that name; `install -d -o -g -m`
   fixes ownership on an existing directory.
3. **The image.** `ghcr.io/actions/actions-runner:2.338.2` exists (consider
   pinning by digest too). As the service uid (not the image's uid 1001):
   `config.sh` runs, and `run.sh` starts. Self-update can write to
   `/home/runner`.
4. **podman-compose (the version from EPEL):** the `x-runner` anchor with
   `<<:` merge keys; `devices: [nvidia.com/gpu=all]` reaching podman as a CDI
   device; two services building the same image tag; `extends` for
   `monitoring` still working alongside them.
5. **SELinux and NFS.** The runner-state mounts are read-write NFS bind mounts
   with no relabel; the example only mounted NFS read-only. If denied, check
   `getsebool virt_use_nfs` / `container_use_nfs`. That is IT's setting:
   ask, don't flip it silently. The lock directory uses `:z` (local disk).
6. **`register.sh` end to end** for one org with a real token; the three files
   land in `runner-state/<org>/` as 0600, owned by the service uid; the
   runner shows up in the org's `gpu` group with labels `self-hosted, Linux,
   X64, gpu`.
7. **Hooks.** The hook variables from the image's `ENV` reach the runner's
   worker; "Set up runner" / "Complete runner" steps appear in job logs;
   writing to `$GITHUB_ENV` from the started hook works (the job sees
   `GPU_LOCK_OWNER` etc.); `nvidia-smi` is present inside the container.
8. **The idle check.** Whether `nvidia-smi --query-compute-apps` inside one
   container lists processes started in the *other* container. If it doesn't,
   the memory threshold still catches a busy GPU; adjust `GPU_IDLE_MAX_MIB` to
   the idle baseline you actually see.
9. **The lock, deliberately:**
   - Start jobs in both orgs at once: one waits, logs who holds the GPU, then
     runs after the other finishes.
   - Cancel a running job: the lock is released.
   - `podman kill` a runner mid-job, then `podman compose up -d`: its lock is
     cleared at startup.
   - Reboot the VM mid-job: both runners come back and the lock is clear.
10. **GitHub-side restrictions, deliberately:** from a fork, open a pull
    request that adds a workflow with `runs-on: { group: gpu, labels: [gpu] }`.
    Its job must stay queued and never reach the VM, even after a maintainer
    approves the run.
11. **The DEPLOY.md verification steps and the gadget monitor registration**,
    as in the example.
