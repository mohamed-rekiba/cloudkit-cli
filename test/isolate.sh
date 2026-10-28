# shellcheck shell=bash
# Sourced by the test files: start from a shell without CloudKit loaded.
# A terminal where `ck` is loaded or logged in exports session variables (an
# empty CLOUDSDK_CORE_ACCOUNT, AWS_PROFILE, GCLOUD_*, …) and may set CloudKit
# options; inherited, they change what the code under test sees.
unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_REGION AWS_DEFAULT_REGION AWS_ACCOUNT_ID \
  GCLOUD_ACTIVE_CONFIG GCLOUD_ACCOUNT GCLOUD_PROJECT GCLOUD_REGION \
  CLOUDSDK_ACTIVE_CONFIG_NAME CLOUDSDK_CORE_ACCOUNT \
  CLOUDKIT_DIR CLOUDKIT_HOME CLOUDKIT_GCLOUD_GLOBAL CLOUDKIT_NO_CLEAR CLOUDKIT_NO_PROMPT \
  CLOUDKIT_PROD_PATTERN CLOUDKIT_REPO_URL CLOUDKIT_ARCHIVE_URL CLOUDKIT_RELEASES_API
