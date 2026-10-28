#!/usr/bin/env bash
# CloudKit installer: fetches CloudKit, installs its dependencies, and adds
# `source .../main.sh` to your shell rc file.
#
#   curl -fsSL https://github.com/shabayekdes/cloudkit-cli/releases/latest/download/install.sh | bash
#   curl -fsSL .../install.sh | bash -s -- --gcp --yes
#   ./install.sh [options]          # from a clone: uses the clone in place
#
# Run with --help for options.

set -euo pipefail

CLOUDKIT_REPO_URL="${CLOUDKIT_REPO_URL:-https://github.com/shabayekdes/cloudkit-cli.git}"
CLOUDKIT_ARCHIVE_URL="${CLOUDKIT_ARCHIVE_URL:-https://github.com/shabayekdes/cloudkit-cli/archive}"
CLOUDKIT_RELEASES_API="${CLOUDKIT_RELEASES_API-https://api.github.com/repos/shabayekdes/cloudkit-cli/releases/latest}"
RC_BEGIN="# >>> cloudkit >>>"
RC_END="# <<< cloudkit <<<"
MANAGED_MARKER=".cloudkit-managed"
VERSION_FILE=".cloudkit-version"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
BOLD=$'\033[1m'
NC=$'\033[0m'

info() { printf "%s==>%s %s\n" "${CYAN}" "${NC}" "$*"; }
ok() { printf "  %s✓%s %s\n" "${GREEN}" "${NC}" "$*"; }
warn() { printf "  %s!%s %s\n" "${YELLOW}" "${NC}" "$*"; }
err() { printf "  %s✗%s %s\n" "${RED}" "${NC}" "$*" >&2; }
die() { printf "%sError:%s %s\n" "${RED}" "${NC}" "$*" >&2; exit 1; }

usage() {
  cat << 'EOF'
Usage: install.sh [options]

  --aws          Install AWS dependencies only (plus common ones)
  --gcp          Install Google Cloud dependencies only (plus common ones)
  --all          Install AWS and Google Cloud dependencies
                 (default: ask; "all" when there is no terminal)
  --core         Install only the common tools (curl, jq, python3), without
                 the AWS CLI or gcloud
  --yes, -y      Don't ask for confirmation
  --no-deps      Skip dependency installation
  --no-rc        Don't edit shell rc files
  --no-setup     Don't offer credential setup at the end
  --dir <path>   Install directory (default: $CLOUDKIT_HOME or ~/.cloudkit;
                 ignored when run from a clone)
  --deps <tools> Install only these tools (comma-separated, e.g. jq,python3)
                 and exit
  --uninstall    Remove the rc block (and the install directory, if this
                 installer created it). Never touches ~/.aws or gcloud config.
  -h, --help     Show this help
EOF
}

# --- prompts ---------------------------------------------------------------

# True when we can talk to the user, even when piped from curl.
has_tty() { { : < /dev/tty; } 2> /dev/null; }

# ask "Question" [default y|n] -> 0 for yes, 1 for no
ask() {
  local question="$1" default="${2:-y}" hint answer
  if [ "$ASSUME_YES" = true ]; then
    return 0
  fi
  if ! has_tty; then
    [ "$default" = y ]
    return
  fi
  if [ "$default" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf "%s %s " "$question" "$hint" > /dev/tty
  read -r answer < /dev/tty || answer=""
  answer="${answer:-$default}"
  case "$answer" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

# --- platform --------------------------------------------------------------

SUDO=""
detect_platform() {
  OS="$(uname -s)"
  ARCH="$(uname -m)"
  PKG=""
  if [ "$OS" = Darwin ]; then
    command -v brew > /dev/null 2>&1 && PKG=brew
  elif command -v apt-get > /dev/null 2>&1; then
    PKG=apt
  elif command -v dnf > /dev/null 2>&1; then
    PKG=dnf
  elif command -v yum > /dev/null 2>&1; then
    PKG=yum
  elif command -v pacman > /dev/null 2>&1; then
    PKG=pacman
  elif command -v brew > /dev/null 2>&1; then
    PKG=brew
  fi

  if [ "$(id -u)" -ne 0 ] && [ "$PKG" != brew ]; then
    if command -v sudo > /dev/null 2>&1; then
      SUDO="sudo"
    else
      warn "Not root and sudo not found; system package installs may fail"
    fi
  fi
}

APT_UPDATED=false
pkg_install() {
  case "$PKG" in
    brew) brew install "$@" ;;
    apt)
      if [ "$APT_UPDATED" = false ]; then
        $SUDO apt-get update -qq
        APT_UPDATED=true
      fi
      $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
      ;;
    dnf | yum) $SUDO "$PKG" install -y -q "$@" ;;
    pacman) $SUDO pacman -S --noconfirm --needed "$@" ;;
    *) return 1 ;;
  esac
}

