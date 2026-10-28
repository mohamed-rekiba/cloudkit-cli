#!/usr/bin/env bash
# Docs sync test: every `ck` subcommand must appear in `ck help <command>` and
# have a "## ck <command> <sub>" heading on its docs page. No network needed.
# Run from repo root: bash test/test_docs.sh

_docs_sh_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REPO_ROOT="$(cd "$_docs_sh_dir/.." && pwd)"
# shellcheck source=test/isolate.sh
source "$_docs_sh_dir/isolate.sh"

CLOUDSDK_CONFIG="$(mktemp -d)"
export CLOUDSDK_CONFIG
trap 'rm -rf "$CLOUDSDK_CONFIG"' EXIT

cd "$REPO_ROOT" || { echo "Could not cd to REPO_ROOT=$REPO_ROOT" >&2; exit 1; }

DOCS="$REPO_ROOT/website/src/content/docs"
# Alternate spellings that share a heading with their main name
ALIASES="setup:gcp"

fail() { echo "FAIL: $*" >&2; exit 1; }

# subcommands FILE FUNCTION INDENT [PARENT]
# Print the case labels at INDENT spaces inside FUNCTION (and, with PARENT,
# inside its `PARENT)` branch), one per line. Flags, `*` and help are skipped.
subcommands() {
  awk -v fn="$2" -v indent="$3" -v parent="${4:-}" '
    $0 ~ "^" fn "\\(\\) *\\{" { in_fn = 1; in_parent = (parent == ""); next }
    in_fn && /^}/ { in_fn = 0 }
    !in_fn { next }
    parent != "" && /^    [^ ][^ ]*\)/ { in_parent = ($0 ~ "^    " parent "\\)") ; next }
    in_parent && match($0, "^" sprintf("%" indent "s", "") "[a-z][a-z|-]*\\)") {
      label = substr($0, indent + 1, RLENGTH - indent - 1)
      n = split(label, parts, "|")
      for (i = 1; i <= n; i++) if (parts[i] != "help") print parts[i]
    }
  ' "$1"
}

errors=0
check() {
  local group="$1" page="$2" subs="$3" help_out sub
  [ -n "$subs" ] || fail "found no subcommands for ck $group (did the dispatcher layout change?)"
  [ -f "$page" ] || fail "missing docs page: ${page#"$REPO_ROOT"/}"
  help_out=$( ( source "$REPO_ROOT/main.sh"; ck help "$group" ) 2>&1 )
  for sub in $subs; do
    case " $ALIASES " in *" $group:$sub "*) continue ;; esac
    if ! grep -E "^## ck $group " "$page" | grep -qE "(^|[^a-z-])$sub([^a-z-]|$)"; then
      echo "  ck $group $sub: no '## ck $group $sub' heading in ${page#"$REPO_ROOT"/}" >&2
      errors=$((errors + 1))
    fi
    if ! echo "$help_out" | grep -qE "(^|[^a-z-])$sub([^a-z-]|$)"; then
      echo "  ck $group $sub: missing from 'ck help $group'" >&2
      errors=$((errors + 1))
    fi
  done
  echo "ck $group: $(echo "$subs" | wc -w | tr -d ' ') subcommands checked"
}

echo "=== Docs: every subcommand is in ck help and the docs site ==="
check aws "$DOCS/commands/aws.mdx" "$(subcommands ck.sh ck 8 aws)"
check gcloud "$DOCS/commands/gcloud.mdx" "$(subcommands ck.sh ck 8 gcloud)"
check ec2 "$DOCS/commands/ec2.mdx" "$(subcommands services/ec2.sh _ck_ec2 4)"
check ecs "$DOCS/commands/ecs.mdx" "$(subcommands services/ecs.sh _ck_ecs 4)"
check gce "$DOCS/commands/gce.mdx" "$(subcommands services/gce.sh _ck_gce 4)"
check mig "$DOCS/commands/mig.mdx" "$(subcommands services/gce_ig.sh _ck_mig 4)"
check setup "$DOCS/commands/setup.mdx" "$(subcommands services/setup.sh _ck_setup 4)"

[ "$errors" -eq 0 ] || fail "$errors docs/help gap(s) found; update ck help and website/src/content/docs/"

echo ""
echo "=== All docs tests passed ==="
