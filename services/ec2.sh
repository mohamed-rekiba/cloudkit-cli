# shellcheck shell=bash
# EC2 CLI function
_ck_ec2() {
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
      if [[ "$2" == "-h" || "$2" == "--help" ]]; then
        echo "Usage: ck ec2 session [instance-id]"
        echo "Omit the instance ID to pick from running instances."
        return 1
      fi

      local instance_id="$2"
      if [[ -z "$instance_id" ]]; then
        local rows_file rc _name _az _ip
        rows_file=$(mktemp)
        # shellcheck disable=SC2016
        aws ec2 describe-instances \
          --filters Name=instance-state-name,Values=running \
          --query 'Reservations[].Instances[].[InstanceId, Tags[?Key==`Name`]|[0].Value, Placement.AvailabilityZone, PrivateIpAddress]' \
          --output text \
          | awk -F'\t' -v OFS='|' '{ if ($2 == "None") $2 = "-"; $1 = $1; print }' > "$rows_file"

        _ck_pick "Running EC2 instances" "Instance ID|Name|AZ|Private IP" "$rows_file"
        rc=$?
        rm -f "$rows_file"
        if [[ $rc -ne 0 ]]; then
          return 1
        fi
        IFS='|' read -r instance_id _name _az _ip <<< "$CK_PICKED"
      fi

      aws ssm start-session \
        --target "$instance_id"
      ;;

    run)
      if [[ $# -lt 2 ]]; then
        echo "Usage: ck ec2 run <instance-id>"
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
        echo "Usage: ck ec2 stop <instance-id>"
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
        echo "Usage: ck ec2 port-forward <remote-port> <local-port> <instance-id> [host]"
        echo ""
        echo "Examples:"
        echo "  # Forward to EC2 instance itself (e.g., web server)"
        echo "  ck ec2 port-forward 8080 8080 i-1234567890abcdef0"
        echo ""
        echo "  # Forward to remote service through EC2 (e.g., RDS)"
        echo "  ck ec2 port-forward 3306 3306 i-1234567890abcdef0 mydb.123.us-west-2.rds.amazonaws.com"
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

    *)
      cat << 'EOF'
Usage: ck ec2 <command> [options]

Commands:
  ls                        List all EC2 instances
  ls-running                List only running EC2 instances
  ls-stopped                List only stopped EC2 instances
  session [instance-id]     Start an SSM session (omit ID to pick a running instance)
  run <instance-id>         Start (run) an EC2 instance
  stop <instance-id>        Stop an EC2 instance
  port-forward <remote-port> <local-port> <instance-id> [host]
                            Forward a port to local machine
                            - Without host: forwards from EC2 instance itself
                            - With host: forwards from remote service through EC2

Examples:
  ck ec2 ls
  ck ec2 ls-running
  ck ec2 ls-stopped
  ck ec2 session
  ck ec2 session i-1234567890abcdef0
  ck ec2 run i-1234567890abcdef0
  ck ec2 stop i-1234567890abcdef0
  ck ec2 port-forward 8080 8080 i-1234567890abcdef0
  ck ec2 port-forward 3306 3306 i-1234567890abcdef0 mydb.123456789012.us-west-2.rds.amazonaws.com
EOF
      return 1
      ;;
  esac
}
