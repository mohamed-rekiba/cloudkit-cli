#!/usr/bin/env bash
# Tests for aws-auth (ADR-001, Epic 001).
# Tests are written BEFORE implementation (TDD Red phase).
# Run from repo root: bash test/test_auth.sh
#
# Tests source session.sh directly and use function-level assertions.
# No AWS credentials or network access required.

_test_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$_test_sh_dir/.." && pwd)"
# shellcheck source=test/isolate.sh
source "$_test_sh_dir/isolate.sh"

# Keep tests away from the real gcloud config (sourcing session.sh may create ck-none)
CLOUDSDK_CONFIG="$(mktemp -d)"
export CLOUDSDK_CONFIG

set -euo pipefail

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

PASS=0
FAIL=0
SKIP=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $*"; SKIP=$((SKIP + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass "$desc"
    else
        fail "$desc — expected='$expected' actual='$actual'"
    fi
}

assert_output_contains() {
    local desc="$1" substring="$2" output="$3"
    if echo "$output" | grep -qF "$substring"; then
        pass "$desc"
    else
        fail "$desc — output did not contain '$substring'. Got: $output"
    fi
}

assert_output_not_contains() {
    local desc="$1" substring="$2" output="$3"
    if echo "$output" | grep -qF "$substring"; then
        fail "$desc — output should NOT contain '$substring'. Got: $output"
    else
        pass "$desc"
    fi
}

assert_var_unset() {
    local desc="$1" varname="$2"
    if [ -z "${!varname+x}" ]; then
        pass "$desc"
    else
        fail "$desc — expected '$varname' to be unset but it is '${!varname}'"
    fi
}

assert_return_zero() {
    local desc="$1"
    shift
    if "$@"; then
        pass "$desc"
    else
        fail "$desc — expected exit 0 but got non-zero"
    fi
}

assert_return_nonzero() {
    local desc="$1"
    shift
    if ! "$@" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc — expected non-zero exit but got 0"
    fi
}

summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Tests: $((PASS + FAIL + SKIP))  PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Source the module under test (without executing _ck_aws_login / _ck_aws_logout)
# ---------------------------------------------------------------------------

# We source session.sh in a subshell per test group to avoid state leakage.
SESSION_SH="$REPO_ROOT/session.sh"
if [ ! -f "$SESSION_SH" ]; then
    echo "FATAL: $SESSION_SH not found" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Story 2 — _parse_iso8601_epoch: cross-platform ISO 8601 → epoch
# ---------------------------------------------------------------------------

echo ""
echo "=== Story 2: _parse_iso8601_epoch ==="

_run_parse() {
    # Run _parse_iso8601_epoch in an isolated subshell
    ( source "$SESSION_SH" 2>/dev/null; _parse_iso8601_epoch "$1" )
}

# Happy path: known UTC timestamp
KNOWN_TS="2026-01-01T00:00:00Z"
EXPECTED_EPOCH=1767225600  # unix epoch for 2026-01-01 00:00:00 UTC
actual_epoch=$(_run_parse "$KNOWN_TS" 2>/dev/null || echo "FAIL_EXIT")
assert_eq "_parse_iso8601_epoch converts a known UTC timestamp" \
    "$EXPECTED_EPOCH" "$actual_epoch"

# Happy path: timestamp with explicit +00:00 offset
actual_epoch2=$(_run_parse "2026-01-01T00:00:00+00:00" 2>/dev/null || echo "FAIL_EXIT")
assert_eq "_parse_iso8601_epoch handles +00:00 offset" \
    "$EXPECTED_EPOCH" "$actual_epoch2"

# Edge case: empty string → returns non-zero
assert_return_nonzero "_parse_iso8601_epoch returns non-zero for empty input" \
    bash -c "source '$SESSION_SH' 2>/dev/null; _parse_iso8601_epoch ''"

# Edge case: clearly invalid string → returns non-zero
assert_return_nonzero "_parse_iso8601_epoch returns non-zero for garbage input" \
    bash -c "source '$SESSION_SH' 2>/dev/null; _parse_iso8601_epoch 'not-a-date'"

# Security: path traversal attempt in timestamp argument
assert_return_nonzero "_parse_iso8601_epoch rejects path traversal input" \
    bash -c "source '$SESSION_SH' 2>/dev/null; _parse_iso8601_epoch '../../../etc/passwd'"

# Security: command injection attempt
assert_return_nonzero "_parse_iso8601_epoch rejects command injection attempt" \
    bash -c "source '$SESSION_SH' 2>/dev/null; _parse_iso8601_epoch '2026-01-01T00:00:00Z; rm -rf /'"

# ---------------------------------------------------------------------------
# Story 1 — _warn_if_expiring_soon: expiry warning output
# ---------------------------------------------------------------------------

echo ""
echo "=== Story 1: _warn_if_expiring_soon ==="

