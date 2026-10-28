#!/bin/bash

# ANSI Color codes (using $'...' syntax for compatibility with bash and zsh)
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
BLUE=$'\033[0;34m'
BOLD_GREEN=$'\033[1;32m'
BOLD=$'\033[1m'
NC=$'\033[0m' # No Color
CYAN=$'\033[0;36m'
GRAY=$'\033[0;90m'
YELLOW=$'\033[0;33m'
PROD_BADGE=$'\033[1;97;41m'

# _parse_iso8601_epoch TIMESTAMP
#
# Converts an ISO 8601 UTC timestamp (e.g. "2026-02-24T15:00:00Z") to Unix
# epoch seconds.  Tries three parsers in order of preference:
#   1. python3  — available on macOS and most Linux distros
#   2. BSD date  (macOS): date -j -f "%Y-%m-%dT%H:%M:%SZ"
#   3. GNU date  (Linux): date -d
#
# Outputs epoch integer on stdout.
# Returns 0 on success, 1 when input is empty, unparseable, or contains
# characters outside the expected ISO 8601 character set.
_parse_iso8601_epoch() {
    local ts="$1"

    # Reject empty input
    if [ -z "$ts" ]; then
        return 1
    fi

    # Allow only characters valid in an ISO 8601 timestamp to prevent injection.
    # Valid set: digits, T, Z, +, -, :
    if ! echo "$ts" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([Z]|[+-][0-9]{2}:[0-9]{2})$'; then
        return 1
    fi

    # Normalise +00:00 → Z for parsers that only handle the Z suffix
    local normalized_ts="${ts/+00:00/Z}"

    # Strip Z suffix for BSD date which uses a format string
    local ts_no_z="${normalized_ts%Z}"

    local epoch

    # Try python3 first (most reliable across platforms)
    if command -v python3 > /dev/null 2>&1; then
        epoch=$(python3 -c "
import sys, datetime, calendar
ts = sys.argv[1]
# Accept both Z-suffix and +00:00 offset
for fmt in ('%Y-%m-%dT%H:%M:%SZ', '%Y-%m-%dT%H:%M:%S+00:00'):
    try:
        dt = datetime.datetime.strptime(ts, fmt)
        print(calendar.timegm(dt.timetuple()))
        sys.exit(0)
    except ValueError:
        pass
sys.exit(1)
" "$normalized_ts" 2>/dev/null) && echo "$epoch" && return 0
    fi

    # Try BSD date (macOS)
    if epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$ts_no_z" "+%s" 2>/dev/null); then
        echo "$epoch"
        return 0
    fi

    # Try GNU date (Linux)
    if epoch=$(date -d "$normalized_ts" +%s 2>/dev/null); then
        echo "$epoch"
        return 0
    fi

    return 1
}

# _aws_credential_expiration PROFILE
#
# Prints the ISO 8601 expiry of PROFILE's credentials, or nothing when they
# do not expire (e.g. static keys).
_aws_credential_expiration() {
    aws configure export-credentials --profile "$1" 2>/dev/null \
        | jq -r '.Expiration // empty' 2>/dev/null
}

# _aws_fetch_session PROFILE
#
# Runs `aws sts get-caller-identity` and the credential-expiry lookup in
# parallel (each AWS CLI start-up costs ~0.5-1s). Sets the caller's `response`
# (identity JSON, or the error text) and `expiration`; returns the sts status.
_aws_fetch_session() {
    local profile="$1"
    local expiration_file sts_rc
    expiration_file=$(mktemp)

    # Job control is off inside $(...), so the background job prints no notices
    response=$(
        _aws_credential_expiration "$profile" > "$expiration_file" &
        aws sts get-caller-identity --profile "$profile" 2>&1
        sts_rc=$?
        wait
        exit "$sts_rc"
    )
    sts_rc=$?

    expiration=$(cat "$expiration_file")
    rm -f "$expiration_file"
    return "$sts_rc"
}

# _aws_export_account_id RESPONSE
#
# Exports AWS_ACCOUNT_ID from a get-caller-identity RESPONSE. The profile list
# only knows the account for SSO profiles, so keys/role profiles need this.
_aws_export_account_id() {
    local account_id
    account_id=$(echo "$1" | jq -r '.Account // empty' 2>/dev/null)
    if [ -n "$account_id" ]; then
        export AWS_ACCOUNT_ID="$account_id"
    fi
}

# _warn_if_expiring_soon PROFILE [EXPIRATION]
#
# Reads the credential expiry time for PROFILE via aws configure export-credentials,
# or uses EXPIRATION when given (an empty value means "no expiry").
# Prints a colour-coded warning to stdout if expiry is within 15 minutes.
# Prints nothing and returns 0 when credentials have no expiry or are healthy.
_warn_if_expiring_soon() {
    local profile="$1"

    local expiration
    if [ $# -ge 2 ]; then
        expiration="$2"
    else
        expiration=$(_aws_credential_expiration "$profile")
    fi

    if [ -z "$expiration" ]; then
        return 0
    fi

    local expiry_epoch current_epoch
    expiry_epoch=$(_parse_iso8601_epoch "$expiration") || return 0
    current_epoch=$(date +%s)

    local seconds_left=$(( expiry_epoch - current_epoch ))
    local minutes_left=$(( seconds_left / 60 ))

    if [ "$seconds_left" -le 300 ]; then
        printf "%s⚠ CRITICAL: AWS credentials expire in %d minute(s)! Re-authenticate immediately.%s\n" \
            "${RED}" "$minutes_left" "${NC}"
    elif [ "$seconds_left" -le 900 ]; then
        printf "%s⚠  warning: AWS credentials expire in %d minute(s).%s\n" \
            "${YELLOW}" "$minutes_left" "${NC}"
    fi

    return 0
}

# _gcloud_token_status ACCOUNT
#
# Reads the cached credential for ACCOUNT via `gcloud auth describe` and prints
# "<expiry-epoch>|<can-refresh>|<expiry-display>", e.g.
# "1792537855|true|2026-10-20 23:10 UTC". Only the expiry, type, and whether a
# refresh token exists are extracted; token values never leave jq.
# Returns 1 when the credential can't be described or reports no expiry.
_gcloud_token_status() {
    local account="$1"

    local fields
    fields=$(gcloud auth describe "$account" --format=json 2>/dev/null \
        | jq -r '"\(.expiry // "")|\((.type // "") != "authorized_user" or (.refresh_token // "") != "")"' 2>/dev/null)

    local expiry can_refresh
    IFS='|' read -r expiry can_refresh <<< "$fields"

    # gcloud reports expiry as "MM-DD-YYYY HH:MM:SS" in UTC
    if ! echo "$expiry" | grep -qE '^[0-9]{2}-[0-9]{2}-[0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}$'; then
        return 1
    fi
    local iso
    iso=$(echo "$expiry" | sed -E 's/^([0-9]{2})-([0-9]{2})-([0-9]{4}) (.*)$/\3-\1-\2T\4Z/')

    local expiry_epoch
    expiry_epoch=$(_parse_iso8601_epoch "$iso") || return 1

    local display="${iso%:??Z}"
    printf "%s|%s|%s UTC\n" "$expiry_epoch" "$can_refresh" "${display/T/ }"
}

# _gcloud_warn_if_expiring_soon TOKEN_STATUS
#
# TOKEN_STATUS is the output of _gcloud_token_status. gcloud renews access tokens
# silently when it holds a refresh token (or a service account key), so this
# only warns for credentials that cannot refresh themselves. Uses the same
# thresholds as _warn_if_expiring_soon. Always returns 0.
_gcloud_warn_if_expiring_soon() {
    local token_status="$1"

    local expiry_epoch can_refresh _display
    IFS='|' read -r expiry_epoch can_refresh _display <<< "$token_status"

    if [ -z "$expiry_epoch" ] || [ "$can_refresh" = true ]; then
        return 0
    fi

    local seconds_left=$(( expiry_epoch - $(date +%s) ))
    local minutes_left=$(( seconds_left / 60 ))

    if [ "$seconds_left" -le 0 ]; then
        printf "%s⚠ CRITICAL: GCloud credentials have expired and cannot refresh. Run ck gcloud login --reauth.%s\n" \
            "${RED}" "${NC}"
    elif [ "$seconds_left" -le 300 ]; then
        printf "%s⚠ CRITICAL: GCloud credentials expire in %d minute(s) and cannot refresh! Re-authenticate immediately.%s\n" \
            "${RED}" "$minutes_left" "${NC}"
    elif [ "$seconds_left" -le 900 ]; then
        printf "%s⚠  warning: GCloud credentials expire in %d minute(s) and will not auto-refresh.%s\n" \
            "${YELLOW}" "$minutes_left" "${NC}"
    fi

    return 0
}

# _aws_describe_identity ARN
#
# Turns a caller-identity ARN into a readable label, e.g.
#   arn:aws:iam::123:user/jane                                  -> IAM user jane
#   arn:aws:sts::123:assumed-role/AWSReservedSSO_Admin_ab12/jane -> SSO Admin as jane
#   arn:aws:sts::123:assumed-role/Deploy/ci                     -> Role Deploy as ci
_aws_describe_identity() {
    local arn="$1"
    local resource="${arn#*:*:*:*:*:}"
    local rest role

    case "$resource" in
        root)
            echo "Root user"
            ;;
        user/*)
            echo "IAM user ${resource##*/}"
            ;;
        assumed-role/AWSReservedSSO_*)
            rest="${resource#assumed-role/AWSReservedSSO_}"
            role="${rest%%/*}"
            # Strip the random suffix AWS appends to the permission set name
            echo "SSO ${role%_*} as ${rest#*/}"
            ;;
        assumed-role/*)
            rest="${resource#assumed-role/}"
            echo "Role ${rest%%/*} as ${rest#*/}"
            ;;
        federated-user/*)
            echo "Federated user ${resource#federated-user/}"
            ;;
        *)
            echo "$arn"
            ;;
    esac
}

# _aws_credentials_summary PROFILE ARN EXPIRATION
#
# Prints the credential type and expiry, e.g.
#   "SSO · expires 2026-10-21 14:20 UTC (in 7h 12m)" or "Static keys · no expiry".
_aws_credentials_summary() {
    local profile="$1"
    local arn="$2"
    local expiration="$3"

    local label
    case "$(_detect_credential_type "$profile")" in
        sso) label="SSO" ;;
        keys) label="Static keys" ;;
        process) label="credential_process" ;;
        *)
            # Not in ~/.aws/config (e.g. keys in ~/.aws/credentials): infer from the identity
            if [[ "$arn" == *":assumed-role/"* ]]; then
                label="Assumed role"
            elif [[ "$arn" == *":user/"* && -z "$expiration" ]]; then
                label="Static keys"
            elif [[ "$arn" == *":user/"* ]]; then
                label="Session token"
            else
                label="Other"
            fi
            ;;
    esac

    if [ -z "$expiration" ]; then
        echo "$label · no expiry"
        return 0
    fi

    local expiry_epoch
    if ! expiry_epoch=$(_parse_iso8601_epoch "$expiration"); then
        echo "$label · expires $expiration"
        return 0
    fi

    local seconds_left=$(( expiry_epoch - $(date +%s) ))
    local when="${expiration:0:10} ${expiration:11:5} UTC"
    if [ "$seconds_left" -le 0 ]; then
        echo "$label · expired $when"
    else
        local hours=$(( seconds_left / 3600 ))
        local minutes=$(( seconds_left % 3600 / 60 ))
        echo "$label · expires $when (in ${hours}h ${minutes}m)"
    fi
}

# _gcloud_adc_summary ACCOUNT
#
# Describes the Application Default Credentials that SDKs and tools like
# Terraform use, compared with the gcloud ACCOUNT. Prints "<level>|<text>"
# where level is ok, info or warn. Reads only type/account fields from the
# credential file; secrets never leave jq.
_gcloud_adc_summary() {
    local account="$1"
    local file="${GOOGLE_APPLICATION_CREDENTIALS:-}"
    local source_note=""

    if [ -n "$file" ]; then
        source_note=" (GOOGLE_APPLICATION_CREDENTIALS)"
    else
        file="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}/application_default_credentials.json"
    fi

    if [ ! -f "$file" ]; then
        echo "warn|not set${source_note} -- run: gcloud auth application-default login"
        return 0
    fi

    local fields type email impersonated
    fields=$(jq -r '
        (.service_account_impersonation_url // "") as $u
        | "\(.type // "")|\(.client_email // .account // "")|\(if ($u | test("serviceAccounts/")) then ($u | capture("serviceAccounts/(?<sa>[^:]+)").sa) else "" end)"
        ' "$file" 2>/dev/null)
    IFS='|' read -r type email impersonated <<< "$fields"

    if [ -n "$impersonated" ]; then
        echo "info|impersonating ${impersonated}${source_note}"
    elif [ "$type" = "service_account" ]; then
        echo "info|service account ${email}${source_note}"
    elif [ "$type" = "authorized_user" ]; then
        if [ -z "$email" ]; then
            echo "info|user login${source_note} (account not recorded)"
        elif [ "$email" = "$account" ]; then
            echo "ok|same as gcloud account${source_note}"
        else
            echo "warn|different account: ${email}${source_note} -- run: gcloud auth application-default login"
        fi
    else
        echo "info|${type:-unknown} credentials${source_note}"
    fi
}

# _ck_is_prod NAME...
#
# Returns 0 when any NAME looks like a production environment. The pattern is
# an extended regex matched case-insensitively; override with CLOUDKIT_PROD_PATTERN.
_ck_is_prod() {
    local pattern="${CLOUDKIT_PROD_PATTERN:-(^|[-_.:/ ])(prod|production|prd)($|[-_.:/ 0-9])}"
    local name
    for name in "$@"; do
        if [ -n "$name" ] && echo "$name" | grep -qiE "$pattern"; then
            return 0
        fi
    done
    return 1
}

# _ck_prod_banner NAME...
#
# Prints a red PRODUCTION banner when any NAME matches _ck_is_prod.
_ck_prod_banner() {
    if _ck_is_prod "$@"; then
        printf "%s  ▲ PRODUCTION  %s\n\n" "${PROD_BADGE}" "${NC}"
    fi
}

# _update_prompt
#
# Detects the running shell and updates the interactive prompt to display the
# active sessions: [AWS_PROFILE:AWS_DEFAULT_REGION] and/or
# [gcloud:GCLOUD_ACCOUNT:GCLOUD_PROJECT]. Production sessions get a red [PROD]
# marker. Does nothing when CLOUDKIT_NO_PROMPT is set.
# Saves the original prompt to $ORG_PROMPT the first time.
_update_prompt() {
    local prefix

    if [ -n "${CLOUDKIT_NO_PROMPT:-}" ]; then
        return 0
    fi

    local prod_marker
    if [ -n "${ZSH_VERSION:-}" ]; then
        prod_marker="%F{red}%B[PROD]%b%f "
    else
        prod_marker="\[\033[1;31m\][PROD]\[\033[0m\] "
    fi

    # One segment per active session, so AWS and gcloud can show together
    prefix=""
    if [ -n "${AWS_PROFILE:-}" ]; then
        if _ck_is_prod "$AWS_PROFILE"; then
            prefix+="$prod_marker"
        fi
        prefix+="[${AWS_PROFILE}:${AWS_DEFAULT_REGION:-}] "
    fi
    if [ -n "${GCLOUD_ACCOUNT:-}" ]; then
        if _ck_is_prod "${GCLOUD_ACTIVE_CONFIG:-}" "${GCLOUD_PROJECT:-}"; then
            prefix+="$prod_marker"
        fi
        prefix+="[gcloud:${GCLOUD_ACCOUNT}:${GCLOUD_PROJECT:-}] "
    fi

    # Save original prompt once
    if [ -z "${ORG_PROMPT:-}" ]; then
        if [ -n "${ZSH_VERSION:-}" ]; then
            export ORG_PROMPT="${PROMPT:-}"
        else
            export ORG_PROMPT="${PS1:-}"
        fi
    fi

    if [ -n "${ZSH_VERSION:-}" ]; then
        export PROMPT="${prefix}${ORG_PROMPT}"
    else
        export PS1="${prefix}${ORG_PROMPT}"
    fi
}

# _detect_credential_type PROFILE_NAME
#
# Reads ~/.aws/config for the given profile stanza and outputs one of:
#   "sso"     — profile has sso_account_id or sso_start_url
#   "keys"    — profile has aws_access_key_id
#   "process" — profile has credential_process
#   "unknown" — none of the above found
_detect_credential_type() {
    local profile_name="$1"
    local config_file="$HOME/.aws/config"

    if [ ! -f "$config_file" ]; then
        echo "unknown"
        return 0
    fi

    local in_section=false
    local line key

    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$line" ] && continue

        # Detect section header
        if echo "$line" | grep -q '^\['; then
            # Check if this is our target profile
            if [[ "$line" == "[profile ${profile_name}]" ]] || \
               [[ "$line" == "[${profile_name}]" ]]; then
                in_section=true
            else
                # If we were in the section, we've left it
                if [ "$in_section" = true ]; then
                    break
                fi
                in_section=false
            fi
            continue
        fi

        if [ "$in_section" = false ]; then
            continue
        fi

        key="${line%%=*}"
        key="${key%"${key##*[![:space:]]}"}"

        case "$key" in
            sso_account_id|sso_start_url)
                echo "sso"
                return 0
                ;;
            aws_access_key_id)
                echo "keys"
                return 0
                ;;
            credential_process)
                echo "process"
                return 0
                ;;
        esac
    done < "$config_file"

    echo "unknown"
    return 0
}

# _ck_refresh_prompt_after_logout
#
# Redraws the prompt for the session that is still active, or restores the
# original prompt when no session is left.
_ck_refresh_prompt_after_logout() {
    if [ -n "${AWS_PROFILE:-}" ] || [ -n "${GCLOUD_ACCOUNT:-}" ]; then
        if [ -n "${ORG_PROMPT:-}" ]; then
            _update_prompt
        fi
        return 0
    fi

    if [ -n "${ORG_PROMPT:-}" ]; then
        if [ -n "${ZSH_VERSION:-}" ]; then
            export PROMPT="$ORG_PROMPT"
        else
            export PS1="$ORG_PROMPT"
        fi
    fi
    unset ORG_PROMPT
}

# _ck_aws_logout (ck aws logout)
#
# Clears the active AWS session from the shell environment.
# Unsets all AWS_* session variables, restores the original shell prompt,
# and prints a confirmation message.
# Does NOT delete any files from ~/.aws/
_ck_aws_logout() {
    unset AWS_PROFILE
    unset AWS_DEFAULT_PROFILE
    unset AWS_REGION
    unset AWS_DEFAULT_REGION
    unset AWS_ACCOUNT_ID

    _ck_refresh_prompt_after_logout

    printf "%sSuccessfully logged out. AWS session cleared.%s\n" "${GREEN}" "${NC}"
    return 0
}

# _ck_aws_switch (ck aws switch)
#
# Switches to a different AWS profile within the current shell session.
# Presents the full profile list, validates credentials, and updates the prompt.
_ck_aws_switch() {
    if ! command -v jq > /dev/null 2>&1; then
        printf "%sError: jq is required. Please install jq.%s\n" "${RED}" "${NC}"
        return 1
    fi

    if ! command -v aws > /dev/null 2>&1; then
        printf "%sError: AWS CLI is required. Please install it.%s\n" "${RED}" "${NC}"
        return 1
    fi

    if [ ! -f "$HOME/.aws/config" ]; then
        printf "%sError: ~/.aws/config not found%s\n" "${RED}" "${NC}"
        return 1
    fi

    # Build profile map (all credential types)
    local temp_map
    temp_map=$(mktemp)

    local current_profile="" current_account="" current_region=""

    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [ -z "$line" ] && continue

        if echo "$line" | grep -q '^\['; then
            if [ -n "$current_profile" ]; then
                echo "${current_account:-N/A}:${current_profile}:${current_region:-N/A}" >> "$temp_map"
            fi
            if [[ "$line" == "[profile "* ]]; then
                current_profile="${line#\[profile }"
                current_profile="${current_profile%%\]*}"
            elif [[ "$line" == "[default]" ]]; then
                current_profile="default"
            else
                current_profile=""
            fi
            current_account=""
            current_region=""
            continue
        fi

        if [[ "$line" == sso_account_id* ]] && [ -z "$current_account" ]; then
            current_account="${line#*=}"
            current_account="${current_account#"${current_account%%[![:space:]]*}"}"
        elif [[ "$line" == aws_access_key_id* ]] && [ -z "$current_account" ]; then
            current_account="(keys)"
        elif [[ "$line" == credential_process* ]] && [ -z "$current_account" ]; then
            current_account="(process)"
        fi

        if [[ "$line" == region* ]]; then
            current_region="${line#*=}"
            current_region="${current_region#"${current_region%%[![:space:]]*}"}"
        fi
    done < "$HOME/.aws/config"

    if [ -n "$current_profile" ]; then
        echo "${current_account:-N/A}:${current_profile}:${current_region:-N/A}" >> "$temp_map"
    fi

    if ! select_profile "$temp_map"; then
        rm -f "$temp_map"
        return 1
    fi
    rm -f "$temp_map"

    # Validate credentials for the selected profile
    local response expiration
    if ! _aws_fetch_session "$AWS_PROFILE"; then
        local cred_type
        cred_type=$(_detect_credential_type "$AWS_PROFILE")
        if [ "$cred_type" = "sso" ]; then
            printf "%sInitiating SSO login for %s...%s\n" "${BOLD_GREEN}" "$AWS_PROFILE" "${NC}"
            aws sso login --profile "$AWS_PROFILE"
            if ! _aws_fetch_session "$AWS_PROFILE"; then
                printf "%sFailed to authenticate with profile: %s%s\n" "${RED}" "$AWS_PROFILE" "${NC}"
                return 1
            fi
        else
            printf "%sFailed to authenticate with profile: %s%s\n" "${RED}" "$AWS_PROFILE" "${NC}"
            return 1
        fi
    fi

    _aws_export_account_id "$response"
    _update_prompt
    clear_terminal
    create_and_display_table "$response" "$AWS_REGION" "$expiration"
    _warn_if_expiring_soon "$AWS_PROFILE" "$expiration"
    return 0
}

# Clear the screen and scrollback so the session table starts at the top.
# Skipped when CLOUDKIT_NO_CLEAR is set or stdout is not a terminal.
clear_terminal() {
    if [ -n "${CLOUDKIT_NO_CLEAR:-}" ] || [ ! -t 1 ]; then
        return 0
    fi
    # Cursor home, clear screen, clear scrollback
    printf '\033[H\033[2J\033[3J'
}

# Get AWS credentials and account information
get_credentials() {
    local current_region="${AWS_DEFAULT_REGION:-us-east-1}"

    # Get caller identity from AWS STS
    local response
    if ! response=$(aws sts get-caller-identity --region "$current_region" 2>&1); then
        echo "AWS Credentials not available"
        return 1
    fi

    echo "$response"
}

# Check if AWS credentials are expired. Uses EXPIRATION when given instead of
# looking it up.
# Returns 0 if expired, 1 if valid or no expiry information is available.
check_credentials_expiration() {
    local profile="$1"
    local expiration

    if [ $# -ge 2 ]; then
        expiration="$2"
    else
        expiration=$(_aws_credential_expiration "$profile")
    fi

    if [ -z "$expiration" ]; then
        return 1
    fi

    local expiration_epoch current_epoch
    expiration_epoch=$(_parse_iso8601_epoch "$expiration") || return 1
    current_epoch=$(date +%s)

    if [ "$expiration_epoch" -lt "$current_epoch" ]; then
        return 0
    fi

    return 1
}

# Create and display table with AWS information using column -t
# Usage: create_and_display_table RESPONSE REGION [EXPIRATION]
create_and_display_table() {
    local response="$1"
    local current_region="${2:-N/A}"
    local expiration="${3:-}"

    # Extract values from JSON response (requires jq)
    local aws_account_id
    local aws_arn

    aws_account_id=$(echo "$response" | jq -r '.Account')
    aws_arn=$(echo "$response" | jq -r '.Arn')

    local aws_profile="${AWS_PROFILE:-default}"

    # Format account ID as XXXX-XXXX-XXXX
    local formatted_account_id="${aws_account_id:0:4}-${aws_account_id:4:4}-${aws_account_id:8:4}"

    local identity credentials
    identity=$(_aws_describe_identity "$aws_arn")
    local identity_color="$GREEN"
    if [ "$identity" = "Root user" ]; then
        identity_color="$RED"
    fi
    credentials=$(_aws_credentials_summary "$aws_profile" "$aws_arn" "$expiration")

    # Print header
    printf "\n%s━━━ AWS Session Information ━━━%s\n\n" "${BOLD_GREEN}" "${NC}"
    _ck_prod_banner "$aws_profile"

    # Build table data, pipe through column -t, then colorize with sed
    {
        printf "Info|Value\n"
        printf "────────────|────────────────────────────────────────────────────────\n"
        printf "Account|%s\n" "$formatted_account_id"
        printf "Profile|%s\n" "$aws_profile"
        printf "Region|%s\n" "$current_region"
        printf "Identity|%s\n" "$identity"
        printf "Credentials|%s\n" "$credentials"
    } | column -t -s '|' | sed \
        -e "1s/.*/${BOLD}&${NC}/" \
        -e "s/\(Account[[:space:]]*\)\(.*\)/\1${RED}\2${NC}/" \
        -e "s/\(Profile[[:space:]]*\)\(.*\)/\1${BLUE}\2${NC}/" \
        -e "s/\(Region[[:space:]]*\)\(.*\)/\1${CYAN}\2${NC}/" \
        -e "s/\(Identity[[:space:]]*\)\(.*\)/\1${identity_color}\2${NC}/" \
        -e "s/\(Credentials[[:space:]]*\)\(.*\)/\1${GRAY}\2${NC}/"

    printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n" "${BOLD_GREEN}" "${NC}"
}

