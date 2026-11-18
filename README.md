# Middle-earth GPU runner

GitHub Actions self-hosted runners for the DiRAC GPU VM, so workflows in the
`dirac-institute` and `lincc-frameworks` GitHub orgs can fill the GPU and
collect timing benchmarks.

- One runner container per org (a runner can only belong to one org), both on
  this VM, taking turns on the GPU: one job at a time, across both orgs.
- Only listed workflow files on `main` can use them, so pull requests from
  forks never run here. That is enforced in each org's GitHub settings.
- Follows the [middle-earth service example](https://github.com/dirac-institute/middle-earth-service-example):
  clone, `sudo ./init.sh`, `podman compose up -d --build`.

**Deploying or operating it:** read `DEPLOY.md`.
**Before giving anyone write access to a repo that uses it:** read
`SECRETS.md`, "Who this trusts".
**Using it from a workflow:** copy `examples/gpu-benchmark.yml` and see
DEPLOY.md, "Using the runner".
