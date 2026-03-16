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

# Clear the terminal screen
clear_terminal() {
    reset && clear
}

# Get AWS credentials and account information
get_credentials() {
    local current_region="${AWS_DEFAULT_REGION:-us-east-1}"

    # Get caller identity from AWS STS
    local response
    response=$(aws sts get-caller-identity --region "$current_region" 2>&1)

    # Check if the command was successful
    if [ $? -ne 0 ]; then
        echo "AWS Credentials not available"
        return 1
    fi

    # Return the response
    echo "$response"
}

# Check if AWS credentials are expired
check_credentials_expiration() {
    local profile="$1"
    local expiration

    # Get the expiration time from AWS credentials
    expiration=$(aws configure export-credentials --profile "$profile" 2>/dev/null | jq -r '.Expiration // empty')

    # Return 1 if no expiration info (not applicable for some credential types)
    if [ -z "$expiration" ]; then
        return 1
    fi

    # Convert expiration ISO 8601 timestamp to epoch
    local expiration_epoch
    local current_epoch

    expiration_epoch=$(date -d "$expiration" +%s 2>/dev/null)
    current_epoch=$(date +%s)

    # Return 0 if expired, 1 if valid
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
            if echo "$line" | grep -q '^\[profile '; then
                current_profile=$(echo "$line" | sed 's/^\[profile \([^]]*\)\].*/\1/')
            elif echo "$line" | grep -q '^\[default\]'; then
                current_profile="default"
            fi
            current_source=""
            current_region=""
            current_role_arn=""
            continue
        fi

        # Extract source_profile
        if echo "$line" | grep -q '^source_profile'; then
            current_source=$(echo "$line" | sed 's/^source_profile[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/')
        fi

        # Extract region
        if echo "$line" | grep -q '^region'; then
            current_region=$(echo "$line" | sed 's/^region[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/')
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
    local temp_map=$(mktemp)
    trap "rm -f $temp_map" EXIT

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
            if echo "$line" | grep -q '^\[profile '; then
                current_profile=$(echo "$line" | sed 's/^\[profile \([^]]*\)\].*/\1/')
            elif echo "$line" | grep -q '^\[default\]'; then
                current_profile="default"
            fi
            current_account=""
            current_region=""
            continue
        fi

        # Extract sso_account_id
        if echo "$line" | grep -q '^sso_account_id'; then
            current_account=$(echo "$line" | sed 's/^sso_account_id[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/')
        fi

        # Extract region
        if echo "$line" | grep -q '^region'; then
            current_region=$(echo "$line" | sed 's/^region[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/')
        fi
    done < "$HOME/.aws/config"

    # Don't forget the last profile
    if [ -n "$current_account" ]; then
        echo "$current_account:$current_profile:$current_region" >> "$temp_map"
    fi

    # Ask user to select a profile
    select_profile "$temp_map"
    if [ $? -ne 0 ]; then
        return 1
    fi

    # Check if already authenticated and not expired
    local response
    local credentials_valid=false

    response=$(aws sts get-caller-identity --profile "$AWS_PROFILE" 2>&1)

    if [ $? -eq 0 ]; then
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
        response=$(aws sts get-caller-identity --profile "$AWS_PROFILE" 2>&1)
        if [ $? -ne 0 ]; then
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
            response=$(aws sts get-caller-identity --profile "$AWS_PROFILE" 2>&1)
            if [ $? -ne 0 ]; then
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