create_and_display_gcloud_table() {
    local account="$1"
    local project="$2"
    local token_status="${3:-}"

    local token_expiry="N/A"
    if [ -n "$token_status" ]; then
        local _epoch can_refresh display
        IFS='|' read -r _epoch can_refresh display <<< "$token_status"
        if [ "$can_refresh" = true ]; then
            token_expiry="$display (auto-refresh)"
        else
            token_expiry="$display (no refresh)"
        fi
    fi

    local config_name="${GCLOUD_ACTIVE_CONFIG:-$(gcloud config configurations list --filter='is_active=true' --format='value(name)' 2>/dev/null)}"
    local region
    if [ -n "${GCLOUD_REGION+x}" ]; then
        region="$GCLOUD_REGION"
    else
        region=$(gcloud config get-value compute/region 2>/dev/null)
    fi
    if [ -z "$region" ] || [ "$region" = "(unset)" ]; then
        region="N/A"
    fi

    local adc adc_level adc_text adc_color
    adc=$(_gcloud_adc_summary "$account")
    IFS='|' read -r adc_level adc_text <<< "$adc"
    case "$adc_level" in
        ok) adc_color="$GREEN" ;;
        warn) adc_color="$YELLOW"; adc_text="⚠ $adc_text" ;;
        *) adc_color="$NC" ;;
    esac

    printf "\n%s━━━ GCloud Session Information ━━━%s\n\n" "${BOLD_GREEN}" "${NC}"
    _ck_prod_banner "$config_name" "$project"

    {
        printf "Info|Value\n"
        printf "────────────|────────────────────────────────────────────────────────\n"
        printf "Account|%s\n" "$account"
        printf "Configuration|%s\n" "$config_name"
        printf "Project|%s\n" "$project"
        printf "Region|%s\n" "$region"
        printf "Token Expiry|%s\n" "$token_expiry"
        printf "ADC|%s\n" "$adc_text"
    } | column -t -s '|' | sed \
        -e "1s/.*/${BOLD}&${NC}/" \
        -e "s/\(Account[[:space:]]*\)\(.*\)/\1${RED}\2${NC}/" \
        -e "s/\(Configuration[[:space:]]*\)\(.*\)/\1${BLUE}\2${NC}/" \
        -e "s/\(Project[[:space:]]*\)\(.*\)/\1${GREEN}\2${NC}/" \
        -e "s/\(Region[[:space:]]*\)\(.*\)/\1${CYAN}\2${NC}/" \
        -e "s/\(Token Expiry[[:space:]]*\)\(.*\)/\1${GRAY}\2${NC}/" \
        -e "s/\(ADC[[:space:]]*\)\(.*\)/\1${adc_color}\2${NC}/"

    printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n" "${BOLD_GREEN}" "${NC}"
}

