#!/usr/bin/env bash
# Tests for the ec2 service helpers.
# Run from repo root: bash test/test_ec2.sh
#
# ssh, aws, and autossh are replaced with shell functions, so no AWS
# credentials, SSH config, or network access are required.

# shellcheck disable=SC2016  # scripts passed to `bash -c` expand variables in the child shell

_test_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$_test_sh_dir/.." && pwd)"

set -euo pipefail

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

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
    if echo "$output" | grep -qF -- "$substring"; then
        pass "$desc"
    else
        fail "$desc — output did not contain '$substring'. Got: $output"
    fi
}

assert_output_not_contains() {
    local desc="$1" substring="$2" output="$3"
    if echo "$output" | grep -qF -- "$substring"; then
        fail "$desc — output should NOT contain '$substring'. Got: $output"
    else
        pass "$desc"
    fi
}

summary() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Tests: $((PASS + FAIL))  PASS: $PASS  FAIL: $FAIL"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [ "$FAIL" -gt 0 ]; then
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Mocks and fixtures
# ---------------------------------------------------------------------------

MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT
export MOCK_DIR
export MAIN_SH="$REPO_ROOT/main.sh"
export MOCKS="$MOCK_DIR/mocks.sh"

# The mocks read these variables:
#   MOCK_SSH_G       file printed by `ssh -G`
#   MOCK_STS         ok | fail | fail-until-login
#   MOCK_PUBLIC_IP   public IP returned by describe-instances ("None" if absent)
#   MOCK_PRIVATE_IP  private IP returned by describe-instances
cat > "$MOCKS" << 'EOF'
ssh() {
    if [ "$1" = "-G" ]; then
        echo "$2" >> "$MOCK_DIR/ssh_hosts"
        cat "$MOCK_SSH_G"
        return 0
    fi
    echo "unexpected ssh call: $*" >&2
    return 99
}

aws() {
    case "$*" in
        "sts get-caller-identity"*)
            case "${MOCK_STS:-ok}" in
                ok) return 0 ;;
                fail) echo "mock sts error" >&2; return 1 ;;
                fail-until-login)
                    [ -f "$MOCK_DIR/logged_in" ] && return 0
                    echo "token expired" >&2
                    return 1
                    ;;
            esac
            ;;
        "sso login"*)
            echo "SSO_LOGIN $*"
            touch "$MOCK_DIR/logged_in"
            ;;
        "ec2 describe-instances"*)
            printf '%s\t%s\n' "${MOCK_PUBLIC_IP:-54.1.2.3}" "${MOCK_PRIVATE_IP:-10.0.0.5}"
            ;;
        *)
            echo "unexpected aws call: $*" >&2
            return 99
            ;;
    esac
}

autossh() {
    echo "AUTOSSH args=[$*] gatetime=${AUTOSSH_GATETIME:-} profile=${AWS_PROFILE:-} region=${AWS_REGION:-}"
}
EOF

# ssh -G output, in the bracketed format OpenSSH prints for forwards
cat > "$MOCK_DIR/tunnel.conf" << 'EOF'
hostname i-0123456789abcdef0
user ec2-user
remoteforward [0.0.0.0]:8080 [localhost]:8080
proxycommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p' --region us-east-1 --profile my-profile"
EOF

cat > "$MOCK_DIR/loopback.conf" << 'EOF'
hostname i-0123456789abcdef0
remoteforward 9090 [localhost]:3000
proxycommand sh -c "aws ssm start-session --target %h --region us-east-1 --profile my-profile"
EOF

cat > "$MOCK_DIR/no-forward.conf" << 'EOF'
hostname i-0123456789abcdef0
proxycommand sh -c "aws ssm start-session --target %h --region us-east-1 --profile my-profile"
EOF

# ssh -G echoes the alias as hostname when ~/.ssh/config has no entry
cat > "$MOCK_DIR/unknown.conf" << 'EOF'
hostname not-configured
EOF

