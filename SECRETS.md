# Secrets and trust

No secret is ever committed to this repo or baked into a container image.

## What is secret here

Each runner's **registration**: three files that `register.sh` creates when it
registers the runner with GitHub.

| File | Contents |
|---|---|
| `.runner` | Which org and runner group, the runner's id and name. |
| `.credentials` | How the runner authenticates to GitHub. |
| `.credentials_rsaparams` | The runner's private key. |

Together they are a bearer credential: anyone who copies them can pretend to
be this runner and receive its jobs, including any secrets those jobs are
given. They do not expire on their own; removing the runner in GitHub revokes
them (see DEPLOY.md, "Removing a runner, or if its credentials leak").

Nothing else is stored. In particular there is no GitHub token, personal
access token or GitHub App key on this VM. The **registration token** that
`register.sh` asks for is only good for registering, and only for an hour, so
it's fine for an org owner to send it to whoever runs `register.sh`.

## Where they live

On the `/service/shire` NFS share, one directory per org, bind-mounted into
that org's runner container (read-write: the runner may rewrite them):

```
$SVC_SHIRE_DIR/runner-state/dirac-institute/     0755  $SVC_USER
$SVC_SHIRE_DIR/runner-state/dirac-institute/.*   0600  $SVC_USER
$SVC_SHIRE_DIR/runner-state/lincc-frameworks/    0755  $SVC_USER
$SVC_SHIRE_DIR/runner-state/lincc-frameworks/.*  0600  $SVC_USER
```

`SVC_SHIRE_DIR` is set at the top of `init.sh` and written to `.env`.
Directories are 0755 so podman, running as root, can mount them; the files
are 0600 so only the service account can read them. Each container mounts
only its own org's directory.

## Ownership and root_squash

`/service/shire` is exported with `root_squash`, so **root on the VM cannot
write to it** — root is mapped to `nobody`. The tree is owned by the service
account named in IT's `/root/VM.set` (`VMUSER`, `VMUID`, `VMGID`), which
`init.sh` also writes to the repo's `.env` as `SVC_USER`, `SVC_UID`, `SVC_GID`.

`register.sh` does its writes as that account. To inspect or remove a
registration by hand, become that user (in bash, `source .env` in the repo
directory first to set the `SVC_*` names):

```bash
setpriv --reuid=$SVC_UID --regid=$SVC_GID --clear-groups \
    ls -la $SVC_SHIRE_DIR/runner-state/dirac-institute/
```

The containers must *run* as that uid, or they cannot read mode-0600 files on
the share. The image creates a user with that uid/gid and the compose file sets
`user:` accordingly. All three values come from `VM.set` (via `.env`) with no
hardcoded defaults.

## Who this trusts

Read this before giving anyone write access to a repo that uses this runner.

1. **Merging to `main` in a repo whose workflow is on a `middle-earth-gpu` runner group's
   allowlist is equivalent to running code on this VM as the service
   account.** The workflow runs whatever is on `main`: tests, scripts, build
   files, dependencies.
2. **That code can read the runner's registration** and so impersonate the
   runner. Containers keep each org's registration apart, but they are not a
   strong boundary against a determined job.
3. Therefore **grant merge rights on those repos on the same terms as root SSH
   access to this VM.** When this was set up (November 2026), the two were the
   same people, in both orgs. "Who has access", below, says where to check
   each.

What keeps everyone else out is GitHub's runner group settings, not anything
in this repo: only listed workflow files at `refs/heads/main` can use the
runners, so pull requests from forks never reach this VM. See DEPLOY.md,
"GitHub-side setup". If those settings are loosened, this trust model no
longer holds.

If that ever stops being true — for example, write access widens to people
you would not give a shell — move to ephemeral runners (one fresh container
and single-use registration per job), and re-read this file.

## Who has access

Access is granted on GitHub and in the services spreadsheet, so look it up
there. Don't copy names into this repo; they would go out of date.

| Who | What they can do here | Where to look |
|---|---|---|
| **Org owners** in each org | Change the `middle-earth-gpu` runner group, so which repos and workflows run on this VM; issue registration tokens; remove a runner | [dirac-institute owners](https://github.com/orgs/dirac-institute/people?query=role%3Aowner), [lincc-frameworks owners](https://github.com/orgs/lincc-frameworks/people?query=role%3Aowner) (visible to org members) |
| Anyone given an org role with "Manage organization runners and runner groups" | The same, for runner groups | The org's Settings → Organization roles → Role assignments (visible to owners) |
| **Maintainers** of each repo on a runner group's list (anyone who can merge to `main`) | Run code on this VM, as the service account (above) | The repo's Settings → Collaborators and teams, for example [this repo's](https://github.com/dirac-institute/middle-earth-gpu/settings/access) (visible to repo admins). Which repos are listed: the org's Settings → Actions → Runner groups → `middle-earth-gpu` |
| **Root on `vga`** | Everything, including reading the registrations as the service account | [Services spreadsheet](https://docs.google.com/spreadsheets/d/14ryGw2b2tsHqK27PX1YHzvvZDDEbCNak8C2At-3fgg8/edit?gid=0#gid=0) |