# _aws_export_region REGION
#
# Exports AWS_REGION / AWS_DEFAULT_REGION for the selected profile. A profile
# without a region (empty, or "N/A" in the switch list) unsets them instead, so
# the AWS CLI uses its own configuration rather than an invalid or stale region.
_aws_export_region() {
    if [ -n "$1" ] && [ "$1" != "N/A" ]; then
        export AWS_REGION="$1"
        export AWS_DEFAULT_REGION="$1"
    else
        unset AWS_REGION AWS_DEFAULT_REGION
    fi
}

select_profile() {
    local temp_map="$1"
    local count=0
    local choice_line=""

    # Count profiles
    count=$(wc -l < "$temp_map")

    if [ "$count" -eq 0 ]; then
        printf "%sError: No profiles found in ~/.aws/config%s\n" "${RED}" "${NC}"
        printf "%sDebug: Make sure your AWS config has sso_account_id and region set for each profile%s\n" "${GRAY}" "${NC}"
        printf "%sExample format:%s\n" "${BLUE}" "${NC}"
        printf "[profile my-profile]\n"
        printf "sso_account_id = 123456789012\n"
        printf "region = us-east-1\n"
        return 1
    fi

    # Auto-select if only one profile available
    if [ "$count" -eq 1 ]; then
        local account profile region
        IFS=':' read -r account profile region < "$temp_map"

        export AWS_PROFILE="$profile"
        export AWS_DEFAULT_PROFILE="$profile"
        _aws_export_region "$region"
        export AWS_ACCOUNT_ID="$account"

        printf "\n%sAuto-selecting the only available profile: %s%s%s (Account: %s)%s\n" \
            "${GREEN}" "${BOLD}" "$profile" "${NC}" "$account" "${NC}"
        return 0
    fi

    printf "\n%sAvailable AWS Profiles:%s\n\n" "${BOLD_GREEN}" "${NC}"

    # Build profile table, pipe through column -t, then colorize with sed
    {
        printf "#|Profile|Account|Region\n"
        printf "─|───────────────────────────|──────────────|──────────────\n"

        local line_num=1
        while IFS=':' read -r account profile region; do
            printf "[%d]|%s|%s|%s\n" "$line_num" "$profile" "$account" "$region"
            line_num=$((line_num + 1))
        done < "$temp_map"
    } | column -t -s '|' | sed \
        -e "1s/.*/${BOLD}&${NC}/" \
        -e "s/\(\[[[0-9]*\]\)/${BLUE}\1${NC}/g"

    printf "\n"

    printf "\n%sSelect a profile [1-%d]: %s" "${BOLD}" "$count" "${NC}"
    read -r choice

    # Validate choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        printf "%sInvalid selection.%s\n" "${RED}" "${NC}"
        return 1
    fi

    # Get the selected line from the temp_map
    choice_line=$(sed -n "${choice}p" "$temp_map")

    # Parse the line
    local account profile region
    IFS=':' read -r account profile region <<< "$choice_line"

    # Export the selected profile and region
    export AWS_PROFILE="$profile"
    export AWS_DEFAULT_PROFILE="$profile"
    _aws_export_region "$region"
    export AWS_ACCOUNT_ID="$account"

    printf "%sSelected profile: %s%s (Account: %s%s)\n" \
        "${GREEN}" "${BOLD}" "$AWS_PROFILE" "${NC}" "$AWS_ACCOUNT_ID"
}