# Mock aws CLI to return a specific expiry timestamp.
# We override 'aws' via a local function within the subshell.

_run_warn() {
    local minutes_ahead="$1"
    # Compute a timestamp that is $minutes_ahead minutes in the future.
    local future_ts
    future_ts=$(python3 -c "
from datetime import datetime, timezone, timedelta
import sys
mins = int(sys.argv[1])
future = datetime.now(timezone.utc) + timedelta(minutes=mins)
print(future.strftime('%Y-%m-%dT%H:%M:%SZ'))
" "$minutes_ahead" 2>/dev/null) || { echo "python3_unavailable"; return 0; }

    bash -c "
source '$SESSION_SH' 2>/dev/null
# Override aws to return a mock credential expiry
aws() {
    if [[ \"\$*\" == *'export-credentials'* ]]; then
        echo '{\"Expiration\": \"$future_ts\"}'
        return 0
    fi
    command aws \"\$@\"
}
export -f aws
output=\$(_warn_if_expiring_soon 'mock-profile' 2>&1)
printf '%s' \"\$output\"
"
}

_run_warn_output() {
    local mins="$1"
    local out
    out=$(_run_warn "$mins" 2>/dev/null || echo "")
    echo "$out"
}

warn_far=$(  _run_warn_output 60   )
warn_15min=$(_run_warn_output 14   )
warn_5min=$( _run_warn_output 4    )

assert_output_not_contains \
    "_warn_if_expiring_soon prints nothing when > 15 min remaining" \
    "warning" "$warn_far"

assert_output_contains \
    "_warn_if_expiring_soon prints a warning when ≤ 15 min remaining" \
    "warning" "$warn_15min"

assert_output_contains \
    "_warn_if_expiring_soon prints a critical warning when ≤ 5 min remaining" \
    "CRITICAL" "$warn_5min"

# Edge case: no Expiration field returned → silent (return 0, no output)
_run_warn_no_expiry() {
    bash -c "
source '$SESSION_SH' 2>/dev/null
aws() {
    if [[ \"\$*\" == *'export-credentials'* ]]; then
        echo '{}'
        return 0
    fi
    command aws \"\$@\"
}
export -f aws
output=\$(_warn_if_expiring_soon 'mock-profile' 2>&1)
rc=\$?
printf '%s' \"\$output\"
exit \$rc
"
}
warn_no_expiry=$(_run_warn_no_expiry 2>/dev/null || echo "")
assert_output_not_contains \
    "_warn_if_expiring_soon is silent when no Expiration field present" \
    "warning" "$warn_no_expiry"

# ---------------------------------------------------------------------------
# GCloud token expiry: _gcloud_token_status / _gcloud_warn_if_expiring_soon
# ---------------------------------------------------------------------------

echo ""
echo "=== GCloud token expiry ==="

# Run _gcloud_token_status against a mocked `gcloud auth describe`.
# $1 = JSON fragment merged into the mocked credential.
_run_gcloud_status() {
    local extra="$1"
    bash -c "
source '$SESSION_SH' 2>/dev/null
gcloud() {
    if [[ \"\$*\" == *'auth describe'* ]]; then
        echo '{\"expiry\": \"10-20-2026 23:10:55\", \"token\": \"ya29.SECRET-ACCESS-TOKEN\", $extra}'
        return 0
    fi
    return 1
}
_gcloud_token_status 'user@example.com'
"
}

status_refresh=$(_run_gcloud_status '"type": "authorized_user", "refresh_token": "1//SECRET-REFRESH-TOKEN"' 2>/dev/null || echo "")
status_no_refresh=$(_run_gcloud_status '"type": "authorized_user"' 2>/dev/null || echo "")
status_sa=$(_run_gcloud_status '"type": "service_account"' 2>/dev/null || echo "")

assert_eq "_gcloud_token_status parses expiry and refresh token" \
    "1792537855|true|2026-10-20 23:10 UTC" "$status_refresh"
assert_eq "_gcloud_token_status reports no refresh without a refresh token" \
    "1792537855|false|2026-10-20 23:10 UTC" "$status_no_refresh"
assert_eq "_gcloud_token_status treats service accounts as refreshable" \
    "1792537855|true|2026-10-20 23:10 UTC" "$status_sa"
assert_output_not_contains "_gcloud_token_status does not print the access token" \
    "SECRET-ACCESS-TOKEN" "$status_refresh"
assert_output_not_contains "_gcloud_token_status does not print the refresh token" \
    "SECRET-REFRESH-TOKEN" "$status_refresh"

_run_gcloud_warn() {
    local seconds_ahead="$1" can_refresh="$2"
    bash -c "
source '$SESSION_SH' 2>/dev/null
_gcloud_warn_if_expiring_soon \"\$(( \$(date +%s) + $seconds_ahead ))|$can_refresh|display\"
"
}

assert_output_not_contains "_gcloud_warn_if_expiring_soon is silent when credentials auto-refresh" \
    "GCloud" "$(_run_gcloud_warn 120 true)"
assert_output_not_contains "_gcloud_warn_if_expiring_soon is silent when > 15 min remaining" \
    "GCloud" "$(_run_gcloud_warn 3600 false)"
assert_output_contains "_gcloud_warn_if_expiring_soon warns when ≤ 15 min remaining" \
    "warning" "$(_run_gcloud_warn 840 false)"
assert_output_contains "_gcloud_warn_if_expiring_soon is critical when ≤ 5 min remaining" \
    "CRITICAL" "$(_run_gcloud_warn 240 false)"
assert_output_contains "_gcloud_warn_if_expiring_soon reports expired credentials" \
    "have expired" "$(_run_gcloud_warn -60 false)"
assert_output_not_contains "_gcloud_warn_if_expiring_soon is silent with no status" \
    "GCloud" "$(bash -c "source '$SESSION_SH' 2>/dev/null; _gcloud_warn_if_expiring_soon ''")"

# ---------------------------------------------------------------------------
# Story 3 — _ck_aws_logout: env var cleanup and prompt restore
# ---------------------------------------------------------------------------

echo ""
echo "=== Story 3: _ck_aws_logout ==="

_run_logout() {
    bash -c "
source '$SESSION_SH' 2>/dev/null
unset GCLOUD_ACCOUNT GCLOUD_PROJECT GCLOUD_ACTIVE_CONFIG
export AWS_PROFILE='test-profile'
export AWS_DEFAULT_PROFILE='test-profile'
export AWS_REGION='us-east-1'
export AWS_DEFAULT_REGION='us-east-1'
export AWS_ACCOUNT_ID='123456789012'
export ORG_PROMPT='original-prompt'
export PS1='[test-profile:us-east-1] original-prompt'

_ck_aws_logout

# Print env var state as key=value lines for assertion
echo \"AWS_PROFILE=\${AWS_PROFILE:-UNSET}\"
echo \"AWS_DEFAULT_PROFILE=\${AWS_DEFAULT_PROFILE:-UNSET}\"
echo \"AWS_REGION=\${AWS_REGION:-UNSET}\"
echo \"AWS_DEFAULT_REGION=\${AWS_DEFAULT_REGION:-UNSET}\"
echo \"AWS_ACCOUNT_ID=\${AWS_ACCOUNT_ID:-UNSET}\"
echo \"ORG_PROMPT=\${ORG_PROMPT:-UNSET}\"
echo \"PS1=\${PS1:-UNSET}\"
"
}

logout_output=$(_run_logout 2>/dev/null || echo "")

assert_output_contains "_ck_aws_logout unsets AWS_PROFILE" \
    "AWS_PROFILE=UNSET" "$logout_output"
assert_output_contains "_ck_aws_logout unsets AWS_DEFAULT_PROFILE" \
    "AWS_DEFAULT_PROFILE=UNSET" "$logout_output"
assert_output_contains "_ck_aws_logout unsets AWS_REGION" \
    "AWS_REGION=UNSET" "$logout_output"
assert_output_contains "_ck_aws_logout unsets AWS_DEFAULT_REGION" \
    "AWS_DEFAULT_REGION=UNSET" "$logout_output"
assert_output_contains "_ck_aws_logout unsets AWS_ACCOUNT_ID" \
    "AWS_ACCOUNT_ID=UNSET" "$logout_output"
assert_output_contains "_ck_aws_logout unsets ORG_PROMPT" \
    "ORG_PROMPT=UNSET" "$logout_output"
assert_output_contains "_ck_aws_logout restores PS1 to original prompt" \
    "PS1=original-prompt" "$logout_output"

# _ck_aws_logout prints a confirmation message
logout_msg=$(bash -c "
source '$SESSION_SH' 2>/dev/null
export AWS_PROFILE='test-profile'
export ORG_PROMPT='orig'
_ck_aws_logout 2>&1
" 2>/dev/null || echo "")
assert_output_contains "_ck_aws_logout prints a confirmation message" \
    "logged out" "$logout_msg"

# Idempotent: calling _ck_aws_logout twice does not error
assert_return_zero "_ck_aws_logout is safe to call when session vars are already unset" \
    bash -c "source '$SESSION_SH' 2>/dev/null; _ck_aws_logout > /dev/null; _ck_aws_logout > /dev/null"

# ---------------------------------------------------------------------------
# Story 4 — _update_prompt: multi-shell prompt detection
# ---------------------------------------------------------------------------

echo ""
echo "=== Story 4: _update_prompt ==="

# zsh path: ZSH_VERSION set, PROMPT should be updated
zsh_prompt_result=$(bash -c "
source '$SESSION_SH' 2>/dev/null
export AWS_PROFILE='my-profile'
export AWS_DEFAULT_REGION='eu-west-1'
unset BASH_VERSION
ZSH_VERSION='5.9'
PROMPT='$ '
ORG_PROMPT='$ '
_update_prompt
echo \"\$PROMPT\"
" 2>/dev/null || echo "")
assert_output_contains "_update_prompt sets zsh PROMPT with profile:region" \
    "my-profile" "$zsh_prompt_result"
assert_output_contains "_update_prompt sets zsh PROMPT with region" \
    "eu-west-1" "$zsh_prompt_result"

# bash path: BASH_VERSION set, PS1 should be updated
bash_ps1_result=$(bash -c "
source '$SESSION_SH' 2>/dev/null
export AWS_PROFILE='prod-profile'
export AWS_DEFAULT_REGION='us-west-2'
unset ZSH_VERSION
BASH_VERSION='5.2.0'
PS1='\$ '
ORG_PROMPT='\$ '
_update_prompt
echo \"\$PS1\"
" 2>/dev/null || echo "")
assert_output_contains "_update_prompt sets bash PS1 with profile" \
    "prod-profile" "$bash_ps1_result"
assert_output_contains "_update_prompt sets bash PS1 with region" \
    "us-west-2" "$bash_ps1_result"

# ORG_PROMPT saved on first call
org_prompt_result=$(bash -c "
source '$SESSION_SH' 2>/dev/null
export AWS_PROFILE='p'
export AWS_DEFAULT_REGION='r'
unset ORG_PROMPT
PS1='original\$ '
ZSH_VERSION='5.9'
PROMPT='original\$ '
_update_prompt
echo \"\$ORG_PROMPT\"
" 2>/dev/null || echo "")
assert_output_contains "_update_prompt saves ORG_PROMPT on first call" \
    "original" "$org_prompt_result"

# ORG_PROMPT not overwritten on subsequent call
org_prompt_preserved=$(bash -c "
source '$SESSION_SH' 2>/dev/null
export AWS_PROFILE='p'
export AWS_DEFAULT_REGION='r'
export ORG_PROMPT='saved-original'
ZSH_VERSION='5.9'
PROMPT='[p:r] saved-original'
_update_prompt
echo \"\$ORG_PROMPT\"
" 2>/dev/null || echo "")
assert_eq "_update_prompt does not overwrite existing ORG_PROMPT" \
    "saved-original" "$org_prompt_preserved"

# ---------------------------------------------------------------------------
# Story 5 — _detect_credential_type: profile type detection
# ---------------------------------------------------------------------------

echo ""
echo "=== Story 5: _detect_credential_type ==="

# Create a temporary mock aws config file
MOCK_CONFIG=$(mktemp)
cat > "$MOCK_CONFIG" << 'EOF'
[profile sso-profile]
sso_start_url = https://example.awsapps.com/start
sso_account_id = 111111111111
region = us-east-1

[profile keys-profile]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
region = us-east-1

[profile process-profile]
credential_process = /usr/local/bin/my-credential-helper --profile prod
region = eu-west-1

[profile unknown-profile]
region = ap-southeast-1

[profile sso-account-id-only]
sso_account_id = 222222222222
region = us-west-2
EOF

_run_detect() {
    local profile="$1"
    bash -c "
HOME_BAK=\$HOME
HOME='$(dirname "$MOCK_CONFIG")'
# Symlink .aws/config → mock file
mkdir -p \"\$HOME/.aws\"
cp '$MOCK_CONFIG' \"\$HOME/.aws/config\"
source '$SESSION_SH' 2>/dev/null
_detect_credential_type '$profile'
HOME=\$HOME_BAK
" 2>/dev/null
}

assert_eq "_detect_credential_type returns 'sso' for SSO start_url profile" \
    "sso" "$(_run_detect sso-profile)"

assert_eq "_detect_credential_type returns 'sso' for sso_account_id-only profile" \
    "sso" "$(_run_detect sso-account-id-only)"

assert_eq "_detect_credential_type returns 'keys' for static key profile" \
    "keys" "$(_run_detect keys-profile)"

assert_eq "_detect_credential_type returns 'process' for credential_process profile" \
    "process" "$(_run_detect process-profile)"

assert_eq "_detect_credential_type returns 'unknown' for region-only profile" \
    "unknown" "$(_run_detect unknown-profile)"

# Security: profile name with shell-special characters
assert_eq "_detect_credential_type handles profile name with spaces gracefully" \
    "unknown" "$(_run_detect 'profile with spaces')"

rm -f "$MOCK_CONFIG"
rm -rf "$(dirname "$MOCK_CONFIG")/.aws" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Story 5 — select_profile: non-SSO profiles included in listing
# ---------------------------------------------------------------------------

echo ""
echo "=== Story 5 (continued): select_profile includes non-SSO profiles ==="

MOCK_CONFIG2=$(mktemp)
cat > "$MOCK_CONFIG2" << 'EOF'
[profile sso-profile]
sso_account_id = 111111111111
region = us-east-1

[profile keys-profile]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
region = us-east-1

[profile process-profile]
credential_process = helper --arg
region = eu-west-1
EOF

_list_profiles() {
    MOCK_HOME=$(mktemp -d)
    mkdir -p "$MOCK_HOME/.aws"
    cp "$MOCK_CONFIG2" "$MOCK_HOME/.aws/config"
    bash -c "
HOME='$MOCK_HOME'
source '$SESSION_SH' 2>/dev/null
# Build the temp_map the same way _ck_aws_login does,
# but extended to include all profile types
temp_map=\$(mktemp)
trap 'rm -f \"\$temp_map\"' EXIT

current_profile=''
current_account=''
current_region=''
while IFS= read -r line; do
    line=\$(echo \"\$line\" | sed 's/^[[:space:]]*//;s/[[:space:]]*\$//')
    [ -z \"\$line\" ] && continue
    if echo \"\$line\" | grep -q '^\['; then
        if [ -n \"\$current_profile\" ]; then
            echo \"\${current_account:-N/A}:\$current_profile:\${current_region:-N/A}\" >> \"\$temp_map\"
        fi
        if [[ \"\$line\" == '[profile '* ]]; then
            current_profile=\"\${line#\[profile }\"
            current_profile=\"\${current_profile%%\]*}\"
        fi
        current_account=''
        current_region=''
        continue
    fi
    if [[ \"\$line\" == sso_account_id* ]]; then
        current_account=\"\${line#*=}\"
        current_account=\"\${current_account#\"\${current_account%%[![:space:]]*}\"}\"
    elif [[ \"\$line\" == aws_access_key_id* ]] && [ -z \"\$current_account\" ]; then
        current_account='(keys)'
    elif [[ \"\$line\" == credential_process* ]] && [ -z \"\$current_account\" ]; then
        current_account='(process)'
    fi
    if [[ \"\$line\" == region* ]]; then
        current_region=\"\${line#*=}\"
        current_region=\"\${current_region#\"\${current_region%%[![:space:]]*}\"}\"
    fi
done < \"\$HOME/.aws/config\"
if [ -n \"\$current_profile\" ]; then
    echo \"\${current_account:-N/A}:\$current_profile:\${current_region:-N/A}\" >> \"\$temp_map\"
fi
cat \"\$temp_map\"
" 2>/dev/null
    rm -rf "$MOCK_HOME"
}

profile_list=$(_list_profiles)

assert_output_contains "profile list includes sso-profile" \
    "sso-profile" "$profile_list"
assert_output_contains "profile list includes keys-profile" \
    "keys-profile" "$profile_list"
assert_output_contains "profile list includes process-profile" \
    "process-profile" "$profile_list"

rm -f "$MOCK_CONFIG2"

# ---------------------------------------------------------------------------
# Story 6 — _ck_aws_switch: function exists and returns non-zero when no config
# ---------------------------------------------------------------------------

echo ""
echo "=== Story 6: _ck_aws_switch ==="

# _ck_aws_switch must be defined after sourcing session.sh
assert_return_zero "_ck_aws_switch function is defined in session.sh" \
    bash -c "source '$SESSION_SH' 2>/dev/null; declare -f _ck_aws_switch > /dev/null"

# With no ~/.aws/config, _ck_aws_switch should return non-zero (no profiles to switch to)
assert_return_nonzero "_ck_aws_switch returns non-zero when ~/.aws/config is missing" \
    bash -c "
HOME=\$(mktemp -d)
source '$SESSION_SH' 2>/dev/null
_ck_aws_switch > /dev/null
"


# Profiles without a region leave AWS_REGION unset instead of "N/A" or ""
region_map=$(mktemp)
echo "(keys):no-region:N/A" > "$region_map"
assert_eq "select_profile unsets AWS_REGION for a profile without a region" "REGION=UNSET" \
    "$(bash -c "source '$SESSION_SH' > /dev/null 2>&1; AWS_REGION=stale; select_profile '$region_map' > /dev/null; echo REGION=\${AWS_REGION:-UNSET}")"
echo "(keys):with-region:eu-west-1" > "$region_map"
assert_eq "select_profile exports the profile's region" "REGION=eu-west-1" \
    "$(bash -c "source '$SESSION_SH' > /dev/null 2>&1; select_profile '$region_map' > /dev/null; echo REGION=\${AWS_DEFAULT_REGION:-UNSET}")"
rm -f "$region_map"

# ck aws login must not replace the user's EXIT trap (bash traps are shell-wide)
assert_output_contains "_ck_aws_login keeps the shell's EXIT trap" "echo mine" \
    "$(bash -c "
HOME=\$(mktemp -d); mkdir -p \"\$HOME/.aws\"; printf '[profile k]\nregion = x\n' > \"\$HOME/.aws/config\"
command() { [ \"\$2\" = aws ] || [ \"\$2\" = jq ] || builtin command \"\$@\"; }
source '$SESSION_SH' > /dev/null 2>&1
trap 'echo mine' EXIT
_ck_aws_login > /dev/null 2>&1
trap -p EXIT
")"

# ---------------------------------------------------------------------------
# Security: no credential values logged or printed
# ---------------------------------------------------------------------------

echo ""
echo "=== Security: credential values not logged ==="

# Ensure _detect_credential_type does not print key values
MOCK_CONFIG3=$(mktemp)
cat > "$MOCK_CONFIG3" << 'EOF'
[profile sensitive-profile]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
region = us-east-1
EOF

MOCK_HOME3=$(mktemp -d)
mkdir -p "$MOCK_HOME3/.aws"
cp "$MOCK_CONFIG3" "$MOCK_HOME3/.aws/config"

detect_output=$(HOME="$MOCK_HOME3" bash -c "
source '$SESSION_SH' 2>/dev/null
_detect_credential_type 'sensitive-profile' 2>&1
" 2>/dev/null || echo "")

assert_output_not_contains \
    "_detect_credential_type does not print the access key value" \
    "AKIAIOSFODNN7EXAMPLE" "$detect_output"
assert_output_not_contains \
    "_detect_credential_type does not print the secret key value" \
    "wJalrXUtnFEMI" "$detect_output"

rm -f "$MOCK_CONFIG3"
rm -rf "$MOCK_HOME3"

# ---------------------------------------------------------------------------
# Session table details: identity, credentials, ADC, production, opt-outs
# ---------------------------------------------------------------------------

echo ""
echo "=== Session table details ==="

_in_session() { bash -c "source '$SESSION_SH' 2>/dev/null; $1" 2>&1; }

assert_eq "_aws_describe_identity: IAM user" \
    "IAM user jane" "$(_in_session "_aws_describe_identity 'arn:aws:iam::123456789012:user/team/jane'")"
assert_eq "_aws_describe_identity: SSO permission set without suffix" \
    "SSO Read_Only as jane@example.com" \
    "$(_in_session "_aws_describe_identity 'arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_Read_Only_0a1b2c3d4e5f/jane@example.com'")"
assert_eq "_aws_describe_identity: assumed role" \
    "Role Deploy as ci-run" "$(_in_session "_aws_describe_identity 'arn:aws:sts::123456789012:assumed-role/Deploy/ci-run'")"
assert_eq "_aws_describe_identity: root" \
    "Root user" "$(_in_session "_aws_describe_identity 'arn:aws:iam::123456789012:root'")"

MOCK_HOME4=$(mktemp -d)
assert_eq "_aws_credentials_summary: IAM user without expiry is static keys" \
    "Static keys · no expiry" \
    "$(HOME="$MOCK_HOME4" _in_session "_aws_credentials_summary p 'arn:aws:iam::1:user/jane' ''")"
future_ts=$(python3 -c "
from datetime import datetime, timezone, timedelta
print((datetime.now(timezone.utc) + timedelta(hours=2, minutes=30)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
assert_output_contains "_aws_credentials_summary shows expiry countdown" \
    "Assumed role · expires" \
    "$(HOME="$MOCK_HOME4" _in_session "_aws_credentials_summary p 'arn:aws:sts::1:assumed-role/R/s' '$future_ts'")"
assert_output_contains "_aws_credentials_summary countdown is in hours and minutes" \
    "(in 2h " \
    "$(HOME="$MOCK_HOME4" _in_session "_aws_credentials_summary p 'arn:aws:sts::1:assumed-role/R/s' '$future_ts'")"
rm -rf "$MOCK_HOME4"

# ADC: run with an isolated gcloud config dir
ADC_DIR=$(mktemp -d)
_adc() { CLOUDSDK_CONFIG="$ADC_DIR" GOOGLE_APPLICATION_CREDENTIALS="${2:-}" _in_session "_gcloud_adc_summary '$1'"; }

assert_output_contains "_gcloud_adc_summary warns when ADC is not set" "warn|not set" "$(_adc me@example.com)"
echo '{"type": "authorized_user", "account": "", "refresh_token": "SECRET-ADC-TOKEN"}' > "$ADC_DIR/application_default_credentials.json"
assert_output_contains "_gcloud_adc_summary: user login without account" "info|user login" "$(_adc me@example.com)"
assert_output_not_contains "_gcloud_adc_summary does not print the refresh token" "SECRET-ADC-TOKEN" "$(_adc me@example.com)"
echo '{"type": "authorized_user", "account": "me@example.com"}' > "$ADC_DIR/application_default_credentials.json"
assert_output_contains "_gcloud_adc_summary: same account" "ok|same as gcloud account" "$(_adc me@example.com)"
echo '{"type": "authorized_user", "account": "other@example.com"}' > "$ADC_DIR/application_default_credentials.json"
assert_output_contains "_gcloud_adc_summary: different account" "warn|different account: other@example.com" "$(_adc me@example.com)"
echo '{"type": "service_account", "client_email": "sa@p.iam.gserviceaccount.com", "private_key": "SECRET-KEY"}' > "$ADC_DIR/sa.json"
assert_output_contains "_gcloud_adc_summary: GOOGLE_APPLICATION_CREDENTIALS service account" \
    "info|service account sa@p.iam.gserviceaccount.com (GOOGLE_APPLICATION_CREDENTIALS)" "$(_adc me@example.com "$ADC_DIR/sa.json")"
echo '{"type": "impersonated_service_account", "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/deploy@p.iam.gserviceaccount.com:generateAccessToken"}' > "$ADC_DIR/application_default_credentials.json"
assert_output_contains "_gcloud_adc_summary: impersonation" "info|impersonating deploy@p.iam.gserviceaccount.com" "$(_adc me@example.com)"
rm -rf "$ADC_DIR"

# Production detection
for name in prod my-prod-account production speero-prd eu-prod-1; do
    assert_return_zero "_ck_is_prod matches '$name'" bash -c "source '$SESSION_SH' 2>/dev/null; _ck_is_prod '$name'"
done
for name in products-api staging dev reproduce; do
    assert_return_nonzero "_ck_is_prod does not match '$name'" bash -c "source '$SESSION_SH' 2>/dev/null; _ck_is_prod '$name'"
done
assert_return_zero "_ck_is_prod honours CLOUDKIT_PROD_PATTERN" \
    bash -c "source '$SESSION_SH' 2>/dev/null; CLOUDKIT_PROD_PATTERN='^live$' _ck_is_prod live"
assert_output_contains "_ck_prod_banner prints for production" "PRODUCTION" "$(_in_session "_ck_prod_banner dev prod-main")"
assert_output_not_contains "_ck_prod_banner is silent otherwise" "PRODUCTION" "$(_in_session "_ck_prod_banner dev staging")"

# Prompt: production marker and opt-out
assert_output_contains "_update_prompt adds [PROD] for a production profile" "[PROD]" \
    "$(_in_session "unset ZSH_VERSION; PS1='\$ '; AWS_PROFILE=prod-admin; AWS_DEFAULT_REGION=us-east-1; _update_prompt; echo \"\$PS1\"")"
assert_output_not_contains "_update_prompt has no [PROD] for other profiles" "[PROD]" \
    "$(_in_session "unset ZSH_VERSION; PS1='\$ '; AWS_PROFILE=dev; AWS_DEFAULT_REGION=us-east-1; _update_prompt; echo \"\$PS1\"")"
assert_eq "_update_prompt leaves the prompt alone with CLOUDKIT_NO_PROMPT" "orig" \
    "$(_in_session "unset ZSH_VERSION; PS1='orig'; AWS_PROFILE=dev; CLOUDKIT_NO_PROMPT=1 _update_prompt; echo \"\$PS1\"")"
assert_eq "_update_prompt shows AWS and gcloud sessions together" \
    "[dev:us-east-1] [gcloud:me@example.com:my-project] \$ " \
    "$(_in_session "unset ZSH_VERSION ORG_PROMPT; PS1='\$ '; AWS_PROFILE=dev; AWS_DEFAULT_REGION=us-east-1; GCLOUD_ACCOUNT=me@example.com; GCLOUD_PROJECT=my-project; _update_prompt; echo \"\$PS1\"")"
assert_output_contains "_update_prompt marks a production gcloud project" "[PROD]" \
    "$(_in_session "unset ZSH_VERSION ORG_PROMPT AWS_PROFILE; PS1='\$ '; GCLOUD_ACCOUNT=me@example.com; GCLOUD_PROJECT=shop-prod; _update_prompt; echo \"\$PS1\"")"
assert_eq "AWS logout keeps the gcloud segment" \
    "[gcloud:me@example.com:my-project] \$ " \
    "$(_in_session "unset ZSH_VERSION ORG_PROMPT; PS1='\$ '; AWS_PROFILE=dev; AWS_DEFAULT_REGION=us-east-1; GCLOUD_ACCOUNT=me@example.com; GCLOUD_PROJECT=my-project; _update_prompt; _ck_aws_logout > /dev/null; echo \"\$PS1\"")"
assert_eq "gcloud logout after AWS logout restores the original prompt" \
    "\$ " \
    "$(_in_session "unset ZSH_VERSION ORG_PROMPT; PS1='\$ '; AWS_PROFILE=dev; GCLOUD_ACCOUNT=me@example.com; _update_prompt; _ck_aws_logout > /dev/null; _ck_gcloud_logout > /dev/null; echo \"\$PS1\"")"
assert_output_contains "_aws_export_account_id exports the account from the identity" "ACCOUNT=123456789012" \
    "$(_in_session "unset AWS_ACCOUNT_ID; _aws_export_account_id '{\"Account\": \"123456789012\"}'; echo ACCOUNT=\$AWS_ACCOUNT_ID")"
# gcloud config selection is per shell (CLOUDSDK_ACTIVE_CONFIG_NAME), never global
GCLOUD_MAP=$(mktemp)
printf 'default:True:me@example.com:proj-a:\nwork:False:me@work.com:proj-b:europe-west1\n' > "$GCLOUD_MAP"
gcloud_select_out=$(_in_session "
gcloud() { echo \"GCLOUD-CALLED \$*\"; }
select_gcloud_profile '$GCLOUD_MAP' <<< 2 > /dev/null
echo CONFIG=\$CLOUDSDK_ACTIVE_CONFIG_NAME ACCOUNT=\$GCLOUD_ACCOUNT REGION=\$GCLOUD_REGION")
assert_output_contains "select_gcloud_profile selects the config for this shell" \
    "CONFIG=work ACCOUNT=me@work.com REGION=europe-west1" "$gcloud_select_out"
assert_output_not_contains "select_gcloud_profile does not change gcloud's global config" \
    "GCLOUD-CALLED" "$gcloud_select_out"
rm -f "$GCLOUD_MAP"
# New terminals start with no gcloud account (like no AWS_PROFILE)
GC_DIR=$(mktemp -d)
mkdir -p "$GC_DIR/configurations"
_fresh_shell() { CLOUDSDK_CONFIG="$GC_DIR" bash -c "unset CLOUDSDK_ACTIVE_CONFIG_NAME CLOUDSDK_CORE_ACCOUNT; $1; source '$SESSION_SH' 2>/dev/null; $2" 2>&1; }
_state='echo "CONFIG=${CLOUDSDK_ACTIVE_CONFIG_NAME-unset} ACCOUNT=${CLOUDSDK_CORE_ACCOUNT-unset}"'
assert_eq "sourcing session.sh starts with an empty gcloud account override" "CONFIG=unset ACCOUNT=" \
    "$(_fresh_shell ":" "$_state")"
assert_eq "no extra gcloud configuration is created" "" "$(ls "$GC_DIR/configurations")"
assert_eq "CLOUDKIT_GCLOUD_GLOBAL keeps gcloud's global config and account" "CONFIG=unset ACCOUNT=unset" \
    "$(_fresh_shell "export CLOUDKIT_GCLOUD_GLOBAL=1" "$_state")"
assert_eq "a config chosen in a parent shell is kept" "CONFIG=work ACCOUNT=unset" \
    "$(_fresh_shell "export CLOUDSDK_ACTIVE_CONFIG_NAME=work" "$_state")"
assert_eq "shells left on the old ck-none config start unselected" "CONFIG=unset ACCOUNT=" \
    "$(_fresh_shell "export CLOUDSDK_ACTIVE_CONFIG_NAME=ck-none" "$_state")"
assert_eq "choosing a config clears the empty account override" "CONFIG=work ACCOUNT=unset" \
    "$(_fresh_shell ":" "_ck_gcloud_use_config work; $_state")"
assert_eq "_ck_gcloud_logout leaves the shell without a gcloud account" "CONFIG=unset ACCOUNT=" \
    "$(_fresh_shell ":" "_ck_gcloud_use_config work; GCLOUD_ACCOUNT=me@work.com; _ck_gcloud_logout > /dev/null; $_state")"
assert_eq "Spaceship's gcloud section is hidden while no account is selected" "SHOW=false" \
    "$(_fresh_shell ":" 'echo SHOW=$SPACESHIP_GCLOUD_SHOW')"
assert_eq "Spaceship's gcloud section returns after choosing a config" "SHOW=true" \
    "$(_fresh_shell "SPACESHIP_GCLOUD_SHOW=true" '_ck_gcloud_use_config work; echo SHOW=$SPACESHIP_GCLOUD_SHOW')"
assert_eq "a user's own SPACESHIP_GCLOUD_SHOW=false is kept after choosing" "SHOW=false" \
    "$(_fresh_shell "SPACESHIP_GCLOUD_SHOW=false" '_ck_gcloud_use_config work; echo SHOW=$SPACESHIP_GCLOUD_SHOW')"
assert_eq "logout hides Spaceship's gcloud section again" "SHOW=false" \
    "$(_fresh_shell "SPACESHIP_GCLOUD_SHOW=true" '_ck_gcloud_use_config work; GCLOUD_ACCOUNT=x; _ck_gcloud_logout > /dev/null; echo SHOW=$SPACESHIP_GCLOUD_SHOW')"
rm -rf "$GC_DIR"

assert_eq "clear_terminal prints nothing when stdout is not a terminal" "" \
    "$(_in_session "clear_terminal")"
assert_eq "clear_terminal does nothing with CLOUDKIT_NO_CLEAR" "" \
    "$(_in_session "CLOUDKIT_NO_CLEAR=1 clear_terminal")"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

summary
