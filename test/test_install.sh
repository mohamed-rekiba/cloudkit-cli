#!/usr/bin/env bash
# Tests for install.sh, `ck setup`, and `ck doctor`. No network, no real
# AWS/GCloud calls: HOME is a temp dir and aws/gcloud are stubs on PATH.
# Run from repo root: bash test/test_install.sh

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
# shellcheck source=test/isolate.sh
source "$REPO_ROOT/test/isolate.sh"

set -e
cd "$REPO_ROOT"

fail() { echo "FAIL: $*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"
export CLOUDSDK_CONFIG="$tmp/gcloud"

mkdir -p "$HOME"

echo "=== Test 1: install.sh adds the rc block once, even when re-run ==="
echo 'alias ll=ls' > "$HOME/.bashrc"
SHELL=/bin/zsh bash install.sh --no-deps --yes < /dev/null > /dev/null
SHELL=/bin/zsh bash install.sh --no-deps --yes < /dev/null > /dev/null
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  [ "$(grep -c '# >>> cloudkit >>>' "$rc")" -eq 1 ] || fail "$rc: expected one cloudkit block"
  grep -qF "source \"$REPO_ROOT/main.sh\"" "$rc" || fail "$rc: missing source line"
done
grep -q '^alias ll=ls$' "$HOME/.bashrc" || fail "existing .bashrc content lost"
echo "install.sh rc block: OK"

echo ""
echo "=== Test 2: install.sh --uninstall removes the block and keeps the clone ==="
bash install.sh --uninstall --yes < /dev/null > /dev/null
grep -q 'cloudkit' "$HOME/.zshrc" "$HOME/.bashrc" && fail "cloudkit block not removed"
[ "$(cat "$HOME/.bashrc")" = 'alias ll=ls' ] || fail ".bashrc changed by uninstall"
[ -f "$REPO_ROOT/main.sh" ] || fail "uninstall deleted the clone"
echo "install.sh --uninstall: OK"

echo ""
echo "=== Test 3: ck help lists setup and doctor ==="
help_out=$( ( source "$REPO_ROOT/main.sh"; ck help ) 2>&1 )
echo "$help_out" | grep -q "setup \[aws|gcloud\]" || fail "ck help missing setup"
echo "$help_out" | grep -q "doctor" || fail "ck help missing doctor"
( source "$REPO_ROOT/main.sh"; ck setup bogus ) > /dev/null 2>&1 && fail "ck setup bogus should exit non-zero"
echo "ck help: OK"

# Stubs: aws/gcloud log their arguments
stub_dir="$tmp/bin"
mkdir -p "$stub_dir"
cat > "$stub_dir/aws" << 'STUB'
#!/usr/bin/env bash
echo "aws $*" >> "$STUB_LOG"
case "$*" in
  --version) echo "aws-cli/2.17.0 Python/3.11 Linux/6 exe/x86_64" ;;
  "configure list-profiles") echo "base-sso" ;;
  "configure get region --profile base-sso") echo "eu-west-1" ;;
esac
STUB
cat > "$stub_dir/gcloud" << 'STUB'
#!/usr/bin/env bash
echo "gcloud $* [config=${CLOUDSDK_ACTIVE_CONFIG_NAME:-}] [account=${CLOUDSDK_CORE_ACCOUNT-unset}]" >> "$STUB_LOG"
case "$*" in
  --version) echo "Google Cloud SDK 500.0.0" ;;
esac
STUB
for tool in session-manager-plugin jq python3; do
  printf '#!/usr/bin/env bash\necho "%s 1.0"\n' "$tool" > "$stub_dir/$tool"