# Find profiles that chain from a given source profile (via source_profile)
find_chained_profiles() {
    local source="$1"
    local output_file="$2"

    local current_profile=""
    local current_source=""
    local current_region=""
    local current_role_arn=""

    while IFS= read -r line; do
        # Remove leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty lines and comments
        [ -z "$line" ] && continue

        # When we hit a new section header, save previous if it chains from source
        if echo "$line" | grep -q '^\['; then
            if [ -n "$current_source" ] && [ "$current_source" = "$source" ] && [ -n "$current_profile" ]; then
                echo "$current_profile:$current_region:$current_role_arn" >> "$output_file"
            fi

            # Extract the new profile name
            if [[ "$line" == "[profile "* ]]; then
                current_profile="${line#\[profile }"
                current_profile="${current_profile%%\]*}"
            elif [[ "$line" == "[default]" ]]; then
                current_profile="default"
            fi
            current_source=""
            current_region=""
            current_role_arn=""
            continue
        fi

        # Extract source_profile
        if [[ "$line" == source_profile* ]]; then
            current_source="${line#*=}"
            current_source="${current_source#"${current_source%%[![:space:]]*}"}"
        fi

        # Extract region
        if [[ "$line" == region* ]]; then
            current_region="${line#*=}"
            current_region="${current_region#"${current_region%%[![:space:]]*}"}"
        fi

        # Extract role_arn
        if echo "$line" | grep -q '^role_arn'; then
            current_role_arn=$(echo "$line" | sed 's/^role_arn[[:space:]]*=[[:space:]]*\(.*\)/\1/' | sed 's/[[:space:]]*$//')
        fi
    done < "$HOME/.aws/config"

    # Don't forget the last profile
    if [ -n "$current_source" ] && [ "$current_source" = "$source" ] && [ -n "$current_profile" ]; then
        echo "$current_profile:$current_region:$current_role_arn" >> "$output_file"
    fi
}

