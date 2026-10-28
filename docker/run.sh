#!/usr/bin/env bash
# Build the cloudkit-dev image and install CloudKit on a fresh machine inside it.
#
#   docker/run.sh shell [installer options]     shell with CloudKit and its dependencies (default: --yes)
#   docker/run.sh fresh                         empty machine: run the installer by hand
#
# Environment:
#   SOURCE       release (default): the latest GitHub release; local: this working tree
#   DEPS         dependencies baked into the shell image: all (default), aws, gcp, core
#   BASE_IMAGE   base image (default ubuntu:24.04; also debian:12, fedora:41, …)
#   USER_SHELL   login shell of the test user (default /bin/bash; or /bin/zsh)
#   IMAGE        image name (default cloudkit-dev)

set -euo pipefail

DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DOCKER_DIR/.." && pwd)"
BASE_IMAGE="${BASE_IMAGE:-ubuntu:24.04}"
USER_SHELL="${USER_SHELL:-/bin/bash}"
IMAGE="${IMAGE:-cloudkit-dev}"
SOURCE="${SOURCE:-release}"
DEPS="${DEPS:-all}"

case "$DEPS" in
  all | aws | gcp | core) ;;
  *) echo "DEPS must be all, aws, gcp or core (got: $DEPS)" >&2; exit 1 ;;
esac

# The version `ck version` reports inside the container, e.g. v2-3-gabc123-dirty-local.
version_label() {
  local label
  label="$(git -C "$REPO_ROOT" describe --tags --always --dirty 2> /dev/null || echo 0)"
  case "$label" in
    v*) ;;
    *) label="v0-$label" ;;
  esac
  echo "$label-local"
}

# Package the working tree (tracked + untracked, .gitignore respected, top-level
# export-ignore paths from .gitattributes left out like GitHub's tarballs) as a
# release the installer downloads with curl, the same way it fetches a GitHub
# release on a machine without git:
#   $1/release.json                            "latest release" API answer
#   $1/archive/refs/tags/<version>.tar.gz      source archive
#   $1/install.sh                              the installer to pipe to bash
local_release() {
  local out="$1" version stage
  version="$(version_label)"
  stage="$out/stage/cloudkit"
  mkdir -p "$stage" "$out/archive/refs/tags"
  git -C "$REPO_ROOT" ls-files -z --cached --others --exclude-standard \
    | (cd "$REPO_ROOT" && while IFS= read -r -d '' f; do
        [ -e "$f" ] || continue
        [ "$(git check-attr export-ignore -- "${f%%/*}")" = "${f%%/*}: export-ignore: set" ] && continue
        printf '%s\0' "$f"
      done) \
    | (cd "$REPO_ROOT" && xargs -0 tar -cf -) \
    | tar -xf - -C "$stage"
  tar -czf "$out/archive/refs/tags/$version.tar.gz" -C "$out/stage" cloudkit
  rm -rf "$out/stage"
  printf '{\n  "tag_name": "%s"\n}\n' "$version" > "$out/release.json"
  cp "$REPO_ROOT/install.sh" "$out/install.sh"
  chmod -R a+rX "$out"
}

cmd="${1:-shell}"
[ $# -gt 0 ] && shift
case "$cmd" in
  shell | fresh) ;;
  *) echo "Usage: docker/run.sh shell [installer options] | fresh" >&2; exit 1 ;;
esac

# The shell starts with dependencies preinstalled; everything else tests a
# truly fresh machine.
target=fresh
quiet="-q"
suffix=""
if [ "$cmd" = shell ]; then
  target=deps
  suffix="-deps-$DEPS"
  # Show progress: the first build downloads the AWS CLI and/or gcloud (a few minutes)
  quiet=""
fi

tag="$IMAGE:$(echo "$BASE_IMAGE" | tr ':/' '--')-$(basename "$USER_SHELL")$suffix"
# shellcheck disable=SC2086
docker build $quiet -f "$DOCKER_DIR/Dockerfile" \
  --build-context repo="$REPO_ROOT" \
  --target "$target" \
  --build-arg BASE_IMAGE="$BASE_IMAGE" \
  --build-arg USER_SHELL="$USER_SHELL" \
  --build-arg DEPS="$DEPS" \
  -t "$tag" "$DOCKER_DIR" > /dev/null

mount=""
if [ "$SOURCE" = local ]; then
  local_dir="$(mktemp -d)"
  trap 'rm -rf "$local_dir"' EXIT
  local_release "$local_dir"
  mount="-v $local_dir:/local:ro"
fi

# Both modes are interactive shells.
tty_flag=""
case "$cmd" in
  shell | fresh) tty_flag="-it" ;;
esac

# shellcheck disable=SC2086
docker run --rm $tty_flag $mount \
  -e CK_SOURCE="$SOURCE" \
  "$tag" "$cmd" "$@"