done
chmod +x "$stub_dir"/*
export STUB_LOG="$tmp/stub.log"

echo ""
echo "=== Test 4: ck doctor passes with all required tools ==="
mkdir -p "$HOME/.aws" && touch "$HOME/.aws/config"
doctor_out=$( ( PATH="$stub_dir:$PATH"; source "$REPO_ROOT/main.sh"; ck doctor ) 2>&1 ) \
  || fail "ck doctor failed with stubs: $doctor_out"
echo "$doctor_out" | grep -q "aws-cli/2.17.0" || fail "ck doctor did not show aws version"
echo "ck doctor (all present): OK"

echo ""
echo "=== Test 5: ck doctor fails when the AWS CLI is v1 ==="
v1_dir="$tmp/v1"
mkdir -p "$v1_dir"
printf '#!/usr/bin/env bash\necho "aws-cli/1.29.0 Python/3.11"\n' > "$v1_dir/aws"
chmod +x "$v1_dir/aws"
( PATH="$v1_dir:$stub_dir:$PATH"; source "$REPO_ROOT/main.sh"; ck doctor ) > /dev/null 2>&1 \
  && fail "ck doctor should fail with AWS CLI v1"
echo "ck doctor (aws v1): OK"

echo ""
echo "=== Test 6: ck setup aws creates a chained profile ==="
: > "$STUB_LOG"
# choice 3, source profile (default), role ARN, profile name (default), region (default), no login
printf '3\n\narn:aws:iam::123456789012:role/Deploy\n\n\nn\n' \
  | ( PATH="$stub_dir:$PATH"; source "$REPO_ROOT/main.sh"; ck setup aws ) > /dev/null 2>&1 \
  || fail "ck setup aws failed"
grep -qx "aws configure set role_arn arn:aws:iam::123456789012:role/Deploy --profile Deploy" "$STUB_LOG" \
  || fail "role_arn not set: $(cat "$STUB_LOG")"
grep -qx "aws configure set source_profile base-sso --profile Deploy" "$STUB_LOG" || fail "source_profile not set"
grep -qx "aws configure set region eu-west-1 --profile Deploy" "$STUB_LOG" || fail "region not set"
printf '3\n\nnot-an-arn\n' \
  | ( PATH="$stub_dir:$PATH"; source "$REPO_ROOT/main.sh"; ck setup aws ) > /dev/null 2>&1 \
  && fail "ck setup aws should reject an invalid role ARN"
echo "ck setup aws: OK"

echo ""
echo "=== Test 7: ck setup gcloud creates and configures a configuration ==="
: > "$STUB_LOG"
# name, account, project, region, zone (default), no ADC, no session
printf 'staging\nme@example.com\nmy-proj\neurope-west1\n\nn\nn\n' \
  | ( PATH="$stub_dir:$PATH"; source "$REPO_ROOT/main.sh"; ck setup gcloud ) > /dev/null 2>&1 \
  || fail "ck setup gcloud failed: $(cat "$STUB_LOG")"
grep -q "^gcloud config configurations create staging --no-activate" "$STUB_LOG" || fail "configuration not created"
grep -qF "gcloud config set core/project my-proj [config=staging] [account=unset]" "$STUB_LOG" \
  || fail "project not set on the new configuration: $(cat "$STUB_LOG")"
grep -qF "gcloud config set compute/zone europe-west1-a [config=staging]" "$STUB_LOG" || fail "default zone not derived from region"
grep -qF "gcloud auth login me@example.com [config=staging]" "$STUB_LOG" || fail "auth login not run"
printf 'Bad_Name\n' \
  | ( PATH="$stub_dir:$PATH"; source "$REPO_ROOT/main.sh"; ck setup gcloud ) > /dev/null 2>&1 \
  && fail "ck setup gcloud should reject an invalid name"
echo "ck setup gcloud: OK"

echo ""
echo "=== Test 8: install.sh installs the latest release ==="
# Local repo with tags v1 and v2; no GitHub API (falls back to git tags)
src="$tmp/src"
git init --quiet "$src"
git -C "$src" symbolic-ref HEAD refs/heads/main
cp -R main.sh ck.sh session.sh services "$src/"
commit() { git -C "$src" -c user.name=t -c user.email=t@t commit --quiet "$@"; }
git -C "$src" add -A
commit -m one
git -C "$src" tag v1
echo "# two" >> "$src/main.sh"
commit -am two
git -C "$src" tag v2
echo "# three" >> "$src/main.sh"
commit -am three
export CLOUDKIT_REPO_URL="file://$src" CLOUDKIT_RELEASES_API=""
ck_home="$HOME/.cloudkit"
run_installer() { bash -s -- --no-deps --no-rc --yes < "$REPO_ROOT/install.sh" > /dev/null 2>&1; }

run_installer || fail "install failed"
[ "$(cat "$ck_home/.cloudkit-version")" = v2 ] || fail "should install the latest tag v2"
grep -q '# three' "$ck_home/main.sh" && fail "installed main instead of v2"
[ "$( ( CLOUDKIT_DIR="$ck_home"; source "$REPO_ROOT/ck.sh"; _ck_version ) )" = v2 ] || fail "ck version wrong"

git -C "$src" tag v3
run_installer || fail "re-install failed"
[ "$(cat "$ck_home/.cloudkit-version")" = v3 ] || fail "re-running should upgrade to v3"
grep -q '# three' "$ck_home/main.sh" || fail "v3 not checked out"

git -C "$src" tag -d v1 v2 v3 > /dev/null
rm -rf "$ck_home"
run_installer || fail "install without releases failed"
[ "$(cat "$ck_home/.cloudkit-version")" = main ] || fail "should fall back to main without releases"
unset CLOUDKIT_REPO_URL CLOUDKIT_RELEASES_API
echo "install.sh latest release: OK"

echo ""
echo "All install/setup tests passed."