# HOME with an SSO profile, for _detect_credential_type
mkdir -p "$MOCK_DIR/sso-home/.aws"
cat > "$MOCK_DIR/sso-home/.aws/config" << 'EOF'
[profile my-profile]
sso_session = my-session
sso_account_id = 111111111111
region = us-east-1
EOF

# HOME with a static-key profile
mkdir -p "$MOCK_DIR/keys-home/.aws"
cat > "$MOCK_DIR/keys-home/.aws/config" << 'EOF'
[profile my-profile]
aws_access_key_id = AKIAIOSFODNN7EXAMPLE
region = us-east-1
EOF

TUNNEL='source "$MAIN_SH" 2>/dev/null; source "$MOCKS"; ec2 tunnel "$@"'

# run_tunnel SCRIPT [ARGS...]
# Runs SCRIPT in a fresh bash and sets OUT (stdout + stderr, with ANSI
# colour codes removed so assertions can match across colour changes) and RC.
run_tunnel() {
    rm -f "$MOCK_DIR/logged_in" "$MOCK_DIR/ssh_hosts"
    RC=0
    OUT=$(bash -c "$1" _ "${@:2}" 2>&1) || RC=$?
    OUT=$(printf '%s' "$OUT" | sed $'s/\033\\[[0-9;]*m//g')
}

# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------

echo ""
echo "=== ec2 tunnel: happy path ==="

MOCK_SSH_G="$MOCK_DIR/tunnel.conf" run_tunnel "$TUNNEL"

assert_eq "ec2 tunnel returns 0 when autossh exits cleanly" "0" "$RC"
assert_output_contains "banner shows the instance ID from HostName" \
    "i-0123456789abcdef0" "$OUT"
assert_output_contains "banner shows the profile from ProxyCommand" \
    "profile: my-profile" "$OUT"
assert_output_contains "banner shows public IP and remote port" \
    "54.1.2.3:8080" "$OUT"
assert_output_contains "banner shows the local target without brackets" \
    "-> localhost:8080" "$OUT"
assert_output_not_contains "no loopback note when the forward binds to 0.0.0.0" \
    "loopback" "$OUT"
assert_output_contains "autossh runs with -M 0 -N and the default host" \
    "AUTOSSH args=[-M 0 -N ec2-tunnel]" "$OUT"
assert_output_contains "autossh runs with AUTOSSH_GATETIME=0" \
    "gatetime=0" "$OUT"
assert_output_contains "AWS_PROFILE comes from the ProxyCommand --profile" \
    "profile=my-profile" "$OUT"
assert_output_contains "AWS_REGION comes from the ProxyCommand --region" \
    "region=us-east-1" "$OUT"
assert_eq "ssh -G reads the default host ec2-tunnel" \
    "ec2-tunnel" "$(cat "$MOCK_DIR/ssh_hosts")"

MOCK_SSH_G="$MOCK_DIR/tunnel.conf" run_tunnel "$TUNNEL" my-other-tunnel
assert_output_contains "a host argument overrides the default host" \
    "AUTOSSH args=[-M 0 -N my-other-tunnel]" "$OUT"

# ---------------------------------------------------------------------------
# IP lookup and forward parsing
# ---------------------------------------------------------------------------

echo ""
echo "=== ec2 tunnel: IP lookup and forward parsing ==="

MOCK_SSH_G="$MOCK_DIR/tunnel.conf" MOCK_PUBLIC_IP=None run_tunnel "$TUNNEL"
assert_output_contains "falls back to the private IP when there is no public IP" \
    "10.0.0.5:8080 (private, reachable only inside the VPC)" "$OUT"

MOCK_SSH_G="$MOCK_DIR/tunnel.conf" MOCK_PUBLIC_IP=None MOCK_PRIVATE_IP=None run_tunnel "$TUNNEL"
assert_output_contains "shows <unknown> when the IP lookup returns nothing" \
    "<unknown>:8080 (IP lookup failed)" "$OUT"
assert_eq "an IP lookup failure does not stop the tunnel" "0" "$RC"

MOCK_SSH_G="$MOCK_DIR/loopback.conf" run_tunnel "$TUNNEL"
assert_output_contains "a port-only RemoteForward gives the remote port" \
    "54.1.2.3:9090" "$OUT"
