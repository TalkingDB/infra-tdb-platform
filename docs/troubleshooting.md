# Troubleshooting

[Docs home](README.md) › Troubleshooting

| Symptom | Likely cause | Fix |
| :--- | :--- | :--- |
| `❌ yq is required` | `make clone`, `make doctor` and `venv.sh` read YAML with yq | Install [mikefarah/yq](https://github.com/mikefarah/yq) (the Go version, not the Python wrapper) |
| `❌ Python 3.x found, but >= 3.12 required` | Older Python on the `PATH` | Install Python 3.12; `sync_git.sh` uses `PYTHON_BIN` (default `python3.12`) for [Poetry](https://python-poetry.org/docs/) |
| `make clone` did not fetch parse-tree, document search, search trainer or ecommerce AI | `local/repo.yaml` lists only six repositories | Clone the others into the same parent folder by hand, or add them to `local/repo.yaml` |
| `make local` reports a repository missing target `local` | That repository's Makefile has no `local` target (for example a frontend) | Run it on its own, or `LOCAL_STRICT=0 make local` to skip it |
| `deploy.sh up` reports `missing target: dev` for every repository | No package or module defines the `dev`, `down`, `log` contract yet | Use `make local`, `make logs` and `make kill` |
| module-ttt fails with `infisical: command not found` | Its `make local` loads secrets with [Infisical](https://infisical.com/docs) by default | Install the Infisical CLI, or run with `SECRETS_MODE=dotenv` and a `.env` file in module-ttt |
| A service fails on `--reload-dir ../base-tdb-models` | A sibling repository is missing | `make clone`, or clone it by hand next to the others |
| `make sync` stops with "Pull failed", or a repository is skipped | Local changes or a diverged branch block `git pull --ff-only` | Commit, stash or rebase in that repository, then run sync again |
| After `make sync mode=git`, many lockfiles changed | Git mode runs `poetry update` in each repository | Expected; review and commit them deliberately, or revert the ones you did not intend |
| `make push` committed and pushed unfinished work | It runs `git add .`, commits and pushes in every repository | Revert it in that repository with `git revert <commit>` and push the revert; push per repository in future |
| `tdbcli`: "Could not find repo root" | Not run from inside this repository and no config yet | Run once from this folder, set `AW_REPO_ROOT`, or write `REPO_ROOT=/path` to `~/.tdbcli/config` |
| Scripts fail on Windows with `$'\r': command not found` | Windows line endings in a checkout | Use [WSL](https://learn.microsoft.com/en-us/windows/wsl/about) with `git config core.autocrlf input`, then check the files out again |

---

**Related:** [Architecture](architecture.md) · [Usage and examples](usage-and-examples.md) · [README](../README.md)