# Package name for a tool on this package manager.
pkg_name() {
  case "$1:$PKG" in
    python3:brew) echo python ;;
    python3:pacman) echo python ;;
    *) echo "$1" ;;
  esac
}

# --- dependency checks -----------------------------------------------------

GCLOUD_SDK_DIR="$HOME/google-cloud-sdk"

has() { command -v "$1" > /dev/null 2>&1; }

has_dep() {
  case "$1" in
    aws) has aws && aws --version 2>&1 | grep -q '^aws-cli/2' ;;
    gcloud) has gcloud || [ -x "$GCLOUD_SDK_DIR/bin/gcloud" ] ;;
    *) has "$1" ;;
  esac
}

# Dependencies for the selected scope, in install order.
wanted_deps() {
  if [ -n "$DEPS_ONLY" ]; then
    echo "$DEPS_ONLY"
    return
  fi
  local deps="curl jq python3"
  if [ "$WANT_AWS" = true ]; then
    deps="$deps unzip aws session-manager-plugin"
  fi
  if [ "$WANT_GCP" = true ]; then
    deps="$deps gcloud"
  fi
  echo "$deps"
}

# --- installers for tools without a plain distro package -------------------

TMP_DIR=""
cleanup() {
  if [ -n "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

# Create TMP_DIR once. Call it directly, not in $(...): a subshell's
# assignment would be lost and the EXIT trap would never clean it up.
make_tmp_dir() {
  [ -n "$TMP_DIR" ] || TMP_DIR="$(mktemp -d)"
}

install_aws() {
  if has aws && aws --version 2>&1 | grep -q '^aws-cli/1'; then
    warn "AWS CLI v1 found ($(command -v aws)); installing v2 alongside it"
  fi
  if [ "$PKG" = brew ]; then
    brew install awscli
    return
  fi
  [ "$OS" = Linux ] || return 1
  local dir arch
  make_tmp_dir
  dir="$TMP_DIR/awscli"
  case "$ARCH" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) err "Unsupported architecture for AWS CLI: $ARCH"; return 1 ;;
  esac
  mkdir -p "$dir"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "$dir/awscliv2.zip"
  unzip -q -o "$dir/awscliv2.zip" -d "$dir"
  $SUDO "$dir/aws/install" --update
}

install_session_manager_plugin() {
  if [ "$PKG" = brew ]; then
    brew install --cask session-manager-plugin
    return
  fi
  local base="https://s3.amazonaws.com/session-manager-downloads/plugin/latest"
  local arm=false file
  case "$ARCH" in
    aarch64 | arm64) arm=true ;;
  esac
  case "$PKG" in
    apt)
      make_tmp_dir
      file="$TMP_DIR/session-manager-plugin.deb"
      if [ "$arm" = true ]; then
        curl -fsSL "$base/ubuntu_arm64/session-manager-plugin.deb" -o "$file"
      else
        curl -fsSL "$base/ubuntu_64bit/session-manager-plugin.deb" -o "$file"
      fi
      $SUDO dpkg -i "$file"
      ;;
    dnf | yum)
      if [ "$arm" = true ]; then
        $SUDO "$PKG" install -y -q "$base/linux_arm64/session-manager-plugin.rpm"
      else
        $SUDO "$PKG" install -y -q "$base/linux_64bit/session-manager-plugin.rpm"
      fi
      ;;
    *)
      err "No automatic install for session-manager-plugin here; see https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"
      return 1
      ;;
  esac
}