# Prompt user to select a chained profile or auto-select if only one exists
select_chained_profile() {
    local chained_file="$1"
    local count=0

    # Check if file exists and has content
    if [ ! -s "$chained_file" ]; then
        return 0
    fi

    count=$(wc -l < "$chained_file" | tr -d ' ')

    if [ "$count" -eq 0 ]; then
        return 0
    fi

    # Auto-select if only one chained profile
    if [ "$count" -eq 1 ]; then
        local profile region role_arn
        IFS=':' read -r profile region role_arn < "$chained_file"

        printf "\n%sFound chained profile: %s%s%s\n" "${CYAN}" "${BOLD}" "$profile" "${NC}"
        printf "%sAuto-selecting chained profile...%s\n" "${GREEN}" "${NC}"

        export AWS_PROFILE="$profile"
        export AWS_DEFAULT_PROFILE="$profile"

        if [ -n "$region" ]; then
            export AWS_REGION="$region"
            export AWS_DEFAULT_REGION="$region"
        fi

        return 0
    fi

    # Multiple chained profiles — prompt user to choose
    printf "\n%sChained profiles found for %s%s%s:%s\n\n" \
        "${BOLD_GREEN}" "${BOLD}" "$AWS_PROFILE" "${BOLD_GREEN}" "${NC}"

    # Build chained profile table
    {
        printf "#|Profile|Region|Role ARN\n"
        printf "─|───────────────────────────|──────────────|──────────────────────────────────────\n"

        local line_num=1
        while IFS=':' read -r profile region role_arn; do
            printf "[%d]|%s|%s|%s\n" "$line_num" "$profile" "${region:-N/A}" "${role_arn:-N/A}"
            line_num=$((line_num + 1))
        done < "$chained_file"
    } | column -t -s '|' | sed \
        -e "1s/.*/${BOLD}&${NC}/" \
        -e "s/\(\[[[0-9]*\]\)/${BLUE}\1${NC}/g"

    printf "\n"

    printf "\n%sSelect a chained profile [1-%d]: %s" "${BOLD}" "$count" "${NC}"
    read -r choice

    # Validate choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        printf "%sInvalid selection. Keeping current profile: %s%s\n" "${RED}" "$AWS_PROFILE" "${NC}"
        return 0
    fi

    # Get the selected line
    local choice_line
    choice_line=$(sed -n "${choice}p" "$chained_file")

    local profile region role_arn
    IFS=':' read -r profile region role_arn <<< "$choice_line"

    export AWS_PROFILE="$profile"
    export AWS_DEFAULT_PROFILE="$profile"

    if [ -n "$region" ]; then
        export AWS_REGION="$region"
        export AWS_DEFAULT_REGION="$region"
    fi

    printf "%sSwitched to chained profile: %s%s%s\n" "${GREEN}" "${BOLD}" "$profile" "${NC}"
}

