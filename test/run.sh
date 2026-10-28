#!/usr/bin/env bash
# Smoke tests for CloudKit CLI. No AWS/GCloud credentials required.
# Run from repo root: bash test/run.sh

# Resolve repo root first (before set -e) so we can cd reliably
_run_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$_run_sh_dir/.." && pwd)"
# shellcheck source=test/isolate.sh
source "$_run_sh_dir/isolate.sh"

# Keep tests away from the real gcloud config (sourcing session.sh may create ck-none)
CLOUDSDK_CONFIG="$(mktemp -d)"
export CLOUDSDK_CONFIG

set -e
cd "$REPO_ROOT" || { echo "Could not cd to REPO_ROOT=$REPO_ROOT" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; exit 1; }

# Test 1: Sourcing main.sh does not fail
echo "=== Test 1: Sourcing main.sh does not fail ==="
( unset AWS_PROFILE; source "$REPO_ROOT/main.sh" ) || fail "Sourcing main.sh failed"
echo "Sourcing main.sh: OK"

# Test 2: ck ec2 with no args prints usage and returns non-zero
echo ""
echo "=== Test 2: ck ec2 with no args prints usage and returns non-zero ==="
ec2_out=$( ( source "$REPO_ROOT/main.sh"; ck ec2 ) 2>&1 ) || true
echo "$ec2_out" | grep -q "Usage: ck ec2" || fail "ck ec2 did not print usage"
( source "$REPO_ROOT/main.sh"; ck ec2 ) 2>/dev/null && fail "ck ec2 should exit non-zero" || true
echo "ck ec2 usage output: OK"

# Test 3: ck ecs with no args prints usage and returns non-zero
echo ""
echo "=== Test 3: ck ecs with no args prints usage and returns non-zero ==="
ecs_out=$( ( source "$REPO_ROOT/main.sh"; ck ecs ) 2>&1 ) || true
echo "$ecs_out" | grep -q "Usage: ck ecs" || fail "ck ecs did not print usage"
( source "$REPO_ROOT/main.sh"; ck ecs ) 2>/dev/null && fail "ck ecs should exit non-zero" || true
echo "ck ecs usage output: OK"

# Test 4: ck gce with no args prints usage and returns non-zero
echo ""
echo "=== Test 4: ck gce with no args prints usage and returns non-zero ==="
gce_out=$( ( source "$REPO_ROOT/main.sh"; ck gce ) 2>&1 ) || true
echo "$gce_out" | grep -q "Usage: ck gce" || fail "ck gce did not print usage"
( source "$REPO_ROOT/main.sh"; ck gce ) 2>/dev/null && fail "ck gce should exit non-zero" || true
echo "ck gce usage output: OK"

# Test 5: instance pickers (stub gcloud/aws on PATH)
echo ""
echo "=== Test 5: gce ssh / ec2 session instance pickers ==="
stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT
cat > "$stub_dir/gcloud" << 'STUB'
#!/usr/bin/env bash
if [[ "$*" == *"status=RUNNING"* ]]; then
  printf 'web-1\tus-central1-a\t10.0.0.2\nweb-2\tus-central1-b\t10.0.0.3\n' | head -n "${N:-2}"
  exit
fi
echo "gcloud $*"
STUB
cat > "$stub_dir/aws" << 'STUB'
#!/usr/bin/env bash
if [[ "$1" == ec2 ]]; then
  printf 'i-aaa\tweb\tus-east-1a\t10.0.0.1\ni-bbb\tNone\tus-east-1b\t10.0.0.2\n' | head -n "${N:-2}"
  exit
fi
echo "aws $*"
STUB
chmod +x "$stub_dir/gcloud" "$stub_dir/aws"

pick() { ( PATH="$stub_dir:$PATH"; source "$REPO_ROOT/main.sh"; "$@" ) 2>&1; }

out=$(echo 2 | pick ck gce ssh)
echo "$out" | grep -q "gcloud compute ssh web-2 --zone us-central1-b" || fail "gce ssh picker did not select web-2: $out"
out=$(N=1 pick ck gce ssh)
echo "$out" | grep -q "gcloud compute ssh web-1 --zone us-central1-a" || fail "gce ssh did not auto-select single instance: $out"
N=0 pick ck gce ssh > /dev/null && fail "gce ssh should fail with no running instances"
echo 9 | pick ck gce ssh > /dev/null && fail "gce ssh should fail on invalid selection"
out=$(echo 2 | pick ck ec2 session)
echo "$out" | grep -q "aws ssm start-session --target i-bbb" || fail "ec2 session picker did not select i-bbb: $out"
N=0 pick ck ec2 session > /dev/null && fail "ec2 session should fail with no running instances"
echo "instance pickers: OK"

# Test 6: ck dispatcher
echo ""
echo "=== Test 6: ck dispatcher ==="
empty_gcloud_dir=$(mktemp -d)
ck_run() { ( unset AWS_PROFILE GCLOUD_ACCOUNT CLOUDSDK_ACTIVE_CONFIG_NAME; export CLOUDSDK_CONFIG="$empty_gcloud_dir"; source "$REPO_ROOT/main.sh"; "$@" ) 2>&1; }

