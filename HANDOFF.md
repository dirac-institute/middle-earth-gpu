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

## Status (2026-11-18, on `vga`)

Deployed for **dirac-institute**. lincc-frameworks is enabled in
`compose.yaml` and `init.sh` and is being registered.

### Done

- **Paths and names.** `SHIRE_DIR=/service/shire` (the service directory).
  "GPU driver" in DEPLOY.md records how the driver was installed.
- **`init.sh` on Rocky 10.** The container toolkit comes from the CUDA repo
  PACS configures; the CDI spec has `nvidia.com/gpu=all`;
  `nvidia-persistenced` is enabled; `install -d -o -g -m` fixes an existing
  directory.
- **The image.** Pinned by tag and digest. As the service uid: `config.sh`
  and `run.sh` work, `/home/runner` is writable, no sudo, GPU visible.
- **podman-compose 1.5.0 (EPEL).** `<<:` merge keys, the CDI device and
  `extends` all work.
- **SELinux and NFS.** No AVC denials from registering or running.
  SELinux is Permissive on this VM (accepted); `virt_use_nfs` is on.
- **`register.sh`** for dirac-institute: three 0600 files owned by
  `astro-vga`, unreadable by root, runner `vga-dirac-institute` in group
  `middle-earth-gpu`.
- **Hooks.** "Set up runner" and "Complete runner" run; `GPU_LOCK_*` and
  `GPU_DRIVER_VERSION` reach the job; nvidia-smi works in jobs.
- **The lock:** released on cancel (and no processes left over);
  `podman kill` mid-job leaves it, and the entrypoint clears it on restart
  (see DEPLOY.md, "Restarting a runner", for GitHub's side of that).
- **GitHub-side:** jobs stay queued while the repo isn't selected or public
  repos aren't allowed (seen by accident while setting up).
- **Smoke test workflow** (`.github/workflows/gpu-smoke-test.yml`) is on
  dirac-institute's runner group list and passes.
- **Monitoring container** answers locally on port 9110, every source `1`.

### Still to do

1. **Fill in the "Who can change its settings" table** in DEPLOY.md,
   "GitHub-side setup".
2. **Busy GPU:** with a CUDA process holding GPU memory on the host, a job
   must fail in "Set up runner" with "The GPU is not idle".
3. **Reboot the VM mid-job:** the runner comes back, the lock is clear, and
   how long GitHub keeps it unavailable (DEPLOY.md, "Restarting a runner").
4. **Fork pull request:** from a fork, open a pull request that adds a
   workflow with `runs-on: { group: middle-earth-gpu, labels: [gpu] }`. Its
   job must stay queued and never reach the VM, even after a maintainer
   approves the run.
5. **Monitoring from outside:** `curl -s
   http://vga.astro.washington.edu:9110/metrics | grep source_success` from
   another machine (if it can't connect, that is a firewall question for
   IT), then the gadget monitor PR (DEPLOY.md, "Monitoring").
6. **lincc-frameworks:** register it (`sudo ./register.sh lincc-frameworks`)
   and start it (`podman compose up -d --build`), then:
   - **Contention:** start jobs in both orgs at once; one waits, logs who
     holds the GPU, then runs after the other finishes.
   - **Idle check across containers:** whether `nvidia-smi
     --query-compute-apps` in one container lists processes started in the
     other. If not, the memory threshold still catches a busy GPU; set
     `GPU_IDLE_MAX_MIB` from the idle baseline (0 MiB on this L4 so far).
7. **Delete this file** once everything above is done.
