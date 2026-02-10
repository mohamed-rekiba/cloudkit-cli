# ECS CLI function
ecs() {
  case "$1" in
    clusters)
      # List all clusters
      aws ecs list-clusters \
        --query 'clusterArns[]' \
        --output text | tr '\t' '\n' | sed 's|.*cluster/||'
      ;;

    services)
      # List services in a cluster
      if [[ $# -lt 2 ]]; then
        echo "Usage: ecs services <cluster-name>"
        return 1
      fi
      aws ecs list-services \
        --cluster "$2" \
        --query 'serviceArns[]' \
        --output text | tr '\t' '\n' | sed 's|.*service/||'
      ;;

    tasks)
      # List all tasks in a cluster
      if [[ $# -lt 2 ]]; then
        echo "Usage: ecs tasks <cluster-name> [--running]"
        return 1
      fi

      local desired_status=""
      if [[ "$3" == "--running" ]]; then
        desired_status="RUNNING"
      fi

      local task_arns
      if [[ -n "$desired_status" ]]; then
        task_arns=$(aws ecs list-tasks \
          --cluster "$2" \
          --desired-status "$desired_status" \
          --query 'taskArns' \
          --output json)
      else
        task_arns=$(aws ecs list-tasks \
          --cluster "$2" \
          --query 'taskArns' \
          --output json)
      fi

      local count=$(echo "$task_arns" | jq 'length')
      if [[ $count -eq 0 ]]; then
        echo "No tasks found in cluster: $2"
        return 0
      fi

      printf "%-40s %-15s %-15s %-25s %-15s\n" "TASK ID" "LAST STATUS" "DESIRED STATUS" "CONTAINER" "UPTIME"
      printf "%s\n" "$(printf '=%.0s' {1..110})"

      # shellcheck disable=SC2086
      aws ecs describe-tasks \
        --cluster "$2" \
        --tasks $task_arns \
        --output json | jq -r '.tasks[] |
          ((.taskArn | split("/") | .[-1]) as $task_id |
           ((.createdAt | split(".")[0] | split("+")[0] | split("Z")[0] | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $created |
            (now - $created | . / 60 | floor) as $uptime_mins |
            ($uptime_mins / 60 | floor) as $hours |
            ($uptime_mins % 60) as $mins |
            ($hours / 24 | floor) as $days |
            (if $days > 0 then
               ($days | tostring) + "d " + (($hours % 24) | tostring) + "h"
             elif $hours > 0 then
               ($hours | tostring) + "h " + ($mins | tostring) + "m"
             else
               ($mins | tostring) + "m"
             end) as $uptime |
            "\($task_id) | \(.lastStatus) | \(.desiredStatus) | \(.containers[0].name) | \($uptime)"))' |
           awk -F' \\| ' '{printf "%-40s %-15s %-15s %-25s %-15s\n", $1, $2, $3, $4, $5}'
      ;;

    service-tasks)
      # List tasks for a specific service
      if [[ $# -lt 3 ]]; then
        echo "Usage: ecs service-tasks <cluster-name> <service-name> [--running]"
        return 1
      fi

      local desired_status=""
      if [[ "$4" == "--running" ]]; then
        desired_status="RUNNING"
      fi

      local task_arns
      if [[ -n "$desired_status" ]]; then
        task_arns=$(aws ecs list-tasks \
          --cluster "$2" \
          --service-name "$3" \
          --desired-status "$desired_status" \
          --query 'taskArns' \
          --output json)
      else
        task_arns=$(aws ecs list-tasks \
          --cluster "$2" \
          --service-name "$3" \
          --query 'taskArns' \
          --output json)
      fi

      local count=$(echo "$task_arns" | jq 'length')
      if [[ $count -eq 0 ]]; then
        echo "No tasks found for service: $3"
        return 0
      fi

      printf "%-40s %-15s %-15s %-25s %-15s\n" "TASK ID" "LAST STATUS" "DESIRED STATUS" "CONTAINER" "UPTIME"
      printf "%s\n" "$(printf '=%.0s' {1..110})"

      # shellcheck disable=SC2086
      aws ecs describe-tasks \
        --cluster "$2" \
        --tasks $task_arns \
        --output json | jq -r '.tasks[] |
          ((.taskArn | split("/") | .[-1]) as $task_id |
           ((.createdAt | split(".")[0] | split("+")[0] | split("Z")[0] | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $created |
            (now - $created | . / 60 | floor) as $uptime_mins |
            ($uptime_mins / 60 | floor) as $hours |
            ($uptime_mins % 60) as $mins |
            ($hours / 24 | floor) as $days |
            (if $days > 0 then
               ($days | tostring) + "d " + (($hours % 24) | tostring) + "h"
             elif $hours > 0 then
               ($hours | tostring) + "h " + ($mins | tostring) + "m"
             else
               ($mins | tostring) + "m"
             end) as $uptime |
            "\($task_id) | \(.lastStatus) | \(.desiredStatus) | \(.containers[0].name) | \($uptime)"))' |
           awk -F' \\| ' '{printf "%-40s %-15s %-15s %-25s %-15s\n", $1, $2, $3, $4, $5}'
      ;;

    task-info)
      # Get detailed info about a task
      if [[ $# -lt 3 ]]; then
        echo "Usage: ecs task-info <cluster-name> <task-id>"
        return 1
      fi
      aws ecs describe-tasks \
        --cluster "$2" \
        --tasks "$3" \
        --output json | jq -r '.tasks[0] |
          ((.createdAt | split(".")[0] | split("+")[0] | split("Z")[0] | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $created |
           (now - $created | . / 60 | floor) as $uptime_mins |
           ($uptime_mins / 60 | floor) as $hours |
           ($uptime_mins % 60) as $mins |
           ($hours / 24 | floor) as $days |
           (if $days > 0 then
              ($days | tostring) + "d " + (($hours % 24) | tostring) + "h"
            elif $hours > 0 then
              ($hours | tostring) + "h " + ($mins | tostring) + "m"
            else
              ($mins | tostring) + "m"
            end) as $uptime |
           "Task ID: \(.taskArn | split("/") | .[-1])\nLast Status: \(.lastStatus)\nDesired Status: \(.desiredStatus)\nContainer: \(.containers[0].name)\nImage: \(.containers[0].image)\nUptime: \($uptime)\nCreated At: \(.createdAt)")'
      ;;

    exec)
      # Execute command in a container
      if [[ $# -lt 4 ]]; then
        echo "Usage: ecs exec <cluster-name> <task-id> <container-name> [command]"
        echo "Example: ecs exec my-cluster abc123 my-container /bin/bash"
        echo "Example: ecs exec my-cluster abc123 my-container ls -la"
        return 1
      fi

      local cluster="$2"
      local task="$3"
      local container="$4"
      shift 4
      local command="${@:1}"

      # If no command provided, default to bash
      if [[ -z "$command" ]]; then
        command="/bin/bash"
      fi

      aws ecs execute-command \
        --cluster "$cluster" \
        --task "$task" \
        --container "$container" \
        --interactive \
        --command "$command"
      ;;

    exec-running)
      # Execute command in the first running task in a cluster
      if [[ $# -lt 3 ]]; then
        echo "Usage: ecs exec-running <cluster-name> <container-name> [--service <service-name>] [command]"
        echo "Example: ecs exec-running my-cluster my-container /bin/bash"
        echo "Example: ecs exec-running my-cluster my-container --service my-service /bin/bash"
        echo "Example: ecs exec-running my-cluster my-container --service my-service ls -la"
        return 1
      fi

      local cluster="$2"
      local container="$3"
      shift 3
      local service_name=""
      if [[ "$1" == "--service" && -n "$2" ]]; then
        service_name="$2"
        shift 2
      fi
      local command="${@:1}"

      # If no command provided, default to bash
      if [[ -z "$command" ]]; then
        command="/bin/bash"
      fi

      local task_arn
      if [[ -n "$service_name" ]]; then
        task_arn=$(aws ecs list-tasks \
          --cluster "$cluster" \
          --service-name "$service_name" \
          --desired-status RUNNING \
          --query 'taskArns[0]' \
          --output text)
      else
        task_arn=$(aws ecs list-tasks \
          --cluster "$cluster" \
          --desired-status RUNNING \
          --query 'taskArns[0]' \
          --output text)
      fi

      if [[ -z "$task_arn" || "$task_arn" == "None" ]]; then
        if [[ -n "$service_name" ]]; then
          echo "No running tasks found for service: $service_name"
        else
          echo "No running tasks found in cluster: $cluster"
        fi
        return 0
      fi

      local task_id
      task_id=$(echo "$task_arn" | sed 's|.*task/||')

      aws ecs execute-command \
        --cluster "$cluster" \
        --task "$task_id" \
        --container "$container" \
        --interactive \
        --command "$command"
      ;;

    logs)
      # Get logs from a task
      if [[ $# -lt 3 ]]; then
        echo "Usage: ecs logs <cluster-name> <task-id> [--tail N]"
        return 1
      fi

      local cluster="$2"
      local task="$3"
      local tail_lines="50"

      if [[ "$4" == "--tail" ]] && [[ -n "$5" ]]; then
        tail_lines="$5"
      fi

      # Get task details to find the log group and stream
      local task_details=$(aws ecs describe-tasks \
        --cluster "$cluster" \
        --tasks "$task" \
        --query 'tasks[0]')

      # Extract container name if not provided
      local container_name=$(echo "$task_details" | jq -r '.containers[0].name')
      local task_arn=$(echo "$task_details" | jq -r '.taskArn')
      local task_id=$(echo "$task_arn" | sed 's|.*task/||')

      # Try to get logs from CloudWatch - this is basic and may need adjustment
      echo "Task: $task_id"
      echo "Container: $container_name"
      echo "Note: Configure CloudWatch logging in your task definition to view logs here"
      ;;

    stop)
      # Stop a task
      if [[ $# -lt 3 ]]; then
        echo "Usage: ecs stop <cluster-name> <task-id> [reason]"
        return 1
      fi

      local reason="${4:-Stopped via CLI}"
      aws ecs stop-task \
        --cluster "$2" \
        --task "$3" \
        --reason "$reason" \
        --query 'task.[taskArn,lastStatus]' \
        --output table
      ;;

    describe)
      # Describe a service
      if [[ $# -lt 3 ]]; then
        echo "Usage: ecs describe <cluster-name> <service-name>"
        return 1
      fi
      aws ecs describe-services \
        --cluster "$2" \
        --services "$3" \
        --query 'services[0].[serviceName,status,runningCount,desiredCount,taskDefinition]' \
        --output table
      ;;

    *)
      cat << 'EOF'
Usage: ecs <command> [options]

Commands:
  clusters                 List all ECS clusters
  services <cluster>       List services in a cluster
  tasks <cluster> [--running]
                          List tasks in a cluster (optionally only running)
  service-tasks <cluster> <service> [--running]
                          List tasks for a specific service (optionally only running)
  task-info <cluster> <task-id>
                          Get detailed task information
  exec <cluster> <task-id> <container> [command]
                          Execute command in a container (default: /bin/bash)
  exec-running <cluster> <container> [command]
                          Execute command in first running task (default: /bin/bash)
                          Add --service <service> to filter by service
  logs <cluster> <task-id> [--tail N]
                          Get task information and container logs
  stop <cluster> <task-id> [reason]
                          Stop a running task
  describe <cluster> <service>
                          Describe a service

Examples:
  ecs clusters
  ecs services my-cluster
  ecs tasks my-cluster --running
  ecs service-tasks my-cluster my-service --running
  ecs task-info my-cluster abc123def456
  ecs exec my-cluster abc123def456 my-container /bin/bash
  ecs exec my-cluster abc123def456 my-container ls -la /var/log
  ecs exec-running my-cluster my-container /bin/bash
  ecs exec-running my-cluster my-container --service my-service /bin/bash
  ecs exec-running my-cluster my-container ls -la /var/log
  ecs logs my-cluster abc123def456
  ecs stop my-cluster abc123def456
  ecs describe my-cluster my-service
EOF
      return 1
      ;;
  esac
}