# _ck_prompt_gcloud_section hide|show
#
# Prompt themes such as Spaceship read gcloud's config files directly, so they
# would keep showing the global configuration while this shell has no account.
# Hides Spaceship's gcloud section while unselected and restores the user's
# own SPACESHIP_GCLOUD_SHOW setting afterwards.
_ck_prompt_gcloud_section() {
    if [ "$1" = "hide" ]; then
        if [ -z "${_CK_SPACESHIP_GCLOUD_SHOW_SAVED+x}" ]; then
            _CK_SPACESHIP_GCLOUD_SHOW_SAVED="${SPACESHIP_GCLOUD_SHOW-}"
        fi
        SPACESHIP_GCLOUD_SHOW=false
    elif [ -n "${_CK_SPACESHIP_GCLOUD_SHOW_SAVED+x}" ]; then
        if [ -n "$_CK_SPACESHIP_GCLOUD_SHOW_SAVED" ]; then
            SPACESHIP_GCLOUD_SHOW="$_CK_SPACESHIP_GCLOUD_SHOW_SAVED"
        else
            unset SPACESHIP_GCLOUD_SHOW
        fi
        unset _CK_SPACESHIP_GCLOUD_SHOW_SAVED
    fi
}

# _ck_gcloud_start_unselected
#
# Leaves this shell without a gcloud account until `ck gcloud login`/`switch`
# (like a shell without AWS_PROFILE). An empty CLOUDSDK_CORE_ACCOUNT overrides
# the account of gcloud's active configuration, so gcloud reports "no active
# account selected"; no extra configuration is created.
_ck_gcloud_start_unselected() {
    unset CLOUDSDK_ACTIVE_CONFIG_NAME
    export CLOUDSDK_CORE_ACCOUNT=""
    _ck_prompt_gcloud_section hide
}

# _ck_gcloud_unselected
#
# Returns 0 when this shell has no gcloud account selected by
# _ck_gcloud_start_unselected.
_ck_gcloud_unselected() {
    [ -n "${CLOUDSDK_CORE_ACCOUNT+x}" ] && [ -z "$CLOUDSDK_CORE_ACCOUNT" ]
}

# _ck_gcloud_use_config NAME
#
# Selects gcloud configuration NAME for this shell only, the way AWS_PROFILE
# works: gcloud (and tools that shell out to it, plus prompt themes such as
# Spaceship) read CLOUDSDK_ACTIVE_CONFIG_NAME before the global active config.
# Unlike `gcloud config configurations activate`, other and new terminals keep
# using the global default.
_ck_gcloud_use_config() {
    unset CLOUDSDK_CORE_ACCOUNT
    export CLOUDSDK_ACTIVE_CONFIG_NAME="$1"
    _ck_prompt_gcloud_section show
}

