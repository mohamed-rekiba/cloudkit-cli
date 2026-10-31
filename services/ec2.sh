# shellcheck shell=bash
# Resolve services dir when sourced (BASH_SOURCE is set when sourced)
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SERVICES_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
else
  SERVICES_DIR=$(cd "$(dirname "$0")" && pwd)
fi
export SERVICES_DIR

# _ec2_tunnel [SSH_HOST]
#
# Opens a reverse SSH tunnel over SSM to the instance named by the SSH_HOST
# entry in ~/.ssh/config (default: ec2-tunnel), and reconnects with autossh
# when the connection drops. The body runs in a subshell, so `exit`, the
# exported AWS_* variables, and the INT/TERM trap do not leak into the
# caller's interactive shell.
_ec2_tunnel() (
  local host="${1:-ec2-tunnel}"

  local tool
  for tool in ssh aws autossh; do
    if ! command -v "$tool" > /dev/null 2>&1; then
      printf "%sError: %s is required. Please install it.%s\n" "${RED}" "$tool" "${NC}" >&2
      exit 1
    fi
  done

  local ssh_config
  ssh_config=$(ssh -G "$host" 2>/dev/null)

  # ssh -G prints hostname as the alias itself when ~/.ssh/config has no entry
  local instance_id
  instance_id=$(printf '%s\n' "$ssh_config" | awk '/^hostname /{print $2; exit}')
  if ! [[ "$instance_id" =~ ^m?i-[0-9a-f]+$ ]]; then
    printf "%sError: HostName for '%s' in ~/.ssh/config is not an instance ID (got '%s').%s\n" \
      "${RED}" "$host" "$instance_id" "${NC}" >&2
    exit 1
  fi

  # ssh -G prints forwards as "[bind]:port [host]:port". Only the first one is
  # shown in the banner; autossh still opens every forward in the entry.
  local forward
  forward=$(printf '%s\n' "$ssh_config" | awk '/^remoteforward /{print $2, $3; exit}')
  if [[ -z "$forward" ]]; then
    printf "%sError: No RemoteForward found for '%s' in ~/.ssh/config.%s\n" "${RED}" "$host" "${NC}" >&2
    exit 1
  fi

  local listen local_target remote_port bind_host=""
  read -r listen local_target <<< "$(printf '%s' "$forward" | tr -d '[]')"
  remote_port="${listen##*:}"
  if [[ "$listen" == *:* ]]; then
    bind_host="${listen%:*}"
  fi

  # Use the same profile and region as the ProxyCommand, so the credential
  # check and the IP lookup hit the account that the tunnel connects to
  local proxy profile region
  proxy=$(printf '%s\n' "$ssh_config" | awk '/^proxycommand /{sub(/^proxycommand /, ""); print; exit}')
  profile=$(printf '%s' "$proxy" | sed -nE "s/.*--profile[= ]+([^ \"']+).*/\1/p")
  region=$(printf '%s' "$proxy" | sed -nE "s/.*--region[= ]+([^ \"']+).*/\1/p")
  if [[ -n "$profile" ]]; then
    export AWS_PROFILE="$profile"
    export AWS_DEFAULT_PROFILE="$profile"
  fi
  if [[ -n "$region" ]]; then
    export AWS_REGION="$region"
    export AWS_DEFAULT_REGION="$region"
  fi

  local profile_name="${AWS_PROFILE:-default}"
  local err
  if ! err=$(aws sts get-caller-identity 2>&1 > /dev/null); then
    if [[ "$(_detect_credential_type "$profile_name")" != "sso" ]]; then
      printf "%sError: AWS credentials are not valid for profile '%s':%s\n" "${RED}" "$profile_name" "${NC}" >&2
      printf "  %s\n" "$err" >&2
      printf "  Run 'aws configure list --profile %s' to check.\n" "$profile_name" >&2
      exit 1
    fi
    printf "%sAWS SSO session expired. Initiating SSO login for %s...%s\n" "${BOLD_GREEN}" "$profile_name" "${NC}"
    aws sso login --profile "$profile_name" || exit 1
    if ! aws sts get-caller-identity > /dev/null 2>&1; then
      printf "%sFailed to authenticate with profile: %s%s\n" "${RED}" "$profile_name" "${NC}" >&2
      exit 1
    fi
  fi

  local public_ip private_ip ip ip_type
  read -r public_ip private_ip <<< "$(aws ec2 describe-instances --instance-ids "$instance_id" \
    --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' \
    --output text 2>/dev/null)"

  if [[ -n "$public_ip" && "$public_ip" != "None" ]]; then
    ip="$public_ip"; ip_type="public"
  elif [[ -n "$private_ip" && "$private_ip" != "None" ]]; then
    ip="$private_ip"; ip_type="private, reachable only inside the VPC"
  else
    ip="<unknown>"; ip_type="IP lookup failed"
  fi

  printf "\n%sStarting EC2 tunnel via %s (%s, profile: %s)%s\n" \
    "${BOLD_GREEN}" "$host" "$instance_id" "$profile_name" "${NC}"
  printf "  %s%s:%s%s (%s) -> %s%s%s\n" \
    "${CYAN}" "$ip" "$remote_port" "${NC}" "$ip_type" "${BLUE}" "$local_target" "${NC}"
  if [[ -z "$bind_host" || "$bind_host" == "localhost" || "$bind_host" == "127.0.0.1" ]]; then
    printf "  %sNote: the forward binds to the instance loopback only. Other hosts cannot reach it.%s\n" \
      "${YELLOW}" "${NC}"
  fi
  printf "  %sPress Ctrl+C to close.%s\n\n" "${GRAY}" "${NC}"

  trap 'printf "\n%sTunnel closed.%s\n" "${GRAY}" "${NC}"; exit 0' INT TERM

  # Two autossh loops for one host fight for the same remote port, and each
  # one makes the other fail. Refuse to start a second loop. Debian and Ubuntu
  # run autossh as /usr/lib/autossh/autossh, so match a path prefix too.
  local running
  running=$(pgrep -f "(^|/)autossh .* ${host}\$" | tr '\n' ' ' | sed 's/ $//')
  if [[ -n "$running" ]]; then
    printf "%sError: a tunnel for '%s' is already running (autossh pid %s).%s\n" \
      "${RED}" "$host" "$running" "${NC}" >&2
    printf "  Close it with Ctrl+C in its terminal, or run: kill %s\n" "$running" >&2
    exit 1
  fi

  # A dead tunnel session can keep the remote port bound on the instance, and
  # then every new forward fails. Kill only sshd processes that listen on the
  # port. OpenSSH 9.8 and later name the session process "sshd-session".
  # This step is best effort: a failure here does not stop the tunnel.
  local cleanup_cmd
  cleanup_cmd=$(printf '%s' \
    "pids=\$(sudo -n ss -ltnpH 'sport = :${remote_port}' 2>/dev/null" \
    " | grep -oE '\"sshd(-session)?\",pid=[0-9]+' | grep -oE '[0-9]+\$' | sort -u);" \
    " if [ -n \"\$pids\" ]; then sudo -n kill \$pids && echo \"\$pids\"; fi")
  local killed
  printf "  %sChecking for old tunnel sessions on port %s...%s\n" "${GRAY}" "$remote_port" "${NC}"
  killed=$(ssh -o ClearAllForwardings=yes -o BatchMode=yes -o ConnectTimeout=20 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
    "$host" "$cleanup_cmd" 2>/dev/null) || true
  if [[ -n "$killed" ]]; then
    printf "  %sClosed old tunnel session (pid %s).%s\n" "${YELLOW}" "$(tr '\n' ' ' <<< "$killed" | sed 's/ $//')" "${NC}"
  else
    printf "  %sNo old tunnel sessions found.%s\n" "${GRAY}" "${NC}"
  fi

  # ssh -N prints nothing while the tunnel works, so say that up front.
  printf "  %sConnecting. The tunnel is up when no errors follow.%s\n\n" "${BOLD_GREEN}" "${NC}"

  # GATETIME=0 keeps autossh retrying even when the first connection fails.
  # -M 0 turns off the autossh monitor port; ServerAlive* in ~/.ssh/config
  # detects a dead connection instead.
  AUTOSSH_GATETIME=0 autossh -M 0 -N "$host"
)

