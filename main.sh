# shellcheck shell=bash
# Resolve helpers dir when run or sourced (BASH_SOURCE is set when sourced)
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  AWS_HELPERS_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
else
  AWS_HELPERS_DIR=$(cd "$(dirname "$0")" && pwd)
fi
export AWS_HELPERS_DIR

alias sso_login="aws sso login --profile"
# shellcheck source=session.sh disable=SC1090
source "$AWS_HELPERS_DIR/session.sh"
# shellcheck source=services/ec2.sh disable=SC1090
source "$AWS_HELPERS_DIR/services/ec2.sh"
# shellcheck source=services/ecs.sh disable=SC1090
source "$AWS_HELPERS_DIR/services/ecs.sh"
# shellcheck source=services/gce.sh disable=SC1090
source "$AWS_HELPERS_DIR/services/gce.sh"
# shellcheck source=services/gce_ig.sh disable=SC1090
source "$AWS_HELPERS_DIR/services/gce_ig.sh"
