# shellcheck shell=bash
# `ck` — single entry point for all CloudKit commands.

_ck_help() {
  case "$1" in
    aws) _ck_aws_usage ;;
    gcloud) _ck_gcloud_usage ;;
    ec2|ecs|gce|mig) "_ck_$1" ;;
    setup) _ck_setup_usage ;;
    doctor) echo "Usage: ck doctor    Check dependencies and AWS/gcloud configuration" ;;
    "")
      cat << 'EOF'
Usage: ck <command> [options]

Sessions:
  aws login               Pick an AWS profile, SSO login, show session table
  aws switch              Switch to another AWS profile
  aws logout              Clear the AWS session from this shell
  aws sso <profile>       Run `aws sso login` for a profile
  gcloud login [--reauth] Pick a gcloud configuration and authenticate
  gcloud switch           Switch to another gcloud configuration
  gcloud logout           Clear the gcloud session from this shell
  status                  Show the active AWS and gcloud sessions

Setup:
  setup [aws|gcloud]      Guided AWS profile / gcloud configuration setup
  doctor                  Check dependencies and configuration
  version                 Show the installed CloudKit version

Services:
  ec2 <command>           EC2 instances: ls, session, run, stop, port-forward
  ecs <command>           ECS: clusters, services, tasks, exec, logs, stop, describe
  gce <command>           GCE VMs: ls, start, stop, ssh, scp, port-forward
  mig <command>           GCE managed instance groups: list, describe, recreate, restart

Run `ck help <command>` for a command's options.
EOF
      ;;
    *)
      printf "%sUnknown command: %s%s\n" "${RED:-}" "$1" "${NC:-}" >&2
      _ck_help
      return 1
      ;;
  esac
  return 0
}

_ck_aws_usage() {
  cat << 'EOF'
Usage: ck aws <login|switch|logout|sso <profile>>

  login             Pick an AWS profile, SSO login, show session table
  switch            Switch to another AWS profile
  logout            Clear the AWS session from this shell
  sso <profile>     Run `aws sso login` for a profile
EOF
}

_ck_gcloud_usage() {
  cat << 'EOF'
Usage: ck gcloud <login [--reauth]|switch|logout>

  login [--reauth]  Pick a gcloud configuration and authenticate
  switch            Switch to another gcloud configuration
  logout            Clear the gcloud session from this shell
EOF
}

# Print "<config>|<account>|<project>" for gcloud's active configuration,
# read from its local config files (no gcloud call). Returns 1 if none.
_ck_gcloud_active_config() {
  local dir="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
  local name="${CLOUDSDK_ACTIVE_CONFIG_NAME:-}"
  if [ -z "$name" ] && [ -f "$dir/active_config" ]; then
    name=$(cat "$dir/active_config")
  fi
  local file="$dir/configurations/config_$name"
  if [ -z "$name" ] || [ ! -f "$file" ]; then
    return 1
  fi

  local account project
  account=$(awk -F' *= *' '/^\[/ { section = $0 } section == "[core]" && $1 == "account" { print $2 }' "$file")
  project=$(awk -F' *= *' '/^\[/ { section = $0 } section == "[core]" && $1 == "project" { print $2 }' "$file")
  printf "%s|%s|%s\n" "$name" "$account" "$project"
}

# Print the installed CloudKit version: the tag the installer checked out,
# else what git says about the clone.
_ck_version() {
  local dir="${CLOUDKIT_DIR:-}" version=""
  if [ -f "$dir/.cloudkit-version" ]; then
    version=$(cat "$dir/.cloudkit-version")
  elif command -v git > /dev/null 2>&1 && [ -d "$dir/.git" ]; then
    version=$(git -C "$dir" describe --tags --always 2> /dev/null)
  fi
  echo "${version:-unknown}"
}

# Show the active sessions from the env vars set by `ck aws login` and
# `ck gcloud login` (no network calls).
_ck_status() {
  printf "\n%s━━━ CloudKit Status ━━━%s\n\n" "${BOLD_GREEN:-}" "${NC:-}"
  {
    printf "Cloud|Info|Value\n"
    printf "──────|────────────|────────────────────────────────────────\n"
    if [ -n "${AWS_PROFILE:-}" ]; then
      printf "AWS|Profile|%s\n" "$AWS_PROFILE"
      printf "AWS|Account|%s\n" "${AWS_ACCOUNT_ID:-N/A}"
      printf "AWS|Region|%s\n" "${AWS_REGION:-${AWS_DEFAULT_REGION:-N/A}}"
    else
      printf "AWS|Session|not logged in (ck aws login)\n"
    fi
    if [ -n "${GCLOUD_ACCOUNT:-}" ]; then
      printf "GCloud|Configuration|%s\n" "${GCLOUD_ACTIVE_CONFIG:-N/A}"
      printf "GCloud|Account|%s\n" "$GCLOUD_ACCOUNT"
      printf "GCloud|Project|%s\n" "${GCLOUD_PROJECT:-N/A}"
    else
      local active config account project
      if ! _ck_gcloud_unselected && active=$(_ck_gcloud_active_config); then
        IFS='|' read -r config account project <<< "$active"
        printf "GCloud|Configuration|%s\n" "${config}"
        printf "GCloud|Account|%s\n" "${account:-N/A}"
        printf "GCloud|Project|%s\n" "${project:-N/A}"
        printf "GCloud|Note|gcloud's active config; not started in this shell (ck gcloud login)\n"
      else
        printf "GCloud|Session|not logged in (ck gcloud login)\n"
      fi
    fi
  } | column -t -s '|' | sed \
    -e "1s/.*/${BOLD:-}&${NC:-}/" \
    -e "s/\(not logged in.*\)/${GRAY:-}\1${NC:-}/" \
    -e "s/\(gcloud's active config.*\)/${GRAY:-}\1${NC:-}/"
  printf "\n"
}

ck() {
  local cmd="${1:-}"
  if [ $# -gt 0 ]; then
    shift
  fi

  case "$cmd" in
    aws)
      local sub="${1:-}"
      if [ $# -gt 0 ]; then
        shift
      fi
      case "$sub" in
        login) _ck_aws_login "$@" ;;
        switch) _ck_aws_switch "$@" ;;
        logout) _ck_aws_logout "$@" ;;
        sso)
          if [ -z "${1:-}" ]; then
            echo "Usage: ck aws sso <profile>"
            return 1
          fi
          aws sso login --profile "$1"
          ;;
        *)
          _ck_aws_usage
          return 1
          ;;
      esac
      ;;

    gcloud)
      local sub="${1:-}"
      if [ $# -gt 0 ]; then
        shift
      fi
      case "$sub" in
        login) _ck_gcloud_login "$@" ;;
        switch) _ck_gcloud_switch "$@" ;;
        logout) _ck_gcloud_logout "$@" ;;
        *)
          _ck_gcloud_usage
          return 1
          ;;
      esac
      ;;

    ec2|ecs|gce|mig)
      "_ck_$cmd" "$@"
      ;;

    status)
      _ck_status
      ;;

    setup)
      _ck_setup "$@"
      ;;

    doctor)
      _ck_doctor
      ;;

    version|--version|-v)
      echo "CloudKit $(_ck_version)"
      ;;

    help|-h|--help)
      _ck_help "$@"
      ;;

    "")
      _ck_help
      return 1
      ;;

    *)
      _ck_help "$cmd"
      return 1
      ;;
  esac
}