# EC2 CLI function
ec2() {
  case "$1" in
    ls)
      # shellcheck disable=SC2016  # backticks are JMESPath literal syntax
      aws ec2 describe-instances \
        --query 'Reservations[].Instances[].{id: InstanceId, name: Tags[?Key==`Name`]|[0].Value, state: State.Name}' \
        | jq -r
      ;;

    ls-running)
      # shellcheck disable=SC2016
      aws ec2 describe-instances \
        --filters Name=instance-state-name,Values=running \
        --query 'Reservations[].Instances[].{id: InstanceId, name: Tags[?Key==`Name`]|[0].Value, state: State.Name}' \
        | jq -r
      ;;

    ls-stopped)
      # shellcheck disable=SC2016
      aws ec2 describe-instances \
        --filters Name=instance-state-name,Values=stopped \
        --query 'Reservations[].Instances[].{id: InstanceId, name: Tags[?Key==`Name`]|[0].Value, state: State.Name}' \
        | jq -r
      ;;

    session)
      if [[ $# -lt 2 ]]; then
        echo "Usage: ec2 session <instance-id>"
        return 1
      fi
      aws ssm start-session \
        --target "$2"
      ;;

    run)
      if [[ $# -lt 2 ]]; then
        echo "Usage: ec2 run <instance-id>"
        return 1
      fi
      echo "Starting instance $2..."
      aws ec2 start-instances \
        --instance-ids "$2" \
        --query 'StartingInstances[0].{InstanceId: InstanceId, PreviousState: PreviousState.Name, CurrentState: CurrentState.Name}' \
        --output table
      ;;

    stop)
      if [[ $# -lt 2 ]]; then
        echo "Usage: ec2 stop <instance-id>"
        return 1
      fi
      echo "Stopping instance $2..."
      aws ec2 stop-instances \
        --instance-ids "$2" \
        --query 'StoppingInstances[0].{InstanceId: InstanceId, PreviousState: PreviousState.Name, CurrentState: CurrentState.Name}' \
        --output table
      ;;

    port-forward)
      if [[ $# -lt 4 ]]; then
        echo "Usage: ec2 port-forward <remote-port> <local-port> <instance-id> [host]"
        echo ""
        echo "Examples:"
        echo "  # Forward to EC2 instance itself (e.g., web server)"
        echo "  ec2 port-forward 8080 8080 i-1234567890abcdef0"
        echo ""
        echo "  # Forward to remote service through EC2 (e.g., RDS)"
        echo "  ec2 port-forward 3306 3306 i-1234567890abcdef0 mydb.123.us-west-2.rds.amazonaws.com"
        return 1
      fi
      
      local remote_port="$2"
      local local_port="$3"
      local instance_id="$4"
      local host="$5"
      
      if [[ -z "$host" ]]; then
        # No host provided: forward to EC2 instance itself
        echo "Forwarding localhost:$local_port -> EC2 instance:$remote_port"
        aws ssm start-session \
          --document-name AWS-StartPortForwardingSession \
          --parameters "{\"portNumber\":[\"$remote_port\"], \"localPortNumber\":[\"$local_port\"]}" \
          --target "$instance_id"
      else
        # Host provided: forward to remote host through EC2
        echo "Forwarding localhost:$local_port -> $host:$remote_port (via EC2 instance)"
        aws ssm start-session \
          --document-name AWS-StartPortForwardingSessionToRemoteHost \
          --parameters "{\"host\":[\"$host\"], \"portNumber\":[\"$remote_port\"], \"localPortNumber\":[\"$local_port\"]}" \
          --target "$instance_id"
      fi
      ;;

    upload)
      if [[ $# -lt 3 ]]; then
        echo "Usage: ec2 upload <instance-id> <local-file> [remote-path] [port]"
        echo ""
        echo "Examples:"
        echo "  ec2 upload i-1234567890abcdef0 /local/file.txt /home/ec2-user/file.txt 8888"
        return 1
      fi

      local instance_id="$2"
      local file_to_send="$3"
      local remote_file_name="$4"
      local port="$5"

      "$SERVICES_DIR/_ec2_upload.sh" "$instance_id" "$file_to_send" "$remote_file_name" "$port"
      ;;

    tunnel)
      _ec2_tunnel "$2"
      ;;

    *)
      cat << 'EOF'
Usage: ec2 <command> [options]

Commands:
  ls                        List all EC2 instances
  ls-running                List only running EC2 instances
  ls-stopped                List only stopped EC2 instances
  session <instance-id>     Start an SSM session to an instance
  run <instance-id>         Start (run) an EC2 instance
  stop <instance-id>        Stop an EC2 instance
  port-forward <remote-port> <local-port> <instance-id> [host]
                            Forward a port to local machine
                            - Without host: forwards from EC2 instance itself
                            - With host: forwards from remote service through EC2
  upload <instance-id> <local-file> [remote-path] [port]
                            Upload a file to an instance via SSM
  tunnel [ssh-host]         Open a reverse SSH tunnel over SSM with autossh
                            - Reads the instance and RemoteForward from ~/.ssh/config
                            - Default ssh-host: ec2-tunnel

Examples:
  ec2 ls
  ec2 ls-running
  ec2 ls-stopped
  ec2 session i-1234567890abcdef0
  ec2 run i-1234567890abcdef0
  ec2 stop i-1234567890abcdef0
  ec2 port-forward 8080 8080 i-1234567890abcdef0
  ec2 port-forward 3306 3306 i-1234567890abcdef0 mydb.123456789012.us-west-2.rds.amazonaws.com
  ec2 upload i-1234567890abcdef0 /local/file.txt /home/ec2-user/file.txt 8888
  ec2 tunnel
  ec2 tunnel my-other-tunnel
EOF
      return 1
      ;;
  esac
}
