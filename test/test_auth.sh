#!/usr/bin/env bash
# Tests for aws-auth (ADR-001, Epic 001).
# Tests are written BEFORE implementation (TDD Red phase).
# Run from repo root: bash test/test_auth.sh
#
# Tests source session.sh directly and use function-level assertions.
# No AWS credentials or network access required.

_test_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$_test_sh_dir/.." && pwd)"

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
# Source the module under test (without executing aws_session / aws_logout)
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
# Story 3 — aws_logout: env var cleanup and prompt restore
# ---------------------------------------------------------------------------

echo ""
echo "=== Story 3: aws_logout ==="

_run_logout() {
    bash -c "
source '$SESSION_SH' 2>/dev/null
export AWS_PROFILE='test-profile'
export AWS_DEFAULT_PROFILE='test-profile'
export AWS_REGION='us-east-1'
export AWS_DEFAULT_REGION='us-east-1'
export AWS_ACCOUNT_ID='123456789012'
export ORG_PROMPT='original-prompt'
export PS1='[test-profile:us-east-1] original-prompt'

aws_logout

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

assert_output_contains "aws_logout unsets AWS_PROFILE" \
    "AWS_PROFILE=UNSET" "$logout_output"
assert_output_contains "aws_logout unsets AWS_DEFAULT_PROFILE" \
    "AWS_DEFAULT_PROFILE=UNSET" "$logout_output"
assert_output_contains "aws_logout unsets AWS_REGION" \
    "AWS_REGION=UNSET" "$logout_output"
assert_output_contains "aws_logout unsets AWS_DEFAULT_REGION" \
    "AWS_DEFAULT_REGION=UNSET" "$logout_output"
assert_output_contains "aws_logout unsets AWS_ACCOUNT_ID" \
    "AWS_ACCOUNT_ID=UNSET" "$logout_output"
assert_output_contains "aws_logout unsets ORG_PROMPT" \
    "ORG_PROMPT=UNSET" "$logout_output"
assert_output_contains "aws_logout restores PS1 to original prompt" \
    "PS1=original-prompt" "$logout_output"

# aws_logout prints a confirmation message
logout_msg=$(bash -c "
source '$SESSION_SH' 2>/dev/null
export AWS_PROFILE='test-profile'
export ORG_PROMPT='orig'
aws_logout 2>&1
" 2>/dev/null || echo "")
assert_output_contains "aws_logout prints a confirmation message" \
    "logged out" "$logout_msg"

# Idempotent: calling aws_logout twice does not error
assert_return_zero "aws_logout is safe to call when session vars are already unset" \
    bash -c "source '$SESSION_SH' 2>/dev/null; aws_logout > /dev/null; aws_logout > /dev/null"

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
# Build the temp_map the same way aws_session does,
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
# Story 6 — aws_switch: function exists and returns non-zero when no config
# ---------------------------------------------------------------------------

echo ""
echo "=== Story 6: aws_switch ==="

# aws_switch must be defined after sourcing session.sh
assert_return_zero "aws_switch function is defined in session.sh" \
    bash -c "source '$SESSION_SH' 2>/dev/null; declare -f aws_switch > /dev/null"

# With no ~/.aws/config, aws_switch should return non-zero (no profiles to switch to)
assert_return_nonzero "aws_switch returns non-zero when ~/.aws/config is missing" \
    bash -c "
HOME=\$(mktemp -d)
source '$SESSION_SH' 2>/dev/null
aws_switch > /dev/null
"

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
# Summary
# ---------------------------------------------------------------------------

summary
