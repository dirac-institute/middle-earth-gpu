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

## Status (2026-11-19, on `vga`)

Deployed and passing for **both orgs**: `vga-dirac-institute` and
`vga-lincc-frameworks`, both in their org's `middle-earth-gpu` runner group.

There are two copies of this repo on GitHub. `dirac-institute/middle-earth-gpu`
is authoritative: branches, PRs and the VM's checkout use it.
`lincc-frameworks/middle-earth-gpu` is a fork, synced to `main`, which exists
only because a runner group accepts jobs from repos in its own org; the
lincc-frameworks group's workflow list names the fork's copy of the smoke
test.

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
- **SELinux and NFS.** No AVC denials from registering or from the NFS
  mounts. SELinux is Permissive on this VM (accepted); `virt_use_nfs` is on.
  Jobs' `nvidia-smi` was denied access to nvidia-persistenced's socket;
  `init.sh` loads `selinux/middle_earth_gpu.te` for that, and after it was
  loaded, fresh runners in both orgs ran smoke tests with no new AVCs.
- **`register.sh`** for both orgs: three 0600 files each, owned by
  `astro-vga`, unreadable by root.
- **Hooks.** "Set up runner" and "Complete runner" run; `GPU_LOCK_*` and
  `GPU_DRIVER_VERSION` reach the job; nvidia-smi works in jobs.
- **The lock:** released on cancel (and no processes left over);
  `podman kill` mid-job leaves it, and the entrypoint clears it on restart
  (see DEPLOY.md, "Restarting a runner", for GitHub's side of that).
- **GitHub-side:** jobs stay queued while the repo isn't selected or public
  repos aren't allowed (seen by accident while setting up).
- **Smoke test workflow** (`.github/workflows/gpu-smoke-test.yml`) is on
  both orgs' runner group lists and passes in both.
- **Two CDI specs (decided: leave as-is, 2026-11-19).** `init.sh` writes
  `/etc/cdi/nvidia.yaml`, and the container toolkit's
  `nvidia-cdi-refresh.service` writes `/var/run/cdi/nvidia.yaml` (at boot, on
  driver module load, and on driver or toolkit changes). Podman uses the
  `/var/run/cdi` one, so `init.sh`'s is redundant but harmless. Two specs
  for the same devices in the *same* directory do conflict, and podman
  rejects both (`nvidia-ctk cdi list` finds 0 devices), so never leave a
  second spec in `/etc/cdi`.
- **Idle check across containers** (2026-11-19): `nvidia-smi
  --query-compute-apps` in one runner does not list processes in the other,
  but memory use is shared. A CUDA process holds ~190 MiB before allocating
  anything and the idle baseline is 0 MiB, so `GPU_IDLE_MAX_MIB` went from
  512 to 64.
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
   approves the run. Do it in both orgs: each group was configured by hand.
5. **Monitoring from outside:** `curl -s
   http://vga.astro.washington.edu:9110/metrics | grep source_success` from
   another machine (if it can't connect, that is a firewall question for
   IT), then the gadget monitor PR (DEPLOY.md, "Monitoring").
6. **Contention:** start jobs in both orgs at once; one waits, logs who
   holds the GPU, then runs after the other finishes.
7. **Boot ordering.** NVIDIA orders docker/containerd/crio after
   `nvidia-cdi-refresh.service`, but not `podman-restart.service`, which
   starts the runners at boot. If the runners start before the spec exists,
   their GPU device won't resolve. Check during the reboot test (3); the fix
   would be a drop-in from `init.sh` with `After=nvidia-cdi-refresh.service`.
8. **Delete this file** once everything above is done.
