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
- **Contention between orgs** (2026-11-19): lincc-frameworks held the GPU
  for 300 s from 18:34:07Z; dirac-institute's job, started at 18:34:37Z,
  waited in "Set up runner" ("GPU in use by 'lincc-frameworks' (...)"), took
  the lock after lincc-frameworks released it at 18:39:08Z, and both
  succeeded.
- **Busy GPU** (2026-11-19): with a host process holding 1216 MiB, a
  lincc-frameworks job took the lock, reported the GPU busy for 60 s, failed
  in "Set up runner" with "The GPU is not idle..." and `nvidia-smi` output,
  and the lock was released. `nvidia-smi --query-compute-apps` in the runner
  did not list the host process either; the memory threshold caught it.
- **Reboot mid-job** (2026-11-19): all three containers were back within 7 s
  of boot; `podman-restart` started after `nvidia-cdi-refresh` finished (the
  `init.sh` drop-in); both runners saw the GPU; the interrupted job's lock was
  cleared by its runner's entrypoint; no AVCs since boot. The runner with the
  interrupted job stayed Active on it until the run was cancelled, then took
  the next job 5 minutes later; the idle runner reconnected after 2 min 38 s.
  A graceful `podman restart` of an idle runner reconnected in 3 s. Details in
  DEPLOY.md, "Restarting a runner".
- **Monitoring:** the container answers on port 9110, and the VM was added
  to the gadget monitor (done separately, 2026-11-19).

### Still to do

1. **Fork pull request:** from a fork, open a pull request that adds a
   workflow with `runs-on: { group: middle-earth-gpu, labels: [gpu] }`. Its
   job must stay queued and never reach the VM, even after a maintainer
   approves the run. Do it in both orgs: each group was configured by hand.
2. **Reboot again after deploying the NFS boot fix.** The reboot after the
   2026-11-19 point release (Rocky 10.3, kernel 6.12.0-264, podman 6.1.1)
   found that podman started the runners before `/service/shire` was
   mounted: `gpu-runner-dirac-institute` failed to start, and the other two
   containers lost their `conmon`. `init.sh` now also orders
   `podman-restart.service` after the mount (DEPLOY.md, "Boot persistence").
   After `sudo ./init.sh` and a plain `reboot`, check: all three containers
   Up, `systemctl status podman-restart` succeeded, and the journal shows
   `service-shire.mount` mounted before `podman-restart` started.
3. **Delete this file** once everything above is done.
