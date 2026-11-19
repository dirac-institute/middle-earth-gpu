# Deploying the Middle-earth GPU runner

Target: stock Rocky 10 VM on UW DiRAC infrastructure, with an NVIDIA GPU passed
through to it.

This VM runs GitHub Actions jobs that need the GPU, for two GitHub orgs
(`dirac-institute` and `lincc-frameworks`). A self-hosted runner can only
belong to one org, so there are two runner containers. They take turns on the
GPU: one job at a time, across both orgs.

```bash
git clone git@github.com:dirac-institute/middle-earth-gpu.git /root/middle-earth-gpu
cd /root/middle-earth-gpu
sudo ./init.sh
sudo ./register.sh dirac-institute      # first deploy only; prompts for a token
sudo ./register.sh lincc-frameworks     # first deploy only; prompts for a token
podman compose up -d --build
```

Before the first `register.sh`, each org needs its runner group set up on
GitHub; see "GitHub-side setup". Without it, the runners either can't register
or will accept jobs from the wrong places.

Then verify:

```bash
podman ps                                   # three containers, all Up
podman logs gpu-runner-dirac-institute      # ends with "Listening for Jobs"
podman logs gpu-runner-lincc-frameworks     # ends with "Listening for Jobs"
podman exec gpu-runner-dirac-institute nvidia-smi   # the GPU is visible
```

Both runners should show as **Idle** in each org's Settings → Actions →
Runners. Then run this repo's **GPU smoke test** workflow by hand (Actions →
GPU smoke test → Run workflow; it must be on the runner group's workflow
list) and check that it passes and its "Set up runner" step says it acquired
the GPU lock.

Then register the VM with the gadget monitor; see "Monitoring" below.

## What each piece does

