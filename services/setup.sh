# shellcheck shell=bash
# `ck setup` (guided AWS / gcloud credential setup) and `ck doctor`
# (dependency and configuration check).

_ck_setup_usage() {
  cat << 'EOF'
Usage: ck setup [aws|gcloud]

  aws               Add an AWS profile: SSO, access keys, or a chained role
  gcloud            Create or update a gcloud configuration and log in
  (none)            Ask which one to set up
EOF
}

# _ck_prompt VAR "Question" [default]
# Reads a line into VAR, falling back to the default on empty input.
_ck_prompt() {
  local __var="$1" __question="$2" __default="${3:-}" __answer=""
  if [ -n "$__default" ]; then
    printf "%s [%s]: " "$__question" "$__default"
  else
    printf "%s: " "$__question"
  fi
  read -r __answer || return 1
  eval "$__var=\${__answer:-\$__default}"
}

# _ck_confirm "Question" [y|n] -> 0 for yes
_ck_confirm() {
  local hint="[Y/n]" answer=""
  if [ "${2:-y}" = n ]; then
    hint="[y/N]"
  fi
  printf "%s %s " "$1" "$hint"
  read -r answer || return 1
  case "${answer:-${2:-y}}" in
    [Yy]*) return 0 ;;
    *) return 1 ;;
  esac
}

_ck_install_hint() {
  printf "  Install it with: %s/install.sh %s\n" "${CLOUDKIT_DIR:-<cloudkit dir>}" "$1"
}

# --- ck setup aws ------------------------------------------------------------

_ck_setup_aws() {
  if ! command -v aws > /dev/null 2>&1; then
    printf "%sError: AWS CLI is required.%s\n" "${RED:-}" "${NC:-}"
    _ck_install_hint --aws
    return 1
  fi

  printf "\n%s━━━ AWS credential setup ━━━%s\n\n" "${BOLD_GREEN:-}" "${NC:-}"
  printf "  1) AWS SSO / IAM Identity Center %s(recommended for organisations)%s\n" "${GRAY:-}" "${NC:-}"
  printf "  2) Access keys (IAM user)\n"
  printf "  3) Role assumed from an existing profile (chained profile)\n\n"
  local choice
  _ck_prompt choice "Choice" 1 || return 1

  local profile=""
  case "$choice" in
    1)
      printf "\n%sAWS will ask for your SSO start URL, region, account, and role, then a profile name.%s\n\n" "${GRAY:-}" "${NC:-}"
      aws configure sso || return 1
      ;;
    2)
      _ck_prompt profile "Profile name" default || return 1
      if ! _ck_valid_profile_name "$profile"; then
        return 1
      fi
      aws configure --profile "$profile" || return 1
      ;;
    3)
      local profiles source_profile role_arn region
      profiles=$(aws configure list-profiles 2> /dev/null)
      if [ -z "$profiles" ]; then
        printf "%sNo profiles found. Set up an SSO or access-key profile first.%s\n" "${RED:-}" "${NC:-}"
        return 1
      fi
      printf "\nExisting profiles:\n"
      printf "%s\n" "$profiles" | sed 's/^/  /'
      _ck_prompt source_profile "Source profile" "$(printf "%s\n" "$profiles" | head -n 1)" || return 1
      if ! printf "%s\n" "$profiles" | grep -qxF "$source_profile"; then
        printf "%sUnknown profile: %s%s\n" "${RED:-}" "$source_profile" "${NC:-}"
        return 1
      fi
      _ck_prompt role_arn "Role ARN (arn:aws:iam::<account>:role/<name>)" || return 1
      if ! printf "%s" "$role_arn" | grep -qE '^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+$'; then
        printf "%sInvalid role ARN: %s%s\n" "${RED:-}" "$role_arn" "${NC:-}"
        return 1
      fi
      _ck_prompt profile "New profile name" "${role_arn##*/}" || return 1
      if ! _ck_valid_profile_name "$profile"; then
        return 1
      fi
      _ck_prompt region "Region" "$(aws configure get region --profile "$source_profile" 2> /dev/null)" || return 1
      aws configure set role_arn "$role_arn" --profile "$profile" &&
        aws configure set source_profile "$source_profile" --profile "$profile" || return 1
      if [ -n "$region" ]; then
        aws configure set region "$region" --profile "$profile" || return 1
      fi
      ;;
    *)
      printf "%sInvalid choice%s\n" "${RED:-}" "${NC:-}"
      return 1
      ;;
  esac

  printf "\n%sAWS profile saved to ~/.aws/config.%s\n" "${GREEN:-}" "${NC:-}"
  if _ck_confirm "Log in now (ck aws login)?"; then
    _ck_aws_login
  fi
}

