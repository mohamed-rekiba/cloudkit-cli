#!/usr/bin/env bash
# Smoke tests for AWS CLI helpers. No AWS credentials required.
# Run from repo root: bash test/run.sh

# Resolve repo root first (before set -e) so we can cd reliably
_run_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$_run_sh_dir/.." && pwd)"

set -e
cd "$REPO_ROOT" || { echo "Could not cd to REPO_ROOT=$REPO_ROOT" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }

# Test 1: Sourcing main.sh does not fail
echo "=== Test 1: Sourcing main.sh does not fail ==="
( unset AWS_PROFILE; source "$REPO_ROOT/main.sh" ) || fail "Sourcing main.sh failed"
echo "Sourcing main.sh: OK"

# Test 2: ec2 with no args prints usage and returns non-zero
echo ""
echo "=== Test 2: ec2 with no args prints usage and returns non-zero ==="
ec2_out=$( ( source "$REPO_ROOT/main.sh"; ec2 ) 2>&1 ) || true
echo "$ec2_out" | grep -q "Usage: ec2" || fail "ec2 did not print usage"
( source "$REPO_ROOT/main.sh"; ec2 ) 2>/dev/null && fail "ec2 should exit non-zero" || true
echo "ec2 usage output: OK"

# Test 3: ecs with no args prints usage and returns non-zero
echo ""
echo "=== Test 3: ecs with no args prints usage and returns non-zero ==="
ecs_out=$( ( source "$REPO_ROOT/main.sh"; ecs ) 2>&1 ) || true
echo "$ecs_out" | grep -q "Usage: ecs" || fail "ecs did not print usage"
( source "$REPO_ROOT/main.sh"; ecs ) 2>/dev/null && fail "ecs should exit non-zero" || true
echo "ecs usage output: OK"

echo ""
echo "=== All smoke tests passed ==="