install_gcloud() {
  case "$PKG" in
    brew)
      brew install --cask gcloud-cli || brew install --cask google-cloud-sdk
      ;;
    apt)
      pkg_install apt-transport-https ca-certificates gnupg
      curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | $SUDO gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg
      echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        | $SUDO tee /etc/apt/sources.list.d/google-cloud-sdk.list > /dev/null
      APT_UPDATED=false
      pkg_install google-cloud-cli
      ;;
    *)
      # Official archive install into ~/google-cloud-sdk; the rc block adds it to PATH
      curl -fsSL https://sdk.cloud.google.com \
        | bash -s -- --disable-prompts --install-dir="$HOME" > /dev/null
      ;;
  esac
}

install_dep() {
  case "$1" in
    aws) install_aws ;;
    session-manager-plugin) install_session_manager_plugin ;;
    gcloud) install_gcloud ;;
    *) pkg_install "$(pkg_name "$1")" ;;
  esac
}

install_deps() {
  info "Checking dependencies"
  local dep missing=""
  for dep in $(wanted_deps); do
    if has_dep "$dep"; then
      ok "$dep"
    else
      warn "$dep (missing)"
      missing="$missing $dep"
    fi
  done
  missing="${missing# }"

  if [ -z "$missing" ]; then
    return 0
  fi
  if [ -z "$PKG" ]; then
    err "No supported package manager found (brew, apt, dnf, yum, pacman)."
    err "Install manually: $missing"
    FAILED="$FAILED $missing"
    return 0
  fi
  if ! ask "Install missing dependencies ($missing) using $PKG?" y; then
    warn "Skipped. Re-run the installer or see: ck doctor"
    FAILED="$FAILED $missing"
    return 0
  fi

  for dep in $missing; do
    info "Installing $dep"
    if install_dep "$dep" && has_dep "$dep"; then
      ok "$dep installed"
    else
      err "$dep failed to install"
      FAILED="$FAILED $dep"
    fi
  done
}

# --- CloudKit itself -------------------------------------------------------

# Print the newest release tag: the GitHub "latest release", or else the
# highest version tag in the repository.
latest_version() {
  local tag=""
  if [ -n "$CLOUDKIT_RELEASES_API" ]; then
    tag=$(curl -fsSL "$CLOUDKIT_RELEASES_API" 2> /dev/null \
      | sed -n 's/^ *"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1) || tag=""
  fi
  if [ -z "$tag" ] && has git; then
    tag=$(git ls-remote --tags --refs "$CLOUDKIT_REPO_URL" 'v*' 2> /dev/null \
      | sed 's|.*refs/tags/||' | sort -V 2> /dev/null | tail -n 1) || tag=""
  fi
  echo "$tag"
}

# Print the ref to install: the newest release, or main when there is none.
install_version() {
  local version
  version="$(latest_version)"
  if [ -z "$version" ]; then
    warn "Could not find a release; installing the main branch" >&2
    version=main
  fi
  echo "$version"
}

fetch_cloudkit() {
  local dir="$1" version="$2"

  if [ -d "$dir/.git" ] && has git; then
    info "Switching CloudKit in $dir to $version"
    if git -C "$dir" fetch --quiet --depth 1 --force "$CLOUDKIT_REPO_URL" "$version" \
      && git -C "$dir" -c advice.detachedHead=false checkout --quiet --detach FETCH_HEAD; then
      echo "$version" > "$dir/$VERSION_FILE"
    else
      warn "Could not update $dir (local changes?); using it as is"
    fi
    return
  fi
  if [ -f "$dir/main.sh" ] && [ ! -f "$dir/$MANAGED_MARKER" ]; then
    warn "Using existing CloudKit in $dir (not managed by the installer, version unchanged)"
    return
  fi
  if [ -f "$dir/$MANAGED_MARKER" ]; then
    # Downloaded archive from an earlier install: replace it
    rm -rf "$dir"
  elif [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2> /dev/null)" ]; then
    die "$dir exists and is not a CloudKit install; pick another with --dir"
  fi

  info "Downloading CloudKit $version into $dir"
  if has git; then
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$version" "$CLOUDKIT_REPO_URL" "$dir"
  else
    local ref="refs/tags/$version"
    [ "$version" = main ] && ref="refs/heads/main"
    mkdir -p "$dir"
    curl -fsSL "$CLOUDKIT_ARCHIVE_URL/$ref.tar.gz" | tar -xz -C "$dir" --strip-components 1
  fi
  touch "$dir/$MANAGED_MARKER"
  echo "$version" > "$dir/$VERSION_FILE"
}

# --- shell rc --------------------------------------------------------------

rc_files() {
  local files="" shell_name
  shell_name="$(basename "${SHELL:-bash}")"
  case "$shell_name" in
    zsh) files="$HOME/.zshrc" ;;
    *)
      if [ "$(uname -s)" = Darwin ]; then
        files="$HOME/.bash_profile"
      else
        files="$HOME/.bashrc"
      fi
      ;;
  esac
  # Also cover the other common rc files that already exist
  local f
  for f in "$HOME/.zshrc" "$HOME/.bashrc"; do
    case " $files " in
      *" $f "*) ;;
      *) [ -f "$f" ] && files="$files $f" ;;
    esac
  done
  echo "$files"
}