# shellcheck disable=SC2329
select_gcloud_profile() {
    local temp_map="$1"
    local count=0
    local choice_line=""

    # Count configurations
    count=$(wc -l < "$temp_map")

    if [ "$count" -eq 0 ]; then
        printf "%sError: No gcloud configurations found.%s\n" "${RED}" "${NC}"
        printf "%sTip: Create one with: gcloud config configurations create <name>%s\n" "${GRAY}" "${NC}"
        return 1
    fi

    # Auto-select if only one configuration available
    if [ "$count" -eq 1 ]; then
        local name _active account project region
        IFS=':' read -r name _active account project region < "$temp_map"

        # Per-shell selection, like AWS_PROFILE (see _ck_gcloud_use_config)
        _ck_gcloud_use_config "$name"
        export GCLOUD_ACTIVE_CONFIG="$name"
        export GCLOUD_ACCOUNT="$account"
        export GCLOUD_PROJECT="$project"
        export GCLOUD_REGION="$region"

        printf "\n%sAuto-selecting the only available configuration: %s%s%s (Account: %s)%s\n" \
            "${GREEN}" "${BOLD}" "$name" "${NC}" "$account" "${NC}"
        return 0
    fi

    printf "\n%sAvailable GCloud Configurations:%s\n\n" "${BOLD_GREEN}" "${NC}"

    {
        printf "#|Config|Active|Account|Project\n"
        printf "─|───────────────────────────|────────|────────────────────────────|────────────────────────────\n"

        local line_num=1
        while IFS=':' read -r name active account project _region; do
            printf "[%d]|%s|%s|%s|%s\n" "$line_num" "$name" "$active" "$account" "$project"
            line_num=$((line_num + 1))
        done < "$temp_map"
    } | column -t -s '|' | sed \
        -e "1s/.*/${BOLD}&${NC}/" \
        -e "s/\(\[[[0-9]*\]\)/${BLUE}\1${NC}/g" \
        -e "s/\(Active[[:space:]]*\)\(True\)/\1${GREEN}\2${NC}/" \
        -e "s/\(Active[[:space:]]*\)\(False\)/\1${GRAY}\2${NC}/"

    printf "\n"

    printf "\n%sSelect a configuration [1-%d]: %s" "${BOLD}" "$count" "${NC}"
    read -r choice

    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        printf "%sInvalid selection.%s\n" "${RED}" "${NC}"
        return 1
    fi

    choice_line=$(sed -n "${choice}p" "$temp_map")

    local name _active account project region
    IFS=':' read -r name _active account project region <<< "$choice_line"

    _ck_gcloud_use_config "$name"
    export GCLOUD_ACTIVE_CONFIG="$name"
    export GCLOUD_ACCOUNT="$account"
    export GCLOUD_PROJECT="$project"
    export GCLOUD_REGION="$region"

    printf "%sSelected configuration: %s%s%s\n" "${GREEN}" "${BOLD}" "$name" "${NC}"
}

_ck_aws_login() {
    # Check if jq is installed
    if ! command -v jq > /dev/null 2>&1; then
        printf "%sError: jq is required to parse AWS response. Please install jq.%s\n" "${RED}" "${NC}"
        return 1
    fi

    # Check if aws cli is installed
    if ! command -v aws > /dev/null 2>&1; then
        printf "%sError: AWS CLI is required. Please install it.%s\n" "${RED}" "${NC}"
        return 1
    fi

    # Check if config file exists
    if [ ! -f "$HOME/.aws/config" ]; then
        printf "%sError: ~/.aws/config not found%s\n" "${RED}" "${NC}"
        return 1
    fi

    # Build the account ID to profile mapping
    local temp_map
    temp_map=$(mktemp)

    local current_profile=""
    local current_account=""
    local current_region=""

    while IFS= read -r line; do
        # Remove leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty lines and comments
        [ -z "$line" ] && continue

        # When we hit a new section header, save the previous profile
        if echo "$line" | grep -q '^\['; then
            if [ -n "$current_account" ]; then
                echo "$current_account:$current_profile:$current_region" >> "$temp_map"
            fi

            # Extract the new profile name
            if [[ "$line" == "[profile "* ]]; then
                current_profile="${line#\[profile }"
                current_profile="${current_profile%%\]*}"
            elif [[ "$line" == "[default]" ]]; then
                current_profile="default"
            fi
            current_account=""
            current_region=""
            continue
        fi

        # Extract sso_account_id
        if [[ "$line" == sso_account_id* ]]; then
            current_account="${line#*=}"
            current_account="${current_account#"${current_account%%[![:space:]]*}"}"
        fi

        # Extract region
        if [[ "$line" == region* ]]; then
            current_region="${line#*=}"
            current_region="${current_region#"${current_region%%[![:space:]]*}"}"
        fi
    done < "$HOME/.aws/config"

    # Don't forget the last profile
    if [ -n "$current_account" ]; then
        echo "$current_account:$current_profile:$current_region" >> "$temp_map"
    fi

    # Ask user to select a profile
    if ! select_profile "$temp_map"; then
        rm -f "$temp_map"
        return 1
    fi
    rm -f "$temp_map"

    # Check if already authenticated and not expired
    local response expiration
    local credentials_valid=false

    if _aws_fetch_session "$AWS_PROFILE"; then
        # Credentials exist, check if they're expired
        if check_credentials_expiration "$AWS_PROFILE" "$expiration"; then
            printf "%s%s%s\n" "${BOLD_GREEN}" "AWS credentials expired. Initiating SSO login..." "${NC}"
        else
            credentials_valid=true
            printf "%sCredentials are valid and not expired%s\n" "${GREEN}" "${NC}"
        fi
    else
        printf "%s%s%s\n" "${BOLD_GREEN}" "AWS credentials not available. Initiating SSO login..." "${NC}"
    fi

    # If credentials are not valid, perform SSO login
    if [ "$credentials_valid" = false ]; then
        aws sso login --profile "$AWS_PROFILE"

        # Try again after login
        if ! _aws_fetch_session "$AWS_PROFILE"; then
            printf "%s%s%s\n" "${RED}" "Failed to authenticate" "${NC}"
            printf "%s%s%s\n" "${RED}" "$response" "${NC}"
            return 1
        fi
    fi

    printf "%sSuccessfully authenticated with profile: %s%s\n" "${GREEN}" "${BOLD}" "${AWS_PROFILE}${NC}"

    # Check for chained profiles (profiles with source_profile pointing to selected profile)
    local chained_file
    chained_file=$(mktemp)
    local selected_base_profile="$AWS_PROFILE"

    find_chained_profiles "$AWS_PROFILE" "$chained_file"

    if [ -s "$chained_file" ]; then
        select_chained_profile "$chained_file"

        # If profile changed, re-fetch identity with the chained profile
        if [ "$AWS_PROFILE" != "$selected_base_profile" ]; then
            if ! _aws_fetch_session "$AWS_PROFILE"; then
                printf "%sFailed to get identity for chained profile: %s%s\n" "${RED}" "$AWS_PROFILE" "${NC}"
                printf "%sFalling back to base profile: %s%s\n" "${CYAN}" "$selected_base_profile" "${NC}"
                export AWS_PROFILE="$selected_base_profile"
                export AWS_DEFAULT_PROFILE="$selected_base_profile"
                _aws_fetch_session "$AWS_PROFILE"
            fi

        fi
    fi

    rm -f "$chained_file"
    _aws_export_account_id "$response"

    clear_terminal
    create_and_display_table "$response" "$AWS_REGION" "$expiration"
    _update_prompt
    _warn_if_expiring_soon "$AWS_PROFILE" "$expiration"
}

