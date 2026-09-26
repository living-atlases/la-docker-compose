# Contributing to la-docker-compose

Thanks for helping. This repo deploys a [Living Atlas](https://living-atlases.gbif.org/) portal on Docker Compose, driven by Ansible. Most users never clone it: [la-toolkit](https://github.com/living-atlases/la-toolkit) and [generator-living-atlas](https://github.com/living-atlases/generator-living-atlas) pull it in. This guide is for people changing the repo itself.

## Where to start

- Issues labelled [`good first issue`](https://github.com/living-atlases/la-docker-compose/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) are self-contained: a script or a check, with a clear way to prove it works, and no cluster needed.
- Issues labelled [`help wanted`](https://github.com/living-atlases/la-docker-compose/issues?q=is%3Aissue+is%3Aopen+label%3A%22help+wanted%22) are bigger or need knowledge we lack: a service we do not cover yet, Airflow ingestion, or experience running a real portal.
- Running a Living Atlas yourself? Reports of what breaks on your inventory are as valuable as code. Open an issue with the service, the symptom, and the first error line of the container log.

Comment on an issue before starting a large piece of work, so nobody duplicates it.

## Ground rules

1. **Every change goes through Ansible.** `/data/docker-compose/` (compose files, `.env`, nginx confs…) is generated. A fix made there by hand is lost on the next `ansiblew` run. Fix the role, task or template in this repo, regenerate, and check that a second run changes nothing. Editing the generated files is fine for finding the root cause, never as the fix.
2. **`ala-install/` is a submodule shared with VM deployments.** A change there must keep working when the same role is deployed on a VM. Gate container-only behaviour on the deployment type instead of changing the VM path.
3. **Every fix comes with a check that fails without it.** That can be a molecule test case, a `scripts/test-*.sh` fixture, or a new check in `scripts/validate-config-gen.sh`. A check that stays green on the broken code does not count.
4. **No site-specific data.** No real hostnames, IPs, credentials or inventories in code, comments, tests or issues. Use `example.org` style names in fixtures.

## Setup

```bash
git clone --recurse-submodules git@github.com:living-atlases/la-docker-compose.git
```

See [Prerequisites](README.md#prerequisites) for the Docker Compose, Node and Ansible versions that matter, and [Testing & local development](README.md#testing--local-development) for the local deploy loop.

## Checks to run before opening a PR

Pick the ones that cover the files you touched. None of them needs a cluster.

| You changed | Run |
|---|---|
| `roles/la-compose/**`, `molecule/**` | `python3 scripts/check-jinja-syntax.py`, `bash scripts/test-compose-includes.sh`, `molecule test -s unit`, `molecule test -s multihub` |
| Any Ansible YAML | `ansible-lint` (FQCN names are enforced) |
| `Jenkinsfile` | `bash scripts/check-jenkinsfile.sh` |
| A `scripts/foo.sh` with a `scripts/test-foo.sh` next to it | that test |
| Rendered config (templates, vars) | `scripts/validate-config-gen.sh` (slow: it renders the whole stack) |

[`.andon/checks.json`](.andon/checks.json) maps file patterns to the check that covers them. It is a good index when you are unsure.

## Pull requests

- One topic per PR, with a description that says what was broken, why, and how you proved the fix.
- Commit messages explain the *why*. The diff already shows the *what*.
- CI deploys the full stack to a test cluster. Maintainers trigger it, so a PR from a fork will not run it by itself.

## License

By contributing you agree that your work is released under this repository's [LICENSE](LICENSE).
