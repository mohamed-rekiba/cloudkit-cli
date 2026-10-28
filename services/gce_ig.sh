# shellcheck shell=bash
# GCE Managed Instance Groups (MIG) helper
_ck_mig() {
  case "$1" in
    list)
      if [[ "$2" == "--region" && -n "$3" ]]; then
        gcloud compute instance-groups managed list --regions "$3"
      else
        gcloud compute instance-groups managed list
      fi
      ;;

    describe)
      if [[ $# -lt 2 ]]; then
        echo "Usage: ck mig describe <group-name> --region <region>"
        echo "Example: ck mig describe laravel-production-mig --region us-central1"
        return 1
      fi

      local group="$2"
      shift 2

      local region=""
      if [[ "$1" == "--region" && -n "$2" ]]; then
        region="$2"
        shift 2
      fi

      if [[ -z "$region" ]]; then
        echo "Error: --region is required"
        return 1
      fi

      gcloud compute instance-groups managed describe "$group" \
        --region "$region"
      ;;

    recreate)
      if [[ $# -lt 2 ]]; then
        echo "Usage: ck mig recreate <group-name> --region <region>"
        echo "Example: ck mig recreate laravel-production-mig --region us-central1"
        return 1
      fi

      local group="$2"
      shift 2

      local region=""
      if [[ "$1" == "--region" && -n "$2" ]]; then
        region="$2"
        shift 2
      fi

      if [[ -z "$region" ]]; then
        echo "Error: --region is required"
        return 1
      fi

      gcloud compute instance-groups managed rolling-action replace "$group" \
        --region "$region"
      ;;

    restart)
      if [[ $# -lt 2 ]]; then
        echo "Usage: ck mig restart <group-name> --region <region>"
        echo "Example: ck mig restart laravel-production-mig --region us-central1"
        return 1
      fi

      local group="$2"
      shift 2

      local region=""
      if [[ "$1" == "--region" && -n "$2" ]]; then
        region="$2"
        shift 2
      fi

      if [[ -z "$region" ]]; then
        echo "Error: --region is required"
        return 1
      fi

      gcloud compute instance-groups managed rolling-action restart "$group" \
        --region "$region"
      ;;

    *)
      cat << 'EOF'
Usage: ck mig <command> [options]

Commands:
  list [--region <region>]
                          List managed instance groups
  describe <group> --region <region>
                          Describe a managed instance group
  recreate <group> --region <region>
                          Replace instances in a managed instance group
  restart <group> --region <region>
                          Restart instances in a managed instance group

Examples:
  ck mig list
  ck mig list --region us-central1
  ck mig describe laravel-production-mig --region us-central1
  ck mig recreate laravel-production-mig --region us-central1
  ck mig restart laravel-production-mig --region us-central1
EOF
      return 1
      ;;
  esac
}
