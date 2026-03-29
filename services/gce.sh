# shellcheck shell=bash
SERVICES_DIR=$(dirname "$0")
export SERVICES_DIR

# GCE (GCloud Compute Engine) CLI function
gce() {
  case "$1" in
    ls)
      if [[ "$2" == "--filter" && -n "$3" ]]; then
        gcloud compute instances list --filter="name~$3"
      else
        gcloud compute instances list
      fi
      ;;

    ssh)
      if [[ $# -lt 2 ]]; then
        echo "Usage: gce ssh <instance-name> [--zone <zone>] [command]"
        echo "Example: gce ssh my-vm --zone us-central1-a"
        echo "Example: gce ssh my-vm --zone us-central1-a \"ls -la\""
        return 1
      fi

      local instance="$2"
      shift 2

      local zone=""
      if [[ "$1" == "--zone" && -n "$2" ]]; then
        zone="$2"
        shift 2
      fi

      local command="${*:1}"
      local args=()
      if [[ -n "$zone" ]]; then
        args+=(--zone "$zone")
      fi

      if [[ -n "$command" ]]; then
        gcloud compute ssh "$instance" \
          "${args[@]}" \
          --command "$command"
      else
        gcloud compute ssh "$instance" \
          "${args[@]}"
      fi
      ;;

    scp)
      if [[ $# -lt 3 ]]; then
        echo "Usage: gce scp <source> <destination> [--zone <zone>]"
        echo "Example: gce scp ./file.txt my-vm:/tmp/file.txt --zone us-central1-a"
        echo "Example: gce scp my-vm:/var/log/syslog ./syslog --zone us-central1-a"
        return 1
      fi

      local source="$2"
      local destination="$3"
      shift 3

      local zone=""
      if [[ "$1" == "--zone" && -n "$2" ]]; then
        zone="$2"
        shift 2
      fi

      local args=()
      if [[ -n "$zone" ]]; then
        args+=(--zone "$zone")
      fi

      gcloud compute scp \
        "${args[@]}" \
        "$source" "$destination"
      ;;

    *)
      cat << 'EOF'
Usage: gce <command> [options]

Commands:
  ls [--filter <pattern>]
                          List GCE instances (optional name filter)
  ssh <instance-name> [--zone <zone>] [command]
                          SSH to a GCE VM (optional command)
  scp <source> <destination> [--zone <zone>]
                          Copy files to/from a GCE VM

Examples:
  gce ls
  gce ls --filter laravel-staging
  gce ssh my-vm --zone us-central1-a
  gce ssh my-vm --zone us-central1-a "ls -la"
  gce scp ./file.txt my-vm:/tmp/file.txt --zone us-central1-a
  gce scp my-vm:/var/log/syslog ./syslog --zone us-central1-a
EOF
      return 1
      ;;
  esac
}