ck_run ck | grep -q "Usage: ck <command>" || fail "ck did not print help"
ck_run ck > /dev/null && fail "ck with no args should exit non-zero"
ck_run ck help > /dev/null || fail "ck help should exit zero"
ck_run ck help gce | grep -q "Usage: ck gce" || fail "ck help gce did not print gce usage"
ck_run ck help mig | grep -q "Usage: ck mig" || fail "ck help mig did not print mig usage"
ck_run ck nope | grep -q "Unknown command: nope" || fail "ck did not report unknown command"
ck_run ck nope > /dev/null && fail "ck with an unknown command should exit non-zero"
ck_run ck aws | grep -q "Usage: ck aws" || fail "ck aws did not print aws usage"
ck_run ck gcloud | grep -q "Usage: ck gcloud" || fail "ck gcloud did not print gcloud usage"
ck_run ck aws sso > /dev/null && fail "ck aws sso without a profile should exit non-zero"
status_out=$(ck_run ck status)
echo "$status_out" | grep -q "not logged in (ck aws login)" || fail "ck status did not report missing AWS session"
echo "$status_out" | grep -q "not logged in (ck gcloud login)" || fail "ck status did not report missing gcloud session"
status_out=$( ( source "$REPO_ROOT/main.sh"; AWS_PROFILE=dev AWS_REGION=eu-west-1 GCLOUD_ACCOUNT=me@example.com ck status ) 2>&1 )
echo "$status_out" | grep -q "dev" || fail "ck status did not show the AWS profile"
echo "$status_out" | grep -q "me@example.com" || fail "ck status did not show the gcloud account"
mkdir -p "$empty_gcloud_dir/configurations"
echo "work" > "$empty_gcloud_dir/active_config"
printf '[core]\naccount = me@example.com\nproject = my-project\n\n[compute]\nregion = us-central1\n' > "$empty_gcloud_dir/configurations/config_work"
status_out=$(ck_run ck status)
echo "$status_out" | grep -q "not logged in (ck gcloud login)" || fail "ck status should show no gcloud session in a new shell"
status_out=$(CLOUDKIT_GCLOUD_GLOBAL=1 ck_run ck status)
echo "$status_out" | grep -q "my-project" || fail "ck status did not read gcloud's active config"
echo "$status_out" | grep -q "not started in this shell" || fail "ck status did not explain the gcloud fallback"
rm -rf "$empty_gcloud_dir"

for old in ec2 ecs gce gce-ig aws_session aws_switch aws_logout gcloud_session gcloud_switch gcloud_logout sso_login; do
  ( source "$REPO_ROOT/main.sh"; type "$old" ) > /dev/null 2>&1 && fail "legacy command '$old' should not be defined"
done
echo "ck dispatcher: OK"

# Test 7: ck ecs tasks batches describe-tasks; ck ecs logs reads the awslogs stream
echo ""
echo "=== Test 7: ck ecs tasks / logs ==="
ecs_stub=$(mktemp -d)
cat > "$ecs_stub/aws" << 'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$AWS_CALLS"
case "$*" in
  *"list-tasks"*)
    jq -n '[range(0; 230) | "arn:aws:ecs:eu-west-1:111111111111:task/my-cluster/t\(.)"]' ;;
  *"describe-tasks"*"tasks[0]"*)
    echo '{"taskArn":"arn:aws:ecs:eu-west-1:111111111111:task/my-cluster/abc123","taskDefinitionArn":"arn:td/app:7","containers":[{"name":"app"}]}' ;;
  *"describe-tasks"*)
    args="$*"; tasks=${args#*--tasks }; tasks=${tasks%% --output*}
    echo "$tasks" | jq '{tasks: [.[] | {taskArn: ., lastStatus: "RUNNING", desiredStatus: "RUNNING", createdAt: "2026-01-01T00:00:00.000000+00:00", containers: [{name: "app"}]}]}' ;;
  *"describe-task-definition"*)
    if [ -n "${NO_AWSLOGS:-}" ]; then echo '[{"name":"app","logConfiguration":{"logDriver":"awsfirelens"}}]'
    else echo '[{"name":"app","logConfiguration":{"logDriver":"awslogs","options":{"awslogs-group":"/ecs/app","awslogs-stream-prefix":"ecs","awslogs-region":"eu-west-1"}}}]'; fi ;;
  *"get-log-events"*)
    echo '{"events":[{"message":"line one"},{"message":"line two"}]}' ;;
esac
STUB
chmod +x "$ecs_stub/aws"
export AWS_CALLS="$ecs_stub/calls"
ecs_run() { ( PATH="$ecs_stub:$PATH"; source "$REPO_ROOT/main.sh"; "$@" ) 2>&1; }

: > "$AWS_CALLS"
out=$(ecs_run ck ecs tasks my-cluster)
[ "$(grep -c "describe-tasks" "$AWS_CALLS")" -eq 3 ] || fail "ck ecs tasks should call describe-tasks 3 times for 230 tasks"
[ "$(echo "$out" | grep -c "RUNNING")" -eq 230 ] || fail "ck ecs tasks did not list all 230 tasks"

: > "$AWS_CALLS"
out=$(ecs_run ck ecs logs my-cluster abc123 --tail 20)
grep -q "logs get-log-events --region eu-west-1 --log-group-name /ecs/app --log-stream-name ecs/app/abc123 --limit 20" "$AWS_CALLS" \
  || fail "ck ecs logs did not read the awslogs stream: $(cat "$AWS_CALLS")"
echo "$out" | grep -q "line two" || fail "ck ecs logs did not print log lines: $out"
NO_AWSLOGS=1 ecs_run ck ecs logs my-cluster abc123 > /dev/null && fail "ck ecs logs should fail for non-awslogs drivers"
ecs_run ck ecs logs my-cluster abc123 --tail abc > /dev/null && fail "ck ecs logs should reject a non-numeric --tail"
rm -rf "$ecs_stub"
unset AWS_CALLS
echo "ck ecs tasks / logs: OK"

echo ""
echo "=== All smoke tests passed ==="
