# Running a job on the GPU runner

How to get a workflow in your repo onto the DiRAC GPU VM. The short version is
in the [README](README.md#running-a-job-on-the-gpu); this file has the details.

## Who does what

Three people may be involved; they can be the same person.

| Step | Who | Permission needed |
|---|---|---|
| Write the workflow and open a pull request | You | Write access to the repo |
| Review and merge it to `main` | A maintainer | Whatever the repo's branch protection requires |
| Protect `main` (once per repo) | A repo admin | Admin on the repo |
| Add the repo and workflow to the runner group | An org admin | Org owner, or an org role with "Manage organization runners and runner groups" |
| Start a manual run (`workflow_dispatch`) | Anyone with write access | Write access to the repo |

Repo admins cannot change the runner group: it is an org setting. DEPLOY.md,
"GitHub-side setup", lists who can change it in each org.

The runner is set up for `dirac-institute`. `lincc-frameworks` is planned but
not yet running.

## 1. Write the workflow

Start from [`examples/gpu-benchmark.yml`](examples/gpu-benchmark.yml). The
rules:

- **Target the runner group** in the GPU job:

  ```yaml
  runs-on:
    group: middle-earth-gpu
    labels: [self-hosted, gpu]
  ```

- **Trusted triggers only:** `push` with `branches: [main]`,
  `workflow_dispatch`, and `schedule`. Never `pull_request`,
  `pull_request_target` or `workflow_run`: the first never matches the
  allowlist, and the other two run from `main` (so they *do* match) but can
  be made to run a pull request's code. Run pull request CI on
  GitHub-hosted runners, in a separate workflow file.
- **Not `release`, and not runs from other branches.** The allowlist entry is
  pinned to `refs/heads/main`. A `release` run happens at the release's tag,
  and a manual run started from another branch happens at that branch, so
  neither matches; they wait forever.
- **Put the GPU job directly in the listed file.** A job in a reusable
  workflow called from the listed file is defined in a different file, so it
  does not match.
- **Keep the file name.** The allowlist names the file. Renaming or moving it
  needs a new allowlist entry.
- **Set `timeout-minutes`.** Time spent waiting for the GPU counts toward it.
  The example uses 240.
- **Record the environment with your results:** `GPU_LOCK_OWNER`,
  `GPU_LOCK_WAIT_SECONDS` and `GPU_DRIVER_VERSION` are set in every job.

## 2. Merge it to `main`

Open a pull request and get it reviewed. The workflow does not run on the
pull request (it has no `pull_request` trigger), and could not reach the VM if
it did.

Everything on `main` in a listed repo runs on this VM: the workflow, and any
tests, scripts, build files and dependencies it runs. So `main` must be
protected before the repo is listed (next step).

## 3. Get it allowlisted

Ask an org admin to do these in the org's settings, under **Settings → Actions
→ Runner groups → `middle-earth-gpu`**:

- **Repository access:** add the repo to the selected repositories.
- **Workflow access:** add this exact entry (selected workflows only):

  ```
  <org>/<repo>/.github/workflows/<file>.yml@refs/heads/main
  ```

  For example,
  `dirac-institute/middle-earth-gpu/.github/workflows/gpu-smoke-test.yml@refs/heads/main`.

Before adding it, the admin should check:

- `main` requires a reviewed pull request to merge (Settings → Branches, or
  Rules), and consider a CODEOWNERS entry for `.github/workflows/`.
- The workflow uses only the triggers above.
- Everyone who can merge to `main` is someone they would trust with a shell on
  the VM. See [`SECRETS.md`](SECRETS.md), "Who this trusts".

The group's "Allow public repositories" setting is already on; that's needed
because these repos are public.

## 4. Run it and check

Trigger it (for `workflow_dispatch`: Actions → your workflow → Run workflow,
on `main`). In the job log:

- **"Set up runner"** shows `Acquired GPU lock as '<org>' after waiting Ns`,
  `GPU is idle`, and the GPU's clocks, temperature and power. If another job
  holds the GPU, it shows who, and waits.
- **"Complete runner"** shows the lock being released.

## What a job gets

- **The GPU, exclusively, for the whole job.** The NVIDIA driver's libraries
  are there, but not the CUDA *runtime*: get it the usual way for your stack
  (PyTorch and JAX wheels bundle it, or use conda).
- **Ubuntu 24.04**, from GitHub's runner image. `actions/setup-python` and
  similar actions work, and cache downloads between jobs.
- **The environment variables above**, for recording with results.

## What a job does not get

- **No `sudo`**, so no system packages. If many jobs need something, ask for it
  to be added to the runner image (`Dockerfile`).
- **No containers.** There is no Docker or podman, so container actions and
  `services:` don't work.
- **No clean machine.** The runner is persistent: anything a job leaves
  outside its workspace (for example in `$HOME`) is still there for the next
  job, from any repo.
- **No parallelism.** One job at a time across all orgs. Keep GPU jobs short,
  and don't run them on every push if they don't need to.

## When a job doesn't start

| What you see | Why | Fix |
|---|---|---|
| "Waiting for a runner to pick up this job", indefinitely | The repo isn't in the group's repository access, the workflow entry is missing or doesn't match exactly, or the run isn't at `refs/heads/main` (see above). GitHub gives no error. | Fix the entry or the trigger, then **cancel the run and start a new one**: a queued run is not matched again. |
| "Set up runner" says `GPU in use by ...` | Another job holds the GPU. | Nothing: it runs when that job finishes, or fails after 3 hours of waiting. |
| "Set up runner" fails with "The GPU is not idle" | Something outside the runners is using the GPU. | Tell the VM's operators (DEPLOY.md). |
| The runner shows "Offline", or "Active" with nothing running | It was restarted or crashed mid-job. | It recovers by itself; see DEPLOY.md, "Restarting a runner". |

Anything else: ask your org's admins for the runner group (listed in
DEPLOY.md, "GitHub-side setup").