_ck_valid_profile_name() {
  if printf "%s" "$1" | grep -qE '^[A-Za-z0-9._-]+$'; then
    return 0
  fi
  printf "%sInvalid profile name: %s (use letters, digits, '.', '_', '-')%s\n" "${RED:-}" "$1" "${NC:-}"
  return 1
}

# --- ck setup gcloud ---------------------------------------------------------

# Run gcloud against configuration $CK_SETUP_CONFIG, ignoring the empty account
# that new shells use to start without a gcloud session.
_ck_setup_gcloud_cmd() {
  env -u CLOUDSDK_CORE_ACCOUNT CLOUDSDK_ACTIVE_CONFIG_NAME="$CK_SETUP_CONFIG" gcloud "$@"
}

_ck_setup_gcloud() {
  if ! command -v gcloud > /dev/null 2>&1; then
    printf "%sError: gcloud CLI is required.%s\n" "${RED:-}" "${NC:-}"
    _ck_install_hint --gcp
    return 1
  fi

  printf "\n%s━━━ gcloud configuration setup ━━━%s\n\n" "${BOLD_GREEN:-}" "${NC:-}"
  local existing name
  existing=$(gcloud config configurations list --format='value(name)' 2> /dev/null)
  if [ -n "$existing" ]; then
    printf "Existing configurations:\n"
    printf "%s\n" "$existing" | sed 's/^/  /'
    printf "\n"
  fi

  _ck_prompt name "Configuration name (e.g. my-project, staging)" || return 1
  if ! printf "%s" "$name" | grep -qE '^[a-z][a-z0-9-]*$'; then
    printf "%sInvalid name: use lowercase letters, digits, and '-', starting with a letter%s\n" "${RED:-}" "${NC:-}"
    return 1
  fi

  local CK_SETUP_CONFIG="$name"
  local account="" project="" region="" zone=""
  if printf "%s\n" "$existing" | grep -qxF "$name"; then
    if ! _ck_confirm "Configuration '$name' exists. Update it?"; then
      return 1
    fi
    account=$(_ck_setup_gcloud_cmd config get-value core/account 2> /dev/null)
    project=$(_ck_setup_gcloud_cmd config get-value core/project 2> /dev/null)
    region=$(_ck_setup_gcloud_cmd config get-value compute/region 2> /dev/null)
    zone=$(_ck_setup_gcloud_cmd config get-value compute/zone 2> /dev/null)
  else
    gcloud config configurations create "$name" --no-activate > /dev/null || return 1
  fi

  _ck_prompt account "Google account email (empty: choose in the browser)" "$account" || return 1
  _ck_prompt project "Project ID" "$project" || return 1
  _ck_prompt region "Default region" "${region:-us-central1}" || return 1
  _ck_prompt zone "Default zone" "${zone:-${region:-us-central1}-a}" || return 1

  if [ -n "$account" ]; then
    _ck_setup_gcloud_cmd config set core/account "$account" > /dev/null 2>&1 || return 1
  fi
  if [ -n "$project" ]; then
    _ck_setup_gcloud_cmd config set core/project "$project" > /dev/null 2>&1 || return 1
  fi
  _ck_setup_gcloud_cmd config set compute/region "$region" > /dev/null 2>&1 || return 1
  _ck_setup_gcloud_cmd config set compute/zone "$zone" > /dev/null 2>&1 || return 1

  # Log in unless the account already has credentials
  local have_creds=""
  if [ -n "$account" ]; then
    have_creds=$(gcloud auth list --filter="account:$account" --format='value(account)' 2> /dev/null)
  fi
  if [ -z "$have_creds" ] || _ck_confirm "$account is already logged in. Log in again?" n; then
    if [ -n "$account" ]; then
      _ck_setup_gcloud_cmd auth login "$account" || return 1
    else
      _ck_setup_gcloud_cmd auth login || return 1
      account=$(_ck_setup_gcloud_cmd config get-value core/account 2> /dev/null)
    fi
  fi

  if _ck_confirm "Also set Application Default Credentials (for SDKs/Terraform)?" n; then
    _ck_setup_gcloud_cmd auth application-default login || return 1
  fi

  printf "\n%sgcloud configuration '%s' is ready (account: %s, project: %s).%s\n" \
    "${GREEN:-}" "$name" "${account:-?}" "${project:-unset}" "${NC:-}"
  if _ck_confirm "Start a session with it now?"; then
    # Same exports as select_gcloud_profile, then the `ck gcloud switch` table
    _ck_gcloud_use_config "$name"
    export GCLOUD_ACTIVE_CONFIG="$name"
    export GCLOUD_ACCOUNT="$account"
    export GCLOUD_PROJECT="${project:-(unset)}"
    export GCLOUD_REGION="$region"

    local token_status
    token_status=$(_gcloud_token_status "$account")
    _update_prompt
    clear_terminal
    create_and_display_gcloud_table "$account" "$GCLOUD_PROJECT" "$token_status"
    _gcloud_warn_if_expiring_soon "$token_status"
  fi
}

