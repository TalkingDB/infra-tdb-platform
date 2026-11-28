<!-- short-readme -->
<h1 align="center">infra-tdb-platform</h1>

<p align="center"><b>Clone, sync, run and deploy every TalkingDB service from one folder.</b></p>

<p align="center"><a href="#try-it">Try it</a> · <a href="docs/architecture.md">How it works</a> · <a href="docs/usage-and-examples.md">Usage and examples</a> · <a href="docs/troubleshooting.md">Troubleshooting</a> · <a href="docs/reference.md">Full reference</a></p>

<p align="center"><a href="https://github.com/TalkingDB/infra-tdb-platform/stargazers"><img src="https://img.shields.io/github/stars/TalkingDB/infra-tdb-platform?style=social" alt="GitHub stars"></a> <a href="https://www.gnu.org/licenses/agpl-3.0.html"><img src="https://img.shields.io/badge/license-AGPL--3.0-blue" alt="AGPL-3.0"></a></p>

<p align="center">
  <img src="docs/images/demo.gif" alt="Animated demo: the real output of make help and make doctor, the six repositories listed in local/repo.yaml, then the four release workflows and the script behind each">
</p>
<p align="center"><sub><code>make help</code> and <code>make doctor</code> are a real run at <code>398b8f2</code>; the workflows are read from the repo.</sub></p>

A Makefile and scripts that clone every repository, keep their dependency pins in step, run all services on one machine, and deploy with [Ansible](https://docs.ansible.com/) and [GitHub Actions](https://docs.github.com/en/actions).

## What it does

- **Clone** the repositories in `local/repo.yaml` next to this one.
- **Sync** pins and local checkouts with `make sync mode=local|git` ([local workflow](docs/architecture.md)).
- **Release** through four reusable workflows: sync, build, deploy, notify ([usage](docs/usage-and-examples.md)).

## Try it

```bash
git clone https://github.com/TalkingDB/infra-tdb-platform.git && cd infra-tdb-platform
make doctor        # checks yq, Python and the shared virtual environment
make clone
make sync mode=local
make local         # every ../package-* and ../module-*
```

Needs Bash, Git, Python 3.12, [Poetry](https://python-poetry.org/docs/) and [yq](https://github.com/mikefarah/yq).

## Where it fits

It drives all the other repositories as a group.

## Learn more

| Page | Read it to |
| :--- | :--- |
| [How it works](docs/architecture.md) | see the parts and how data moves |
| [Usage and examples](docs/usage-and-examples.md) | copy working examples |
| [Troubleshooting](docs/troubleshooting.md) | fix a problem |
| [Full reference](docs/reference.md) | read everything that used to be on this page |
| [All docs](docs/README.md) | see every page |

## Support TalkingDB

If infra-tdb-platform saved you time, please [give it a star](https://github.com/TalkingDB/infra-tdb-platform) ⭐. Stars help other developers find the project.

Found a bug, or a document it gets wrong? [Open an issue](https://github.com/TalkingDB/infra-tdb-platform/issues/new). We are always here to help and open to a conversation. Explore the TalkingDB applications at [talkingdb.io](https://talkingdb.io/#applications).

## License

Licensed under the GNU Affero General Public License v3.0 ([AGPL-3.0](https://www.gnu.org/licenses/agpl-3.0.html)). See [LICENSE](LICENSE).
