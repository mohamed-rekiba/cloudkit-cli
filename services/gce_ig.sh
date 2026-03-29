# shellcheck shell=bash
SERVICES_DIR=$(dirname "$0")
export SERVICES_DIR

# GCE Managed Instance Groups (MIG) helper
gce-ig() {
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
        echo "Usage: gce-ig describe <group-name> --region <region>"
        echo "Example: gce-ig describe laravel-production-mig --region us-central1"
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
        echo "Usage: gce-ig recreate <group-name> --region <region>"
        echo "Example: gce-ig recreate laravel-production-mig --region us-central1"
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
        echo "Usage: gce-ig restart <group-name> --region <region>"
        echo "Example: gce-ig restart laravel-production-mig --region us-central1"
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
Usage: gce-ig <command> [options]

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
  gce-ig ls
  gce-ig ls --region us-central1
  gce-ig describe laravel-production-mig --region us-central1
  gce-ig recreate laravel-production-mig --region us-central1
  gce-ig restart laravel-production-mig --region us-central1
EOF
      return 1
      ;;
  esac
}
