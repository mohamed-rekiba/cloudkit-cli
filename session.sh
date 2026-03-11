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

# _warn_if_expiring_soon PROFILE
#
# Reads the credential expiry time for PROFILE via aws configure export-credentials.
# Prints a colour-coded warning to stdout if expiry is within 15 minutes.
# Prints nothing and returns 0 when credentials have no expiry or are healthy.
_warn_if_expiring_soon() {
    local profile="$1"

    local expiration
    expiration=$(aws configure export-credentials --profile "$profile" 2>/dev/null \
        | jq -r '.Expiration // empty' 2>/dev/null)

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

# _update_prompt
#
# Detects the running shell and updates the interactive prompt to display
# the active AWS_PROFILE and AWS_DEFAULT_REGION.
# Saves the original prompt to $ORG_PROMPT the first time.
_update_prompt() {
    local profile="${AWS_PROFILE:-}"
    local region="${AWS_DEFAULT_REGION:-}"
    local prefix="[${profile}:${region}] "

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

# aws_logout
#
# Clears the active AWS session from the shell environment.
# Unsets all AWS_* session variables, restores the original shell prompt,
# and prints a confirmation message.
# Does NOT delete any files from ~/.aws/
aws_logout() {
    unset AWS_PROFILE
    unset AWS_DEFAULT_PROFILE
    unset AWS_REGION
    unset AWS_DEFAULT_REGION
    unset AWS_ACCOUNT_ID

    # Restore original prompt
    if [ -n "${ORG_PROMPT:-}" ]; then
        if [ -n "${ZSH_VERSION:-}" ]; then
            export PROMPT="$ORG_PROMPT"
        else
            export PS1="$ORG_PROMPT"
        fi
    fi
    unset ORG_PROMPT

    printf "%sSuccessfully logged out. AWS session cleared.%s\n" "${GREEN}" "${NC}"
    return 0
}

# aws_switch
#
# Switches to a different AWS profile within the current shell session.
# Presents the full profile list, validates credentials, and updates the prompt.
aws_switch() {
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
    local response
    if ! response=$(aws sts get-caller-identity --profile "$AWS_PROFILE" 2>&1); then
        local cred_type
        cred_type=$(_detect_credential_type "$AWS_PROFILE")
        if [ "$cred_type" = "sso" ]; then
            printf "%sInitiating SSO login for %s...%s\n" "${BOLD_GREEN}" "$AWS_PROFILE" "${NC}"
            aws sso login --profile "$AWS_PROFILE"
            if ! response=$(aws sts get-caller-identity --profile "$AWS_PROFILE" 2>&1); then
                printf "%sFailed to authenticate with profile: %s%s\n" "${RED}" "$AWS_PROFILE" "${NC}"
                return 1
            fi
        else
            printf "%sFailed to authenticate with profile: %s%s\n" "${RED}" "$AWS_PROFILE" "${NC}"
            return 1
        fi
    fi

    _update_prompt
    _warn_if_expiring_soon "$AWS_PROFILE"
    create_and_display_table "$response" "$AWS_REGION"
    return 0
}

# Clear the terminal screen
clear_terminal() {
    reset && clear
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

# Check if AWS credentials are expired.
# Returns 0 if expired, 1 if valid or no expiry information is available.
check_credentials_expiration() {
    local profile="$1"
    local expiration

    expiration=$(aws configure export-credentials --profile "$profile" 2>/dev/null \
        | jq -r '.Expiration // empty')

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
create_and_display_table() {
    local response="$1"
    local current_region="$2"

    # Extract values from JSON response (requires jq)
    local aws_account_id
    local aws_arn
    local user_id

    aws_account_id=$(echo "$response" | jq -r '.Account')
    aws_arn=$(echo "$response" | jq -r '.Arn')
    user_id=$(echo "$response" | jq -r '.UserId')

    local aws_profile="${AWS_PROFILE:-default}"

    # Format account ID as XXXX-XXXX-XXXX
    local formatted_account_id="${aws_account_id:0:4}-${aws_account_id:4:4}-${aws_account_id:8:4}"

    # Print header
    printf "\n%s━━━ AWS Session Information ━━━%s\n\n" "${BOLD_GREEN}" "${NC}"

    # Build table data, pipe through column -t, then colorize with sed
    {
        printf "Info|Value\n"
        printf "────────────|────────────────────────────────────────────────────────\n"
        printf "Account|%s\n" "$formatted_account_id"
        printf "Profile|%s\n" "$aws_profile"
        printf "Region|%s\n" "$current_region"
        printf "Identity ARN|%s\n" "$aws_arn"
        printf "User ID|%s\n" "$user_id"
    } | column -t -s '|' | sed \
        -e "1s/.*/${BOLD}&${NC}/" \
        -e "s/\(Account[[:space:]]*\)\(.*\)/\1${RED}\2${NC}/" \
        -e "s/\(Profile[[:space:]]*\)\(.*\)/\1${BLUE}\2${NC}/" \
        -e "s/\(Region[[:space:]]*\)\(.*\)/\1${CYAN}\2${NC}/" \
        -e "s/\(Identity ARN[[:space:]]*\)\(.*\)/\1${RED}\2${NC}/" \
        -e "s/\(User ID[[:space:]]*\)\(.*\)/\1${GREEN}\2${NC}/"

    printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n" "${BOLD_GREEN}" "${NC}"
}

create_and_display_gcloud_table() {
    local account="$1"
    local project="$2"

    printf "\n%s━━━ GCloud Session Information ━━━%s\n\n" "${BOLD_GREEN}" "${NC}"

    {
        printf "Info|Value\n"
        printf "────────────|────────────────────────────────────────────────────────\n"
        printf "Account|%s\n" "$account"
        printf "Project|%s\n" "$project"
    } | column -t -s '|' | sed \
        -e "1s/.*/${BOLD}&${NC}/" \
        -e "s/\(Account[[:space:]]*\)\(.*\)/\1${RED}\2${NC}/" \
        -e "s/\(Project[[:space:]]*\)\(.*\)/\1${BLUE}\2${NC}/"

    printf "\n%s━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%s\n\n" "${BOLD_GREEN}" "${NC}"
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
        export AWS_REGION="$region"
        export AWS_DEFAULT_REGION="$region"
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
    export AWS_REGION="$region"
    export AWS_DEFAULT_REGION="$region"
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

    printf "\n%sAvailable GCloud Configurations:%s\n\n" "${BOLD_GREEN}" "${NC}"

    {
        printf "#|Config|Active|Account|Project\n"
        printf "─|───────────────────────────|────────|────────────────────────────|────────────────────────────\n"

        local line_num=1
        while IFS=':' read -r name active account project; do
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

    local name active account project
    IFS=':' read -r name active account project <<< "$choice_line"

    if ! gcloud config configurations activate "$name" > /dev/null 2>&1; then
        printf "%sFailed to activate configuration: %s%s\n" "${RED}" "$name" "${NC}"
        return 1
    fi

    printf "%sSelected configuration: %s%s\n" "${GREEN}" "${BOLD}" "$name" "${NC}"
}

aws_session() {
    # Check if jq is installed
    if ! command -v jq > /dev/null 2>&1; then
        printf "%sError: jq is required to parse AWS response. Please install jq.%s\n" "${RED}" "${NC}"
        exit 1
    fi

    # Check if aws cli is installed
    if ! command -v aws > /dev/null 2>&1; then
        printf "%sError: AWS CLI is required. Please install it.%s\n" "${RED}" "${NC}"
        exit 1
    fi

    # Check if config file exists
    if [ ! -f "$HOME/.aws/config" ]; then
        printf "%sError: ~/.aws/config not found%s\n" "${RED}" "${NC}"
        return 1
    fi

    # Build the account ID to profile mapping
    local temp_map
    temp_map=$(mktemp)
    trap 'rm -f "$temp_map"' EXIT

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
        return 1
    fi

    # Check if already authenticated and not expired
    local response
    local credentials_valid=false

    if response=$(aws sts get-caller-identity --profile "$AWS_PROFILE" 2>&1); then
        # Credentials exist, check if they're expired
        if check_credentials_expiration "$AWS_PROFILE"; then
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
        if ! response=$(aws sts get-caller-identity --profile "$AWS_PROFILE" 2>&1); then
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
            if ! response=$(aws sts get-caller-identity --profile "$AWS_PROFILE" 2>&1); then
                printf "%sFailed to get identity for chained profile: %s%s\n" "${RED}" "$AWS_PROFILE" "${NC}"
                printf "%sFalling back to base profile: %s%s\n" "${CYAN}" "$selected_base_profile" "${NC}"
                export AWS_PROFILE="$selected_base_profile"
                export AWS_DEFAULT_PROFILE="$selected_base_profile"
                response=$(aws sts get-caller-identity --profile "$AWS_PROFILE" 2>&1)
            fi

            # Update AWS_ACCOUNT_ID from the new identity
            local new_account_id
            new_account_id=$(echo "$response" | jq -r '.Account // empty')
            if [ -n "$new_account_id" ]; then
                export AWS_ACCOUNT_ID="$new_account_id"
            fi
        fi
    fi

    rm -f "$chained_file"

    clear_terminal
    create_and_display_table "$response" "$AWS_REGION"
    _update_prompt
    _warn_if_expiring_soon "$AWS_PROFILE"

    # Save original PROMPT if not already saved
    if [ -z "$ORG_PROMPT" ]; then
        export ORG_PROMPT="$(echo "$PROMPT" | sed '/./,$!d')"
    fi
    export PROMPT="%F{cyan}[${AWS_PROFILE}:${AWS_DEFAULT_REGION}]%f ${ORG_PROMPT}"

}

gcloud_session() {
    local force_reauth=false
    if [[ "$1" == "--reauth" ]]; then
        force_reauth=true
    fi

    # Check if jq is installed
    if ! command -v jq > /dev/null 2>&1; then
        printf "%sError: jq is required to parse gcloud response. Please install jq.%s\n" "${RED}" "${NC}"
        exit 1
    fi

    # Check if gcloud cli is installed
    if ! command -v gcloud > /dev/null 2>&1; then
        printf "%sError: gcloud CLI is required. Please install it.%s\n" "${RED}" "${NC}"
        exit 1
    fi

    # Build configuration list for selection
    local temp_map=$(mktemp)
    trap "rm -f $temp_map" EXIT

    gcloud config configurations list --format=json 2>/dev/null | jq -r '.[] |
      (.name) as $name |
      (if .is_active then "True" else "False" end) as $active |
      (.properties.core.account // "") as $account |
      (.properties.core.project // "") as $project |
      "\($name):\($active):\($account):\($project)"' > "$temp_map"

    select_gcloud_profile "$temp_map"
    if [ $? -ne 0 ]; then
        return 1
    fi

    local active_account
    local active_project
    local credentials_valid=false

    active_account=$(gcloud config get-value account 2>/dev/null)
    active_project=$(gcloud config get-value project 2>/dev/null)

    if [ -n "$active_account" ] && [ "$active_account" != "(unset)" ] && [ "$force_reauth" = false ]; then
        local active_count
        active_count=$(gcloud auth list --format=json 2>/dev/null | jq '[.[] | select(.status=="ACTIVE")] | length' 2>/dev/null)
        if [ "$active_count" -gt 0 ]; then
            local access_token
            access_token=$(gcloud auth print-access-token 2>/dev/null)
            if [ -n "$access_token" ]; then
                credentials_valid=true
                printf "%sGCloud credentials are valid%s\n" "${GREEN}" "${NC}"
            fi
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
    clear_terminal
    create_and_display_gcloud_table "$active_account" "$active_project"

    export PROMPT="%F{green}${LOGNAME}@gcloud:${active_account}:${active_project}%f %F{blue}%~%f
> "
}