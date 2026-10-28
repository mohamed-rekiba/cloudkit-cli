#!/usr/bin/env bash
# Tag main and publish a GitHub release, so the installer URL
#   https://github.com/<repo>/releases/latest/download/install.sh
# serves the new version.
#
#   scripts/release.sh <version> [--yes] [--dry-run]
#   make release VERSION=v3 [YES=1] [DRY_RUN=1]
#
# Steps: check main is clean and up to date, run the tests, create an
# annotated tag, push main and the tag, create the release (marked latest,
# install.sh attached, notes generated), then check the latest download URL.
# Needs git and an authenticated gh (gh auth login).

set -euo pipefail

REMOTE="${RELEASE_REMOTE:-origin}"
BRANCH="main"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

info() { printf "%s==>%s %s\n" "${CYAN}" "${NC}" "$*"; }
ok() { printf "  %s✓%s %s\n" "${GREEN}" "${NC}" "$*"; }
warn() { printf "  %s!%s %s\n" "${YELLOW}" "${NC}" "$*"; }
die() { printf "%sError:%s %s\n" "${RED}" "${NC}" "$*" >&2; exit 1; }

usage() {
  sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
}

VERSION="" ASSUME_YES=false DRY_RUN=false
while [ $# -gt 0 ]; do
  case "$1" in
    -y | --yes) ASSUME_YES=true ;;
    -n | --dry-run) DRY_RUN=true ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "Unknown option: $1" ;;
    *) VERSION="$1" ;;
  esac
  shift
done

[ -n "$VERSION" ] || { usage >&2; die "Missing version, e.g. make release VERSION=v3"; }
case "$VERSION" in
  v*) ;;
  *) VERSION="v$VERSION" ;;
esac
# v3, v3.1, v3.1.0 — the installer picks the newest v* tag with sort -V
echo "$VERSION" | grep -Eq '^v[0-9]+(\.[0-9]+){0,2}$' \
  || die "Invalid version '$VERSION' (expected v<major>[.<minor>[.<patch>]], e.g. v3 or v3.1.0)"

cd "$(git rev-parse --show-toplevel)"
command -v gh > /dev/null 2>&1 || die "gh (GitHub CLI) is required: https://cli.github.com"

# owner/name of the remote; passed to every gh call so it never picks another remote
REPO="$(git remote get-url "$REMOTE" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')"
[ -n "$REPO" ] || die "Could not read the GitHub repository from remote '$REMOTE'"
gh auth status --hostname github.com > /dev/null 2>&1 || die "gh is not logged in: run gh auth login"

info "Checking $BRANCH"
[ "$(git rev-parse --abbrev-ref HEAD)" = "$BRANCH" ] || die "Not on $BRANCH (git switch $BRANCH)"
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "Uncommitted changes; commit or stash them first"
git fetch --quiet --tags "$REMOTE" "$BRANCH"
behind="$(git rev-list --count "HEAD..$REMOTE/$BRANCH")"
ahead="$(git rev-list --count "$REMOTE/$BRANCH..HEAD")"
[ "$behind" -eq 0 ] || die "$BRANCH is $behind commit(s) behind $REMOTE/$BRANCH (git pull --ff-only)"
ok "$BRANCH at $(git log -1 --format='%h %s')"

if git rev-parse -q --verify "refs/tags/$VERSION" > /dev/null \
  || [ -n "$(git ls-remote --tags "$REMOTE" "refs/tags/$VERSION")" ]; then
  die "Tag $VERSION already exists"
fi
previous="$(gh release view --repo "$REPO" --json tagName --jq .tagName 2> /dev/null || true)"
if [ -n "$previous" ]; then
  newest="$(printf '%s\n%s\n' "$previous" "$VERSION" | sort -V | tail -n 1)"
  [ "$newest" = "$VERSION" ] || die "$VERSION is not newer than the latest release $previous"
fi
ok "$VERSION is new (latest release: ${previous:-none})"

info "Running tests"
make --no-print-directory test > /dev/null || die "Tests failed (run make test)"
ok "make test"
if command -v shellcheck > /dev/null 2>&1; then
  make --no-print-directory shellcheck > /dev/null || die "Shellcheck failed (run make shellcheck)"
  ok "make shellcheck"
else
  warn "shellcheck not installed; skipped (CI runs it)"
fi

printf "\n%sRelease %s%s of %s\n" "${BOLD}" "$VERSION" "${NC}" "$REPO"
printf "  commit    %s\n" "$(git log -1 --format='%h %s')"
if [ "$ahead" -gt 0 ]; then
  printf "  push      %s commit(s) to %s/%s, plus tag %s\n" "$ahead" "$REMOTE" "$BRANCH" "$VERSION"
else
  printf "  push      tag %s\n" "$VERSION"
fi
printf "  release   CloudKit %s (latest), asset install.sh, notes since %s\n\n" "$VERSION" "${previous:-the first commit}"

if [ "$DRY_RUN" = true ]; then
  info "Dry run: nothing tagged, pushed or published"
  exit 0
fi
if [ "$ASSUME_YES" = false ]; then
  printf "Publish? [y/N] "
  read -r answer < /dev/tty || answer=""
  case "$answer" in
    [Yy]*) ;;
    *) die "Aborted" ;;
  esac
fi

info "Tagging $VERSION"
git tag -a "$VERSION" -m "CloudKit $VERSION"
info "Pushing $BRANCH and $VERSION to $REMOTE"
if ! git push --atomic "$REMOTE" "$BRANCH" "refs/tags/$VERSION"; then
  git tag -d "$VERSION" > /dev/null
  die "Push failed; local tag $VERSION removed"
fi

asset_dir="$(mktemp -d)"
trap 'rm -rf "$asset_dir"' EXIT
git show "$VERSION:install.sh" > "$asset_dir/install.sh"

notes="$(cat << EOF
## Install

\`\`\`bash
curl -fsSL https://github.com/$REPO/releases/latest/download/install.sh | bash
\`\`\`

Already installed? Re-run the same command to upgrade, then check with \`ck version\`.
EOF
)"

info "Creating the GitHub release"
release_args=(--repo "$REPO" --title "CloudKit $VERSION" --notes "$notes" --generate-notes --latest --verify-tag)
[ -n "$previous" ] && release_args+=(--notes-start-tag "$previous")
gh release create "$VERSION" "$asset_dir/install.sh" "${release_args[@]}" \
  || die "Release failed; tag $VERSION is pushed. Retry: gh release create $VERSION install.sh --repo $REPO --latest --generate-notes"

info "Checking the latest download URL"
url="https://github.com/$REPO/releases/latest/download/install.sh"
for _ in 1 2 3 4 5; do
  if curl -fsSL "$url" 2> /dev/null | cmp -s - "$asset_dir/install.sh"; then
    ok "$url serves $VERSION"
    printf "\n%sReleased %s%s: https://github.com/%s/releases/tag/%s\n" "${GREEN}" "$VERSION" "${NC}" "$REPO" "$VERSION"
    exit 0
  fi
  sleep 3
done
warn "$url does not serve the $VERSION install.sh yet (GitHub caching?); check the release page"
