# Usage and examples

[Docs home](README.md) › Usage and examples

Every `make` target, what it runs, and when to use it. Run them from this repository's folder.

| Target | Runs | Use it to |
| :--- | :--- | :--- |
| `make help` | prints the main targets | see what is available |
| `make doctor` | [`scripts/doctor.sh`](../scripts/doctor.sh) | check `yq`, the Python version against `config/config.yaml`, and the shared virtual environment |
| `make clone` | [`scripts/clone-repo.sh`](../scripts/clone-repo.sh) | clone the repositories in [`local/repo.yaml`](../local/repo.yaml) into the parent folder; existing ones are skipped |
| `make sync mode=git` | [`scripts/sync_git.sh`](../scripts/sync_git.sh) `git` | pull, re-pin to GitHub commits, `poetry update` |
| `make sync mode=local` | [`scripts/sync_git.sh`](../scripts/sync_git.sh) `local` | pull, point dependencies at sibling folders, `poetry lock` and `poetry install` |
| `make local` | [`scripts/deploy.sh`](../scripts/deploy.sh) `local` | start every package and module in the background |
| `make logs` | `deploy.sh logs` | follow all logs together |
| `make kill` | `deploy.sh kill` | stop what `make local` started |
| `make push` | [`scripts/push_git.sh`](../scripts/push_git.sh) | sync, commit and push every repository |
| `make venv` | prints `source scripts/venv.sh` | activate the shared virtual environment (must be sourced) |
| `make debug-config` | [`vscode/debug_launch.py`](../vscode/debug_launch.py) | generate VS Code debug launch settings |
| `make tdbcli-install-user` | copies `scripts/tdbcli.sh` to `~/.local/bin/tdbcli` | use `tdbcli` without `sudo` |
| `make tdbcli-install` | copies it to `/usr/local/bin` with `sudo` | install for all users |
| `make tdbcli-uninstall` | removes both installs and `~/.tdbcli` | clean up |

## Start a full local stack

```bash
make doctor
make clone
make sync mode=local
make local
make logs
```

`deploy.sh` reads three switches from the environment:

| Variable | Default | Meaning |
| :--- | :--- | :--- |
| `LOCAL_SYNC` | `0` | `1` runs `make sync` in each repository before starting it |
| `LOCAL_STRICT` | `1` | `1` fails a repository that lacks a required target; `0` skips it |
| `LOCAL_SYNC_STRICT` | `0` | `1` treats a failed sync as a failure for that repository |

Example: `LOCAL_STRICT=0 make local` starts whatever can start and skips the rest.

## Work on one base package and see it everywhere

```bash
make sync mode=local      # every repository now imports ../base-tdb-* directly
# edit ../base-tdb-models, the services reload on save
make sync mode=git        # re-pin to the commits you have checked out
```

Review every `pyproject.toml` and `poetry.lock` diff before committing. `mode=git` runs `poetry update`, which can move other dependencies too.

## Push safely

`make push` commits everything in every repository. A safer pattern for a change that spans repositories:

```bash
for d in ../base-tdb-models ../package-named-entity-linker; do
  git -C "$d" status --short
done
# then commit and push each repository on its own branch, and open one pull request per repository
```

## Deploy with Ansible

```bash
cd ansible
ansible-galaxy install -r requirements.yml
ansible-playbook -i inventories/local/hosts.yml site.yml
```

Set environment specific values in `group_vars/staging.yml` or `group_vars/prod.yml`. Secrets are handled by the `secrets` role; never commit them.

---

**Related:** [Architecture](architecture.md) · [Troubleshooting](troubleshooting.md) · [README](../README.md)