_ck_setup() {
  case "${1:-}" in
    aws) _ck_setup_aws ;;
    gcloud|gcp) _ck_setup_gcloud ;;
    "")
      local choice
      printf "Set up:\n  1) AWS\n  2) Google Cloud\n  3) Both\n"
      _ck_prompt choice "Choice" 3 || return 1
      case "$choice" in
        1) _ck_setup_aws ;;
        2) _ck_setup_gcloud ;;
        3) _ck_setup_aws; _ck_setup_gcloud ;;
        *) printf "%sInvalid choice%s\n" "${RED:-}" "${NC:-}"; return 1 ;;
      esac
      ;;
    -h|--help|help) _ck_setup_usage ;;
    *) _ck_setup_usage; return 1 ;;
  esac
}

# --- ck doctor ---------------------------------------------------------------

# _ck_doctor_line ok|warn|fail NAME DETAIL
_ck_doctor_line() {
  local mark
  case "$1" in
    ok) mark="${GREEN:-}✓${NC:-}" ;;
    warn) mark="${YELLOW:-}!${NC:-}" ;;
    *) mark="${RED:-}✗${NC:-}"; _CK_DOCTOR_FAILED=1 ;;
  esac
  printf "  %s %-24s %s\n" "$mark" "$2" "$3"
}