_ck_gcloud_logout() {
    unset GCLOUD_ACTIVE_CONFIG
    unset GCLOUD_ACCOUNT
    unset GCLOUD_PROJECT
    unset GCLOUD_REGION
    # Back to no gcloud account (or gcloud's global default with CLOUDKIT_GCLOUD_GLOBAL)
    unset CLOUDSDK_ACTIVE_CONFIG_NAME
    if [ -z "${CLOUDKIT_GCLOUD_GLOBAL:-}" ]; then
        _ck_gcloud_start_unselected
    fi

    _ck_refresh_prompt_after_logout

    printf "%sSuccessfully logged out. GCloud session cleared.%s\n" "${GREEN}" "${NC}"
    return 0
}

_ck_gcloud_switch() {
    if ! command -v jq > /dev/null 2>&1; then
        printf "%sError: jq is required. Please install jq.%s\n" "${RED}" "${NC}"
        return 1
    fi

    if ! command -v gcloud > /dev/null 2>&1; then
        printf "%sError: gcloud CLI is required. Please install it.%s\n" "${RED}" "${NC}"
        return 1
    fi

    local temp_map
    temp_map=$(mktemp)

    gcloud config configurations list --format=json 2>/dev/null | jq -r '.[] |
      (.name) as $name |
      (if .is_active then "True" else "False" end) as $active |
      (.properties.core.account // "") as $account |
      (.properties.core.project // "") as $project |
      (.properties.compute.region // "") as $region |
      "\($name):\($active):\($account):\($project):\($region)"' > "$temp_map"

    if ! select_gcloud_profile "$temp_map"; then
        rm -f "$temp_map"
        return 1
    fi
    rm -f "$temp_map"

    # The picker exported the account/project from the configuration list
    local active_account="${GCLOUD_ACCOUNT:-}"
    local active_project="${GCLOUD_PROJECT:-}"
    if [ -z "$active_project" ]; then
        active_project="(unset)"
        export GCLOUD_PROJECT="$active_project"
    fi

    local token_status
    token_status=$(_gcloud_token_status "$active_account")

    _update_prompt
    clear_terminal
    create_and_display_gcloud_table "$active_account" "$active_project" "$token_status"
    _gcloud_warn_if_expiring_soon "$token_status"
    return 0
}

_ck_gcloud_login() {
    local force_reauth=false
    if [[ "$1" == "--reauth" ]]; then
        force_reauth=true
    fi

    # Check if jq is installed
    if ! command -v jq > /dev/null 2>&1; then
        printf "%sError: jq is required to parse gcloud response. Please install jq.%s\n" "${RED}" "${NC}"
        return 1
    fi

    # Check if gcloud cli is installed
    if ! command -v gcloud > /dev/null 2>&1; then
        printf "%sError: gcloud CLI is required. Please install it.%s\n" "${RED}" "${NC}"
        return 1
    fi

    # Build configuration list for selection
    local temp_map
    temp_map=$(mktemp)

    gcloud config configurations list --format=json 2>/dev/null | jq -r '.[] |
      (.name) as $name |
      (if .is_active then "True" else "False" end) as $active |
      (.properties.core.account // "") as $account |
      (.properties.core.project // "") as $project |
      (.properties.compute.region // "") as $region |
      "\($name):\($active):\($account):\($project):\($region)"' > "$temp_map"

    if ! select_gcloud_profile "$temp_map"; then
        rm -f "$temp_map"
        return 1
    fi
    rm -f "$temp_map"

    local active_account
    local active_project
    local credentials_valid=false

    # The picker exported the account/project from the configuration list
    active_account="${GCLOUD_ACCOUNT:-}"
    active_project="${GCLOUD_PROJECT:-}"

    if [ -n "$active_account" ] && [ "$active_account" != "(unset)" ] && [ "$force_reauth" = false ]; then
        # Fails when the account has no credentials or needs reauthentication
        if gcloud auth print-access-token > /dev/null 2>&1; then
            credentials_valid=true
            printf "%sGCloud credentials are valid%s\n" "${GREEN}" "${NC}"
        fi
    fi

    if [ "$credentials_valid" = false ]; then
        if [ "$force_reauth" = true ]; then
            printf "%s%s%s\n" "${BOLD_GREEN}" "GCloud reauthentication requested. Initiating login..." "${NC}"
        else
            printf "%s%s%s\n" "${BOLD_GREEN}" "GCloud credentials expired or not available. Initiating login..." "${NC}"
        fi
        gcloud auth login
        active_account=$(gcloud config get-value account 2>/dev/null)
        active_project=$(gcloud config get-value project 2>/dev/null)
    fi

    if [ -z "$active_account" ] || [ "$active_account" = "(unset)" ]; then
        printf "%sFailed to authenticate with gcloud%s\n" "${RED}" "${NC}"
        return 1
    fi

    if [ -z "$active_project" ] || [ "$active_project" = "(unset)" ]; then
        active_project="(unset)"
    fi

    printf "%sSuccessfully authenticated with account: %s%s\n" "${GREEN}" "${BOLD}" "${active_account}${NC}"

    export GCLOUD_ACCOUNT="$active_account"
    export GCLOUD_PROJECT="$active_project"

    local token_status
    token_status=$(_gcloud_token_status "$active_account")

    clear_terminal
    create_and_display_gcloud_table "$active_account" "$active_project" "$token_status"
    _update_prompt
    _gcloud_warn_if_expiring_soon "$token_status"
}

# Shells started while the earlier "ck-none" configuration was in use
if [ "${CLOUDSDK_ACTIVE_CONFIG_NAME:-}" = "ck-none" ]; then
    unset CLOUDSDK_ACTIVE_CONFIG_NAME
fi

# New terminals start without a gcloud account, the way they start without
# AWS_PROFILE. Set CLOUDKIT_GCLOUD_GLOBAL=1 to keep gcloud's global active
# configuration instead. A configuration chosen in a parent shell
# (CLOUDSDK_ACTIVE_CONFIG_NAME already set) is kept.
if [ -z "${CLOUDKIT_GCLOUD_GLOBAL:-}" ] && [ -z "${CLOUDSDK_ACTIVE_CONFIG_NAME:-}" ]; then
    _ck_gcloud_start_unselected
fi
