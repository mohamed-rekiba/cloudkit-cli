#!/usr/bin/env bash
# Runs inside the cloudkit-dev container (see docker/Dockerfile).
#
#   ck-test-install shell [installer options]    install CloudKit, then open a shell with ck
#   ck-test-install fresh                        open a shell to run the installer by hand
#   ck-test-install verify                       check an existing install
#
# CK_SOURCE picks what gets installed:
#   release (default)  the latest GitHub release, via `curl … | bash`
#   local              the working tree, packaged by docker/run.sh as a fake
#                      release under /local (release.json + archive tarball), so
#                      uncommitted changes go through the same download path

set -euo pipefail

LOCAL="${CK_LOCAL:-/local}"
SOURCE="${CK_SOURCE:-release}"
RELEASE_URL="https://github.com/shabayekdes/cloudkit-cli/releases/latest/download/install.sh"
LOCAL_ENV="CLOUDKIT_RELEASES_API=file://$LOCAL/release.json CLOUDKIT_ARCHIVE_URL=file://$LOCAL/archive"

info() { printf "\033[0;36m==>\033[0m %s\n" "$*"; }
fail() { printf "\033[0;31mFAIL:\033[0m %s\n" "$*" >&2; exit 1; }

# Remember --no-deps so verify skips ck doctor.
note_no_deps() {
  case " $* " in
    *" --no-deps "*) CK_NO_DEPS=true ;;
  esac
}

install_local() {
  note_no_deps "$@"
  [ -f "$LOCAL/release.json" ] || fail "No local release in $LOCAL (run through docker/run.sh)"
  info "Running install.sh $* (from the working tree)"
  # shellcheck disable=SC2086 # two VAR=value words
  env $LOCAL_ENV bash -s -- "$@" < "$LOCAL/install.sh"
}

install_release() {
  note_no_deps "$@"
  info "Running the published installer: $RELEASE_URL $*"
  curl -fsSL "$RELEASE_URL" | bash -s -- "$@"
}

install_cloudkit() {
  case "$SOURCE" in
    release) install_release "$@" ;;
    local) install_local "$@" ;;
    *) fail "Unknown CK_SOURCE: $SOURCE (use release or local)" ;;
  esac
}

# Run a command in a fresh interactive shell, the way a user would after install.
in_shell() {
  local sh="$1"
  shift
  { "$sh" -ic "$*" < /dev/null 2>&1 || true; } | grep -v -e 'job control' -e 'terminal process group' || true
}

verify() {
  local dir="${CLOUDKIT_HOME:-$HOME/.cloudkit}" rc sh out version
  info "Verifying the install in $dir"
  [ -f "$dir/main.sh" ] || fail "$dir/main.sh missing"
  [ -f "$dir/.cloudkit-managed" ] || fail "$dir is not marked as installer-managed"

  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [ -f "$rc" ] || continue
    [ "$(grep -c '# >>> cloudkit >>>' "$rc")" -le 1 ] || fail "$rc: duplicate cloudkit block"
  done
  rc="$HOME/.$(basename "$SHELL")rc"
  grep -qF "source \"$dir/main.sh\"" "$rc" || fail "$rc: missing source line"
  echo "  rc block: OK ($rc)"

  sh="$(basename "$SHELL")"
  out="$(in_shell "$sh" 'ck help')"
  echo "$out" | grep -q 'doctor' || fail "ck help in $sh: $out"
  echo "  ck help: OK ($sh)"
  version="$(cat "$dir/.cloudkit-version" 2> /dev/null || true)"
  [ -n "$version" ] || fail "$dir/.cloudkit-version missing"
  # Releases older than `ck version` only get the version file checked.
  if echo "$out" | grep -q '^ *version '; then
    out="$(in_shell "$sh" 'ck version')"
    [ "$out" = "CloudKit $version" ] || fail "ck version: expected 'CloudKit $version', got: $out"
  fi
  echo "  version: $version"

  # Without dependencies doctor can only report missing tools, so skip it.
  if [ "${CK_NO_DEPS:-false}" = true ]; then
    echo "  ck doctor: skipped (--no-deps)"
    return 0
  fi
  info "ck doctor"
  out="$(in_shell "$sh" 'ck doctor')"
  echo "$out"
  echo "$out" | grep -q 'required tools are missing' && fail "ck doctor reports missing required tools"
  return 0
}

cmd="${1:-shell}"
[ $# -gt 0 ] && shift
case "$cmd" in
  shell)
    # Dependencies are preinstalled in the image, so this only installs CloudKit.
    [ $# -gt 0 ] || set -- --yes
    install_cloudkit "$@" > /dev/null
    verify
    printf "\nCloudKit is installed and loaded: try ck help.\n\n"
    exec "$SHELL" -l
    ;;
  fresh)
    printf "\nFresh machine ready. Install CloudKit like a new user would:\n\n"
    if [ "$SOURCE" = local ]; then
      echo "  $LOCAL_ENV bash < $LOCAL/install.sh"
    else
      echo "  curl -fsSL $RELEASE_URL | bash"
    fi
    printf "\nThen: exec \$SHELL -l && ck doctor     (verify: ck-test-install verify)\n\n"
    exec "$SHELL" -l
    ;;
  verify) verify ;;
  -h | --help | help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) exec "$cmd" "$@" ;;
esac