assert_output_contains "a port-only RemoteForward gives the local target" \
    "-> localhost:3000" "$OUT"
assert_output_contains "a port-only RemoteForward prints the loopback note" \
    "loopback only" "$OUT"

# ---------------------------------------------------------------------------
# Config errors
# ---------------------------------------------------------------------------

echo ""
echo "=== ec2 tunnel: config errors ==="

MOCK_SSH_G="$MOCK_DIR/unknown.conf" run_tunnel "$TUNNEL" not-configured
assert_eq "returns 1 when the host is not in ~/.ssh/config" "1" "$RC"
assert_output_contains "explains that HostName is not an instance ID" \
    "is not an instance ID (got 'not-configured')" "$OUT"
assert_output_not_contains "does not start autossh for an unknown host" \
    "AUTOSSH" "$OUT"

MOCK_SSH_G="$MOCK_DIR/no-forward.conf" run_tunnel "$TUNNEL"
assert_eq "returns 1 when there is no RemoteForward" "1" "$RC"
assert_output_contains "explains that RemoteForward is missing" \
    "No RemoteForward found for 'ec2-tunnel'" "$OUT"

# command -v finds shell functions, so remove the mock and empty PATH
MOCK_SSH_G="$MOCK_DIR/tunnel.conf" run_tunnel \
    'source "$MAIN_SH" 2>/dev/null; source "$MOCKS"; unset -f autossh; PATH=/nonexistent; ec2 tunnel'
assert_eq "returns 1 when autossh is not installed" "1" "$RC"
assert_output_contains "names autossh as the missing tool" \
    "autossh is required" "$OUT"

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

echo ""
echo "=== ec2 tunnel: credentials ==="

HOME="$MOCK_DIR/keys-home" MOCK_SSH_G="$MOCK_DIR/tunnel.conf" MOCK_STS=fail run_tunnel "$TUNNEL"
assert_eq "returns 1 when non-SSO credentials are invalid" "1" "$RC"
assert_output_contains "shows the AWS error for invalid non-SSO credentials" \
    "mock sts error" "$OUT"
assert_output_not_contains "does not run SSO login for a non-SSO profile" \
    "SSO_LOGIN" "$OUT"

HOME="$MOCK_DIR/sso-home" MOCK_SSH_G="$MOCK_DIR/tunnel.conf" MOCK_STS=fail-until-login run_tunnel "$TUNNEL"
assert_eq "returns 0 after a successful SSO login" "0" "$RC"
assert_output_contains "runs SSO login for the ProxyCommand profile" \
    "SSO_LOGIN sso login --profile my-profile" "$OUT"
assert_output_contains "starts autossh after SSO login" \
    "AUTOSSH" "$OUT"

HOME="$MOCK_DIR/sso-home" MOCK_SSH_G="$MOCK_DIR/tunnel.conf" MOCK_STS=fail run_tunnel "$TUNNEL"
assert_eq "returns 1 when credentials are still invalid after SSO login" "1" "$RC"
assert_output_contains "reports the failed authentication" \
    "Failed to authenticate with profile: my-profile" "$OUT"
assert_output_not_contains "does not start autossh when authentication fails" \
    "AUTOSSH" "$OUT"

# ---------------------------------------------------------------------------
# Caller shell isolation
# ---------------------------------------------------------------------------

echo ""
echo "=== ec2 tunnel: caller shell isolation ==="

MOCK_SSH_G="$MOCK_DIR/tunnel.conf" run_tunnel '
source "$MAIN_SH" 2>/dev/null
source "$MOCKS"
export AWS_PROFILE=caller-profile
ec2 tunnel > /dev/null
echo "after_profile=$AWS_PROFILE"
echo "after_trap=[$(trap -p INT)]"
'
assert_output_contains "AWS_PROFILE in the caller shell is unchanged" \
    "after_profile=caller-profile" "$OUT"
assert_output_contains "no INT trap is left in the caller shell" \
    "after_trap=[]" "$OUT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

summary