# Remove our marked block from FILE (keeps the file itself, its mode and links).
rc_remove_block() {
  local file="$1" tmp
  [ -f "$file" ] || return 0
  grep -qF "$RC_BEGIN" "$file" || return 0
  tmp="$(mktemp)"
  awk -v b="$RC_BEGIN" -v e="$RC_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip
  ' "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

rc_block() {
  local dir="$1"
  echo "$RC_BEGIN"
  if ! has gcloud && [ -x "$GCLOUD_SDK_DIR/bin/gcloud" ]; then
    # shellcheck disable=SC2016
    printf 'export PATH="%s/bin:$PATH"\n' "$GCLOUD_SDK_DIR"
  fi
  printf 'source "%s/main.sh"\n' "$dir"
  echo "$RC_END"
}

install_rc() {
  local dir="$1" file
  info "Updating shell rc files"
  for file in $(rc_files); do
    rc_remove_block "$file"
    # Start on a new line if the file doesn't end with one
    if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then
      echo >> "$file"
    fi
    rc_block "$dir" >> "$file"
    ok "$file"
  done
}

# --- credentials -----------------------------------------------------------

offer_setup() {
  local dir="$1"
  if [ "$ASSUME_YES" = true ] || ! has_tty; then
    return 0
  fi
  if [ "$WANT_AWS" = true ] && has_dep aws; then
    local default=y
    [ -s "$HOME/.aws/config" ] && default=n
    if ask "Set up AWS credentials now (ck setup aws)?" "$default"; then
      bash -c 'source "$1/main.sh" && ck setup aws' _ "$dir" < /dev/tty || true
    fi
  fi
  if [ "$WANT_GCP" = true ] && has_dep gcloud; then
    local default=y
    [ -n "$(ls "${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/configurations" 2> /dev/null)" ] && default=n
    if ask "Set up a gcloud configuration now (ck setup gcloud)?" "$default"; then
      PATH="$PATH:$GCLOUD_SDK_DIR/bin" \
        bash -c 'source "$1/main.sh" && ck setup gcloud' _ "$dir" < /dev/tty || true
    fi
  fi
}

# --- uninstall -------------------------------------------------------------

uninstall() {
  local dir="$1" file
  info "Removing CloudKit from shell rc files"
  for file in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [ -f "$file" ] && grep -qF "$RC_BEGIN" "$file"; then
      rc_remove_block "$file"
      ok "$file"
    fi
  done
  if [ -f "$dir/$MANAGED_MARKER" ]; then
    if ask "Delete $dir?" y; then
      rm -rf "$dir"
      ok "Deleted $dir"
    fi
  else
    warn "Leaving $dir in place (not created by this installer)"
  fi
  printf "\nCloudKit removed. Open a new terminal. ~/.aws and gcloud configuration were not touched.\n"
}

# --- main ------------------------------------------------------------------

main() {
  WANT_AWS="" WANT_GCP="" ASSUME_YES=false DO_DEPS=true DO_RC=true DO_SETUP=true DEPS_ONLY=""
  local do_uninstall=false dir="${CLOUDKIT_HOME:-$HOME/.cloudkit}"
  FAILED=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --aws) WANT_AWS=true; WANT_GCP="${WANT_GCP:-false}" ;;
      --gcp | --gcloud) WANT_GCP=true; WANT_AWS="${WANT_AWS:-false}" ;;
      --all) WANT_AWS=true; WANT_GCP=true ;;
      --core) WANT_AWS=false; WANT_GCP=false ;;
      -y | --yes) ASSUME_YES=true ;;
      --no-deps) DO_DEPS=false ;;
      --no-rc) DO_RC=false ;;
      --no-setup) DO_SETUP=false ;;
      --dir)
        [ -n "${2:-}" ] || die "--dir needs a path"
        dir="$2"
        shift
        ;;
      --deps)
        [ -n "${2:-}" ] || die "--deps needs a tool list, e.g. jq,python3"
        DEPS_ONLY="${2//,/ }"
        shift
        ;;
      --uninstall) do_uninstall=true ;;
      -h | --help) usage; exit 0 ;;
      *) usage >&2; die "Unknown option: $1" ;;
    esac
    shift
  done

  # Run from a clone: use it in place
  local self_dir=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$self_dir/main.sh" ] && [ -f "$self_dir/ck.sh" ] && dir="$self_dir"
  fi

  if [ "$do_uninstall" = true ]; then
    uninstall "$dir"
    return 0
  fi

  if [ -n "$DEPS_ONLY" ]; then
    detect_platform
    install_deps
    [ -z "$FAILED" ]
    return
  fi

  printf "\n%sCloudKit installer%s %s(AWS & Google Cloud shell helpers)%s\n\n" "${BOLD}" "${NC}" "${GRAY}" "${NC}"
  detect_platform

  if [ -z "$WANT_AWS" ] && [ -z "$WANT_GCP" ]; then
    WANT_AWS=true WANT_GCP=true
    if [ "$ASSUME_YES" = false ] && has_tty; then
      local choice
      printf "Which clouds do you use?\n  1) AWS and Google Cloud\n  2) AWS only\n  3) Google Cloud only\n  4) CloudKit only (common tools, no AWS CLI or gcloud)\nChoice [1]: " > /dev/tty
      read -r choice < /dev/tty || choice=""
      case "${choice:-1}" in
        2) WANT_GCP=false ;;
        3) WANT_AWS=false ;;
        4) WANT_AWS=false WANT_GCP=false ;;
      esac
    fi
  fi

  if [ "$DO_DEPS" = true ]; then
    install_deps
  fi

  [ "$dir" = "${self_dir:-}" ] || fetch_cloudkit "$dir" "$(install_version)"
  [ -f "$dir/main.sh" ] || die "CloudKit not found in $dir"

  if [ "$DO_RC" = true ]; then
    install_rc "$dir"
  fi

  if [ "$DO_SETUP" = true ]; then
    offer_setup "$dir"
  fi

  printf "\n"
  if [ -n "$FAILED" ]; then
    err "Not installed:$FAILED"
    printf "  Run %sck doctor%s for details.\n" "${BOLD}" "${NC}"
  fi
  local installed=""
  [ -f "$dir/$VERSION_FILE" ] && installed=" $(cat "$dir/$VERSION_FILE")"
  printf "%sCloudKit%s is installed in %s.%s\n" "${GREEN}" "$installed" "$dir" "${NC}"
  printf "  ck doctor     check dependencies and configuration\n"
  printf "  ck setup      configure AWS / gcloud credentials\n"
  printf "  ck help       list commands\n\n"

  # An installer can't define `ck` in the shell that started it, so offer to
  # replace this process with a fresh login shell that loads the rc block.
  if [ "$DO_RC" = true ] && [ "$ASSUME_YES" = false ] && has_tty; then
    if ask "Start a new shell now so 'ck' works in this terminal?" y; then
      printf "\n"
      exec "${SHELL:-bash}" -l < /dev/tty
    fi
  fi
  printf "%s'ck' is not loaded in this terminal yet.%s Run %sexec %s%s or open a new terminal.\n\n" \
    "${YELLOW}" "${NC}" "${BOLD}" "$(basename "${SHELL:-bash}")" "${NC}"
}

main "$@"