| File | Role |
|---|---|
| `/root/VM.set` (not in the repo) | Written by IT when the VM is provisioned. The source of truth for the service account name, uid, and gid. |
| `init.sh` | Host-level only: checks the service account from `/root/VM.set`, installs podman, podman-compose and the NVIDIA Container Toolkit, generates the CDI spec that hands the GPU to containers, enables GPU persistence mode and `podman-restart.service`, loads the SELinux module in `selinux/`, creates the GPU lock directory, reports which orgs are registered, writes `.env`. Idempotent; safe to re-run. |
| `selinux/middle_earth_gpu.te` | SELinux policy module, loaded by `init.sh`: lets GPU containers reach nvidia-persistenced's socket. See "VM infrastructure context". |
| `register.sh` | One-time, per org: registers a runner with GitHub using a short-lived token, and saves its credentials to `/service/shire` as the service account. |
| `Dockerfile` | GitHub's official runner image (pinned), run as the service account, with the GPU lock hooks. |
| `runner/entrypoint.sh` | Container entrypoint: links the org's registration into the runner, clears any lock this runner left behind, starts the runner. |
| `runner/job-started.sh` | Runs before every job: waits for the GPU lock, checks the GPU is idle, records the GPU's state. |
| `runner/job-completed.sh` | Runs after every job, even failed or cancelled ones: releases the lock. |
| `runner/gpu-lock-lib.sh` | The lock itself, shared by the scripts above. |
| `runner/register-in-container.sh` | Used by `register.sh`; runs GitHub's `config.sh` inside the image. |
| `compose.yaml` | One runner service per org, plus `monitoring` (the VM's CPU, memory and disks on port 9110). |
| `monitoring/` | Service VM monitor, copied unchanged from [middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor). |
| `examples/gpu-benchmark.yml` | A workflow to copy into a repo that wants to use the GPU. |
| `.github/workflows/gpu-smoke-test.yml` | Run by hand to check a deployed runner: hooks, lock and GPU, with no project code. |
| `USING.md` | For people adding a GPU job to their repo: permissions, allowlisting, limits, troubleshooting. |
| `SECRETS.md` | What is secret here, where it lives, and who it trusts. |

## Architecture

```
                 ┌──────────────── GPU VM ─────────────────────────────────┐
  GitHub    ◄────┤ runner-dirac-institute   ─┐                             │
  (dirac-        │   registration: /service/ │                             │
   institute)    │   shire/.../dirac-institute├─► /gpu-lock ─► one job at   │
                 │                            │   (local dir)  a time on    │
  GitHub    ◄────┤ runner-lincc-frameworks  ─┘                 the GPU      │
  (lincc-        │   registration: /service/shire/.../lincc-frameworks      │
   frameworks)   │                                                          │
                 │ monitoring (port 9110) ◄── gadget monitor                │
                 └──────────────────────────────────────────────────────────┘
```

Runners only connect *out* to GitHub over HTTPS and long-poll for jobs.
Nothing connects in to them.

## Design choices

**One persistent runner per org, as the service account.** Each runner keeps
its registration across restarts, on the root_squash NFS share where only the
service account can read it. This is the simplest setup that works, and it
relies on a trust decision recorded in `SECRETS.md`: everyone who can get code
run here is already trusted with this VM.

**GitHub decides which code runs here, not this repo.** The repos are public
with open pull requests, and a pull request can change any workflow file, so
nothing in a workflow file can keep untrusted code off this VM. GitHub's runner
group settings can: they accept jobs only from listed workflow files on
`main`. See "GitHub-side setup".

**A lock directory, not a scheduler.** `mkdir` is atomic, so whichever runner
creates `/gpu-lock/held` first holds the GPU, and the other waits. There is no
queue or fairness between orgs; at this VM's load, first come first served is
enough.

**Benchmarks never run on a busy GPU.** After taking the lock, a job also
checks the GPU has no processes and almost no memory in use, and fails loudly
if not, rather than producing a misleading timing.

**No container engine inside the runners.** No Docker or podman socket is
mounted, so jobs cannot start containers. A job with the host's container
socket would effectively be root on the VM.

## GitHub-side setup

This half of the configuration lives in each org's settings on GitHub, not in
this repo. Do it in **both** orgs. You need to be an org owner or have the
"Manage organization runners and runner groups" permission in that org.

**1. A runner group called `middle-earth-gpu`** (Settings → Actions → Runner groups → New
runner group). Creating groups needs the GitHub Team plan.

- **Repository access:** *Selected repositories*, listing only the repos that
  need the GPU.
- **Allow public repositories:** on. Off is the default; these repos are
  public.
- **Workflow access:** *Selected workflows*, listing each workflow file that
  may use the GPU, pinned to `main` with a fully qualified ref:

  ```
  dirac-institute/some-repo/.github/workflows/gpu-benchmark.yml@refs/heads/main
  ```

  A pull request from a fork runs at a pull-request ref, so it never matches
  this list: its jobs wait in the queue and never reach the VM, even if a
  maintainer approves the run. Only jobs defined directly in a listed file
  can use the group.

  **If a job waits forever** at "Waiting for a runner to pick up this job"
  while the runner shows as Idle, one of the three settings above is missing:
  the repo isn't selected, public repositories aren't allowed, or the
  workflow isn't listed exactly as above. GitHub gives no error. Fix the
  setting, cancel the run and start a new one: a run that is already queued
  is not matched again.

**2. Only list workflows with trusted triggers:** `push` (to `main`),
`workflow_dispatch`, `schedule`. (`release` is safe but runs at a tag ref, so
it never matches a `@refs/heads/main` entry.) Never list a workflow that uses
`pull_request_target` or `workflow_run`: those run from `main`, so they pass
the check above, and if they check out a pull request's code they would run it
here.

**3. Protect `main`** in each repo: require a pull request review before
merging. Everything that lands on `main` in a listed repo (the workflow, and
any tests, scripts or build files it runs) will run on this VM. Consider a
CODEOWNERS entry for `.github/workflows/`.

**4. Run pull request CI on GitHub-hosted runners**, not here. They are free
for public repos, and contributors still get fast feedback.

Only an org's owners (or someone they give runner-group permission) can
change these settings, and a successor may not be an owner of both orgs.
`SECRETS.md`, "Who has access", says how to find each org's owners, each
repo's maintainers, and who has root on this VM.

## Using the runner

How a repo gets a job onto this VM, what a job gets, and what to do when one
doesn't start, are in [`USING.md`](USING.md). Point people there.

## The GPU lock

Every job, from either org, takes the lock before its first step and releases
it after its last, even when it fails or is cancelled. In the job log:

- **"Set up runner"** shows the wait (`GPU in use by 'lincc-frameworks' (...)`),
  the idle check, and the GPU's clocks, temperature and power.
- **"Complete runner"** shows the release.

Waiting counts toward the job's `timeout-minutes` (default 6 hours), because
GitHub considers the job started. Tunables, set as `environment:` entries on
the runner services in `compose.yaml`:

| Variable | Default | Meaning |
|---|---|---|
| `GPU_LOCK_MAX_WAIT_SECONDS` | 10800 | Fail the job after waiting this long. |
| `GPU_LOCK_STALE_SECONDS` | 86400 | Treat the *other* runner's lock as abandoned after this long. |
| `GPU_IDLE_MAX_MIB` | 64 | "Idle" means at most this much GPU memory in use. It is the only check that sees GPU work in the *other* runner's container (`nvidia-smi` lists only processes in its own), so keep it below the ~190 MiB any CUDA process uses; idle is 0 MiB on the L4. |
| `GPU_IDLE_GRACE_SECONDS` | 60 | How long to wait for the GPU to go idle before failing. |

A lock left behind by a crash clears itself: a runner releases its own lock
when its container starts, and reclaims its own lock at its next job.

To see who holds the GPU right now:

```bash
cat /var/lib/middle-earth-gpu-runner/gpu-lock/held/owner \
    /var/lib/middle-earth-gpu-runner/gpu-lock/held/info
```

## Benchmark reliability

The runners make the GPU exclusive and check it is idle. Some noise is outside
their control:

- **CPU timings are shared.** The GPU belongs to this VM alone, but the CPUs
  are shared with every other VM on the physical machine. Anything that times
  CPU work, data loading or host-to-device copies picks up noise from them.
  Run a fixed reference benchmark regularly and watch for shifts.
- **Clocks.** GPU boost clocks vary with temperature and power, and that
  variation lands in timings. Locking them (`nvidia-smi -lgc <min>,<max>`)
  makes runs more comparable at the cost of peak speed. This is a deliberate
  decision for the benchmark's owners, so `init.sh` does not do it. If you
  decide to, it needs root and does not survive a reboot, so add it to
  `init.sh` as a systemd unit and record the decision here.
- **Persistence mode** is enabled by `init.sh` (`nvidia-persistenced`), so the
  first job after an idle period doesn't pay for driver startup.
- **Record the environment with every result:** at least the variables above,
  plus `nvidia-smi` output, which "Set up runner" prints.

## GPU driver

The NVIDIA driver must be installed on the VM before `init.sh`; it checks for
`nvidia-smi` and stops if it's missing. It is not installed by `init.sh`
because it is tied to the kernel: a kernel update can break it, and fixing it
needs a person.

On this VM (`vga`, an NVIDIA L4), the driver was installed on 2026-11-17
from NVIDIA's CUDA repo, which PACS configures as
`/etc/yum.repos.d/PACS/cuda-rhel10.repo`:

```bash
dnf install kernel-devel-matched kernel-headers   # DKMS builds against these
dnf install nvidia-driver-cuda kmod-nvidia-open-dkms
```

That is driver 620.70.06, the **open** kernel module, built by DKMS. The same
repo also provides the CUDA toolkit (installed on the host for debugging, not
used by the runners) and `nvidia-container-toolkit`, which `init.sh` installs.

**After a kernel update**, DKMS rebuilds the module at boot, provided the
matching `kernel-devel` is installed (`kernel-devel-matched` pulls it in).
Check with `dkms status` and `nvidia-smi`. If the build failed, install the
matching `kernel-devel` and run `dkms autoinstall`, or boot the previous
kernel.

**After any driver change**, re-run `sudo ./init.sh`: the CDI spec it writes
names the driver's files by version. Then `podman compose up -d
--force-recreate` so the runners pick up the new spec.

## Service identity: `/root/VM.set`

IT leaves `/root/VM.set` on every VM when it provisions it. It is in tcsh
syntax and names the VM and its service account:

```
set VM=myservice
set VMUSER=astro-myservice
set VMUID=NNNNNNN
set VMGID=NNNNNNNNNN
set VMGECOS="My Service Management User"
```

`init.sh` reads `VMUSER`, `VMUID` and `VMGID` from it. It parses the file and
never runs it, and ignores lines of any other form. It exits if the file is
missing, if any of the three is missing or malformed, or if the account does
not exist on the VM with exactly that uid and primary gid. If `VM` doesn't
match the VM's short hostname, it warns, because the file may have been
copied from another VM. `VMGECOS` is not used.

There is no copy of these values in the repo. If `VM.set` is missing or wrong,
ask PACS via help-astro@uw.edu rather than writing your own.

## Per-host configuration: `.env`

`init.sh` writes the account to `.env` as `SVC_USER`, `SVC_UID` and
`SVC_GID`, along with the host's FQDN and short name (`SVC_FQDN`,
`SVC_SHORTNAME`; runners are named `<short name>-<org>`), the service's
directory on `/service/shire` (`SVC_SHIRE_DIR`) and the GPU lock directory
(`GPU_LOCK_DIR`). Podman compose reads `.env` automatically.

The Dockerfile and compose.yaml consume these values with no hardcoded
defaults, so running `podman compose` without a populated `.env` fails on the
missing variables. `.env` is gitignored and derived: `init.sh` rewrites it on
every run. Re-run `init.sh` rather than editing it, and never copy it between
hosts.

## VM infrastructure context

DiRAC VMs run Rocky 10 and use podman (not Docker) as the container runtime.
Key things to know:

- **podman-compose** is the compose frontend. It reads the same `compose.yaml`
  format as `docker compose`. Install it from EPEL; `init.sh` handles this.
- **podman-restart.service** must be enabled for `restart: unless-stopped` to
  survive a VM reboot. `init.sh` enables it.
- **The VM's reverse proxy** handles TLS termination and firewall rules for
  services that serve web traffic. The runners serve nothing: they only make
  outbound HTTPS connections to GitHub, so they need no ports and no proxy
  route.
- **Service accounts** exist because the NFS share uses `root_squash`. The
  container process must run as the uid that owns the secrets on the share.
  IT creates this account on the VM and names it in `/root/VM.set`;
  `init.sh` checks the two agree and exits if they do not.
- **GPU containers** use CDI: `init.sh` installs the NVIDIA Container
  Toolkit and writes `/etc/cdi/nvidia.yaml`, and `compose.yaml` asks for the
  device `nvidia.com/gpu=all`.
- **SELinux** is permissive on this VM and IT expects to keep it that way,
  but the service is meant to work under enforcing too. The CDI spec mounts
  nvidia-persistenced's socket into GPU containers, and the base policy
  doesn't let containers connect to it, so every job's `nvidia-smi` logged a
  denial. `init.sh` loads a small module, `selinux/middle_earth_gpu.te`,
  that allows exactly that (`semodule -l | grep middle_earth_gpu` shows it).
  After any change that could add denials, check
  `ausearch -m AVC -ts recent`: in permissive mode they are only logged, so
  nothing else will tell you.

## Adding an org

1. Do the "GitHub-side setup" in the new org.
2. In `compose.yaml`, copy a runner service block and change the org name in
   its service name, `container_name`, `RUNNER_ORG`, `LOCK_OWNER`, volume path
   and label.
3. Add the org to `ORGS` in `init.sh`.
4. `sudo ./init.sh && sudo ./register.sh <org> && podman compose up -d --build`

More runners share the same GPU lock, so this adds no GPU contention, only
more queues waiting for it.

## Upgrading the runner

GitHub requires self-hosted runners to stay reasonably current. The runner
updates itself in place when GitHub releases a new version, but a rebuilt
container starts again from the image's version. Every few months, change the
`FROM` line in the `Dockerfile` to a newer release
(https://github.com/actions/runner/releases) and `podman compose up -d
--build`. Registrations are unaffected.

The `FROM` line pins both the tag and the digest of its x86_64 image, because
GitHub re-pushes existing tags. To get the digest for a tag, for example
`2.338.2`:

```bash
podman pull ghcr.io/actions/actions-runner:2.338.2
podman image inspect --format '{{.Digest}}' ghcr.io/actions/actions-runner:2.338.2
```

## Restarting a runner

To restart a runner, use `podman compose restart` or `podman stop`, never
`podman kill`. A stopped runner deletes its GitHub session on the way out
("Deleting Runner Session..."), so it is back and listening within seconds
(3 s when measured). Avoid doing it mid-job if you can: the job fails.

If a runner is killed, crashes, or the VM reboots, it cannot delete its
session, and GitHub treats it as busy for a while:

1. **About 30 s to 3 minutes offline.** When it comes back, its log repeats
   "A session for this runner already exists" until GitHub drops the old
   session. It then reconnects ("Runner reconnected") with no help.
2. **Then, only if it was running a job: "Active" on that job,
   indefinitely.** GitHub still thinks the job is running and sends the
   runner nothing new. Cancel that run on GitHub; the runner's log shows
   "Job cancellation request ... received, cancellation timeout 5 minutes",
   and it goes Idle when those 5 minutes are up. If nobody cancels, it lasts
   until the job's `timeout-minutes`.

The GPU lock is not the problem in either case: the runner clears its own
stale lock as soon as its container starts.

Measured on `vga`: after `podman kill` mid-job (2026-11-18), about 10 minutes
to the next job, with a cancel. After a reboot mid-job (2026-11-19), all
containers were back within 7 s of boot; the runner that had a job
reconnected after 32 s and then stayed Active until its run was cancelled,
and the idle runner reconnected after 2 min 38 s. The reboot stopped the
containers, but they still didn't delete their sessions (the journal isn't
kept across reboots, so it's not known why), so treat a reboot like a crash.

## Removing a runner, or if its credentials leak

In the org on GitHub, Settings → Actions → Runners, remove the runner. Its
credentials stop working immediately. Then delete
`$SVC_SHIRE_DIR/runner-state/<org>/` as the service account, and either
re-register (`sudo ./register.sh <org>`) or remove its block from
`compose.yaml`.

## Monitoring

The `monitoring` container is the gadget monitor's **service VM monitor**. It
serves the VM's CPU, memory, disk and load figures as Prometheus text on
`http://<vm fqdn>:9110/metrics`. The gadget monitor
([middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor))
polls that every minute and graphs it on its **Service VMs** dashboard.
`monitoring/README.md` lists the metrics and explains each compose setting.

**Keep `monitoring/` identical to the gadget monitor's copy.** Do not edit it
in a service repo. To update it, copy the folder over again from the gadget
monitor's repo. The only per-service lines are in `compose.yaml`:
`container_name` (any name unique on the VM) and `labels`.

**Port 9110 is reachable from anywhere.** It is the only published port, and it is
on every interface and does not go through the VM's reverse proxy or TLS,
because the gadget monitor connects to it directly. Podman DNATs the port, so
firewalld does not need to open it. Anyone who can reach the VM can read
these figures. They are resource numbers only, which was judged acceptable.
`monitoring/README.md` explains how to restrict who can read them.

### Registering the VM with the gadget monitor

Deploying the container is not enough on its own. The gadget monitor only
polls VMs listed in its `config/service_vms.toml`. Once the service is
running on its production VM:

1. **Check the endpoint from another machine**, using the production VM's
   own FQDN (what `hostname -f` prints on it, which is also `SVC_FQDN` in
   its `.env`):

   ```bash
   curl -s http://<vm fqdn>:9110/metrics | grep source_success
   ```

   Every `source` should report `1`. If it can't connect, the gadget monitor
   can't either. Fix that first.

2. **Open a pull request** against
   [dirac-institute/middle-earth-gadget-monitor](https://github.com/dirac-institute/middle-earth-gadget-monitor).
   It should add one entry to `config/service_vms.toml`:

   ```toml
   [[service_vm]]
   name = "<service name>"     # becomes the `service_vm` label on the dashboard
   address = "<vm fqdn>"       # the production VM's FQDN, as in step 1
   ```

   - `name` is a short, stable name for the service, typically the repo
     name without its `middle-earth-` prefix. Renaming it later starts new
     series and breaks the VM's history on the dashboard, so choose it once.
     It must not match any existing `name` in the file.
   - `address` must be the production VM, never a dev or test box. A dev
     box's numbers would be graphed as if they were the service's.
   - Add `port` or `metrics_url` only if you changed the monitor's port. With
     the settings in `monitoring/compose.yaml` you never need them.
   - In the PR description, give the service's repo and paste the step 1
     `curl` output, so the reviewer knows the endpoint answers.

   Do not add anything else. The dashboard lists every VM in the file
   automatically.

3. **After it merges and the gadget monitor is redeployed**, the VM
   appears on the **Service VMs** dashboard within a minute or two.

A VM that is retired or renamed needs another PR to remove or change its
entry. Otherwise the dashboard shows it as down.

## Boot persistence

`restart: unless-stopped` only survives reboot if `podman-restart.service` is
enabled, which `init.sh` does. By default it waits only for the network, so
`init.sh` gives it a drop-in
(`/etc/systemd/system/podman-restart.service.d/10-middle-earth-gpu.conf`)
that also makes it wait for:

- **the `/service/shire` NFS mount**, which holds the runners'
  registrations. Without this, a runner can start before the share is
  mounted and fail ("cannot stat `/service/shire/runner-state/...`"); that
  fails the whole `podman-restart.service`, and systemd then kills the other
  containers' `conmon`, so podman loses track of them too. This happened
  once, on 2026-11-19.
- **the container toolkit's `nvidia-cdi-refresh.service`**, which recreates
  the GPU's CDI spec in `/var/run/cdi` at every boot; otherwise the runners
  could start before their GPU device exists.

If containers are missing after a boot, check
`systemctl status podman-restart.service` and
`journalctl -b -u podman-restart`. A job that was running at reboot stays "in progress" on
GitHub, and its runner takes no new jobs, until someone cancels that run;
see "Restarting a runner". Its GPU lock is cleared when its runner
restarts.
