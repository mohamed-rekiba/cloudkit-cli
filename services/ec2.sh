# shellcheck shell=bash
# Resolve services dir when sourced (BASH_SOURCE is set when sourced)
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  SERVICES_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
else
  SERVICES_DIR=$(cd "$(dirname "$0")" && pwd)
fi
export SERVICES_DIR

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
EOF
      return 1
      ;;
  esac
}
