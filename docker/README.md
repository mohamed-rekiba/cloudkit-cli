# Fresh-install testing in Docker

Try `install.sh` and `ck` on a clean machine without touching your own `~/.zshrc`, `~/.aws` or gcloud config.

The image is a stock Linux (Ubuntu 24.04 by default) with a non-root user (`dev`, passwordless sudo) plus `curl` — nothing else, not even git. Containers are removed when you leave the shell.

## Quick start

```bash
make docker-shell                 # fresh machine with the latest release installed, ck ready
make docker-shell SOURCE=local    # same, with your working tree (uncommitted changes included)
make docker-fresh                 # empty machine: run the installer yourself
```

## Targets

| Command | What it does |
|---|---|
| `make docker-shell` | Installs CloudKit, checks the install, opens a shell where `ck` works. Dependencies (AWS CLI, gcloud, …) are baked into the image, so `ck doctor` is green |
| `make docker-fresh` | Prints the install command and opens a shell on an empty machine, so you can walk through the installer's questions (which clouds, dependencies, `ck setup`) |

Options, set on the `make` command line or in the environment:

| Variable | Values | Effect |
|---|---|---|
| `SOURCE` | `release` (default), `local` | Install the latest GitHub release, or your working tree |
| `DEPS` | `all` (default), `aws`, `gcp`, `core` | Tools baked into the `docker-shell` image |
| `BASE_IMAGE` | `ubuntu:24.04` (default), `debian:12`, `fedora:41`, … | The machine (`apt` or `dnf`) |
| `USER_SHELL` | `/bin/bash` (default), `/bin/zsh` | The user's login shell, so `~/.bashrc` or `~/.zshrc` |

Pass your own installer options by calling the script directly:

```bash
docker/run.sh shell --yes --no-rc
```

## Image sizes

| Image | Size |
|---|---|
| `docker-fresh` | ~90 MB |
| `docker-shell DEPS=core` | jq + python3 only |
| `docker-shell DEPS=aws` | ~400 MB |
| `docker-shell` (`DEPS=all`) | ~1.1 GB (mostly gcloud) |

The `docker-shell` image runs the installer's dependency step at build time, so the first build takes a few minutes. Docker then caches it until `install.sh` changes. Each `DEPS` / `BASE_IMAGE` / `USER_SHELL` combination gets its own tag (`cloudkit-dev:ubuntu-24.04-bash-deps-aws`, …).

## What `docker-shell` checks

Before opening the shell:

1. `~/.cloudkit` exists and is marked as installer-managed
2. The rc file has exactly one `cloudkit` block that sources `~/.cloudkit/main.sh`
3. `ck help` works in a new interactive shell
4. The installed version is recorded, and `ck version` reports it (on releases that have `ck version`)
5. `ck doctor` reports no missing required tools (skipped with `--no-deps`)

Run the same checks again any time inside the container with `ck-test-install verify`.

## How `SOURCE=local` works

`docker/run.sh` packages your working tree (tracked and untracked files, `.gitignore` respected, **including uncommitted changes**) as a fake GitHub release: a `release.json` naming the version (e.g. `v2-3-gabc123-dirty-local`) and a source tarball. Both are mounted read-only at `/local`, and `install.sh` downloads from there with `curl`.

That goes through the same code path as `curl … | bash` on a machine without git. Running `./install.sh` from a clone would skip the download and use the clone in place.

## Files

```
docker/Dockerfile         the fresh machine (targets: fresh, deps)
docker/run.sh             host side: builds the image, packages SOURCE=local, runs the container
docker/test-install.sh    container side: install, verify, shell (ck-test-install)
```
