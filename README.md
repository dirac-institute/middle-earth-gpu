# Middle-earth GPU runner

GitHub Actions self-hosted runners on the DiRAC GPU VM (`vga`, an NVIDIA L4),
so that workflows in DiRAC's GitHub orgs can use the GPU, mainly for timing
benchmarks.

| Org | Status |
|---|---|
| `dirac-institute` | Running |
| `lincc-frameworks` | Running |

## How it works

- **One runner per org.** A self-hosted runner can only belong to one GitHub
  org, so each org gets its own runner container on the same VM.
- **One job at a time on the GPU,** across all orgs. Before each job, the
  runner takes a lock shared by all the runners, and checks that the GPU is
  idle. After the job, it releases the lock, even if the job failed or was
  cancelled. A job never shares the GPU, so its timings aren't disturbed by
  other jobs.
- **GitHub decides which code runs here.** In each org, a runner group called
  `middle-earth-gpu` accepts jobs only from listed workflow files on `main`
  of listed repos in that org. Pull requests, including ones from forks,
  never reach this VM.
- **Jobs get the GPU and nothing more:** no `sudo` and no Docker or podman.

It follows the
[middle-earth service example](https://github.com/dirac-institute/middle-earth-service-example):
IT provisions the VM and its service account, secrets live on the
`/service/shire` NFS share, and deployment is `init.sh` plus `podman
compose`.

## Running a job on the GPU

For someone with a repo in `dirac-institute` or `lincc-frameworks` (a
runner group only takes jobs from repos in its own org):

1. **Add a workflow** to your repo, starting from
   [`examples/gpu-benchmark.yml`](examples/gpu-benchmark.yml). Its GPU job
   uses:

   ```yaml
   runs-on:
     group: middle-earth-gpu
     labels: [self-hosted, gpu]
   ```

   Only use the triggers `push` (to `main`), `workflow_dispatch` and
   `schedule`. Never use `pull_request`, `pull_request_target` or
   `workflow_run`.
2. **Merge it to `main`** through a reviewed pull request.
3. **Ask an org admin** to add your repo, and this exact workflow entry, to
   the org's `middle-earth-gpu` runner group:

   ```
   <org>/<repo>/.github/workflows/<file>.yml@refs/heads/main
   ```

   Until they do, the job waits at "Waiting for a runner to pick up this
   job" without any error.
4. **Run it,** and check that its "Set up runner" step says it acquired the
   GPU lock.

[`USING.md`](USING.md) has the details: who needs which permission, what a
job gets and doesn't get, and what to do when a job doesn't start.

**Anyone who can merge to `main` in a listed repo can run code on this VM.**
Read [`SECRETS.md`](SECRETS.md), "Who this trusts", before giving anyone
write access to such a repo.

## Deploying

On the VM, as root (IT has already provisioned the VM, `/root/VM.set` and the
NVIDIA driver):

```bash
git clone git@github.com:dirac-institute/middle-earth-gpu.git /root/middle-earth-gpu
cd /root/middle-earth-gpu
sudo ./init.sh                          # host setup; safe to re-run
sudo ./register.sh dirac-institute      # once per org; asks for a registration token
sudo ./register.sh lincc-frameworks
podman compose up -d --build
```

Each org's runner group has to exist before its runner is registered. Then
check that the runners show as **Idle** on GitHub, and run the **GPU smoke
test** workflow by hand in each org: from this repo in `dirac-institute`, and
from its fork, `lincc-frameworks/middle-earth-gpu`, in `lincc-frameworks`.
The fork exists only for that; all changes go to this repo.

[`DEPLOY.md`](DEPLOY.md) covers all of this in detail: the GitHub-side setup,
the design and its choices, the GPU lock, adding an org, upgrading, restarting
a runner, the GPU driver, SELinux, boot order and monitoring.

## Documentation

| File | Read it when |
|---|---|
| [`USING.md`](USING.md) | You want to run a job on the GPU. |
| [`DEPLOY.md`](DEPLOY.md) | You are deploying, operating or changing the runners. |
| [`SECRETS.md`](SECRETS.md) | You are deciding who gets write access to a repo that uses the GPU, or a runner's credentials may have leaked. |
| [`HANDOFF.md`](HANDOFF.md) | You are finishing the initial deployment: what has been verified, and what is left. |