# _ck_doctor_tool NAME LEVEL_IF_MISSING HINT [VERSION_CMD...]
_ck_doctor_tool() {
  local name="$1" missing_level="$2" hint="$3"
  shift 3
  if ! command -v "$name" > /dev/null 2>&1; then
    _ck_doctor_line "$missing_level" "$name" "${GRAY:-}missing — ${hint}${NC:-}"
    return 1
  fi
  local version=""
  if [ $# -gt 0 ]; then
    version=$("$@" 2>&1 | head -n 1)
  fi
  _ck_doctor_line ok "$name" "${GRAY:-}${version}${NC:-}"
}

_ck_doctor() {
  _CK_DOCTOR_FAILED=0
  local installer="${CLOUDKIT_DIR:-.}/install.sh"

  printf "\n%s━━━ CloudKit Doctor ━━━%s\n" "${BOLD_GREEN:-}" "${NC:-}"
  printf "%sCloudKit %s (%s)%s\n" "${GRAY:-}" "$(_ck_version)" "${CLOUDKIT_DIR:-?}" "${NC:-}"

  printf "\n%sCommon%s\n" "${BOLD:-}" "${NC:-}"
  _ck_doctor_tool jq fail "required" jq --version
  _ck_doctor_tool python3 fail "required for credential expiry" python3 --version

  # A cloud is checked strictly when its CLI or config is present
  local use_aws=false use_gcp=false
  if command -v aws > /dev/null 2>&1 || [ -f "$HOME/.aws/config" ]; then
    use_aws=true
  fi
  local gcloud_dir="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"
  if command -v gcloud > /dev/null 2>&1 || [ -d "$gcloud_dir/configurations" ]; then
    use_gcp=true
  fi
  local level
  # CloudKit-only installs (install.sh --core) are valid: just point the way
  if [ "$use_aws" = false ] && [ "$use_gcp" = false ]; then
    printf "\n%sNeither the AWS CLI nor gcloud is installed. Install one with: %s --aws | --gcp%s\n" \
      "${YELLOW:-}" "$installer" "${NC:-}"
  fi

  printf "\n%sAWS%s\n" "${BOLD:-}" "${NC:-}"
  level=warn
  if [ "$use_aws" = true ]; then
    level=fail
  fi
  if command -v aws > /dev/null 2>&1; then
    local aws_version
    aws_version=$(aws --version 2>&1 | head -n 1)
    case "$aws_version" in
      aws-cli/2*) _ck_doctor_line ok aws "${GRAY:-}${aws_version%% *}${NC:-}" ;;
      *) _ck_doctor_line fail aws "${GRAY:-}${aws_version%% *} — AWS CLI v2 required ($installer --aws)${NC:-}" ;;
    esac
  else
    _ck_doctor_line "$level" aws "${GRAY:-}missing — $installer --aws${NC:-}"
  fi
  _ck_doctor_tool session-manager-plugin "$level" "needed by ec2 session/port-forward, ecs exec" \
    session-manager-plugin --version
  if [ "$use_aws" = true ]; then
    local profile_count=0
    if command -v aws > /dev/null 2>&1; then
      profile_count=$(aws configure list-profiles 2> /dev/null | grep -c .)
    fi
    if [ "$profile_count" -gt 0 ]; then
      _ck_doctor_line ok "profiles" "${GRAY:-}${profile_count} in ~/.aws/config${NC:-}"
    else
      _ck_doctor_line warn "profiles" "${GRAY:-}none — run: ck setup aws${NC:-}"
    fi
  fi

  printf "\n%sGoogle Cloud%s\n" "${BOLD:-}" "${NC:-}"
  level=warn
  if [ "$use_gcp" = true ]; then
    level=fail
  fi
  if command -v gcloud > /dev/null 2>&1; then
    _ck_doctor_line ok gcloud "${GRAY:-}$(gcloud --version 2> /dev/null | head -n 1)${NC:-}"
  else
    _ck_doctor_line "$level" gcloud "${GRAY:-}missing — $installer --gcp${NC:-}"
  fi
  if [ "$use_gcp" = true ]; then
    local config_count
    config_count=$(find "$gcloud_dir/configurations" -maxdepth 1 -type f -name 'config_*' 2> /dev/null | grep -c .)
    if [ "$config_count" -gt 0 ]; then
      _ck_doctor_line ok "configurations" "${GRAY:-}${config_count} in ${gcloud_dir}${NC:-}"
    else
      _ck_doctor_line warn "configurations" "${GRAY:-}none — run: ck setup gcloud${NC:-}"
    fi
    if [ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] || [ -f "$gcloud_dir/application_default_credentials.json" ]; then
      _ck_doctor_line ok "ADC" "${GRAY:-}set${NC:-}"
    else
      _ck_doctor_line warn "ADC" "${GRAY:-}not set (optional) — gcloud auth application-default login${NC:-}"
    fi
  fi

  printf "\n%sShell%s\n" "${BOLD:-}" "${NC:-}"
  local rc found=""
  for rc in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    if [ -f "$rc" ] && grep -q 'main\.sh' "$rc" && grep -qiE 'cloudkit|aws-cli-helpers' "$rc"; then
      found="$found $rc"
    fi
  done
  if [ -n "$found" ]; then
    _ck_doctor_line ok "rc file" "${GRAY:-}loaded from${found}${NC:-}"
  else
    _ck_doctor_line warn "rc file" "${GRAY:-}not in ~/.zshrc or ~/.bashrc — run: $installer --no-deps${NC:-}"
  fi

  printf "\n"
  if [ "$_CK_DOCTOR_FAILED" -ne 0 ]; then
    printf "%sSome required tools are missing.%s\n\n" "${RED:-}" "${NC:-}"
    return 1
  fi
  printf "%sAll required tools are installed.%s\n\n" "${GREEN:-}" "${NC:-}"
  return 0
}
