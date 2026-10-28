# shellcheck shell=bash
# _ck_ecs_print_tasks CLUSTER TASK_ARNS_JSON
# Prints the task table for a JSON list of task ARNs. describe-tasks accepts at
# most 100 tasks per call, so the ARNs are sent in batches, each as one JSON
# list argument.
_ck_ecs_print_tasks() {
  local cluster="$1" task_arns="$2" count start=0 batch

  printf "%-40s %-15s %-15s %-25s %-15s\n" "TASK ID" "LAST STATUS" "DESIRED STATUS" "CONTAINER" "UPTIME"
  printf "%s\n" "$(printf '=%.0s' {1..110})"

  count=$(echo "$task_arns" | jq 'length')
  while [[ $start -lt $count ]]; do
    batch=$(echo "$task_arns" | jq -c ".[$start:$((start + 100))]")
    aws ecs describe-tasks \
      --cluster "$cluster" \
      --tasks "$batch" \
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
    start=$((start + 100))
  done
}

# ECS CLI function
_ck_ecs() {
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
        echo "Usage: ck ecs services <cluster-name>"
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
        echo "Usage: ck ecs tasks <cluster-name> [--running]"
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

      local count
      count=$(echo "$task_arns" | jq 'length')
      if [[ $count -eq 0 ]]; then
        echo "No tasks found in cluster: $2"
        return 0
      fi

      _ck_ecs_print_tasks "$2" "$task_arns"
      ;;

    service-tasks)
      # List tasks for a specific service
      if [[ $# -lt 3 ]]; then
        echo "Usage: ck ecs service-tasks <cluster-name> <service-name> [--running]"
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

      local count
      count=$(echo "$task_arns" | jq 'length')
      if [[ $count -eq 0 ]]; then
        echo "No tasks found for service: $3"
        return 0
      fi

      _ck_ecs_print_tasks "$2" "$task_arns"
      ;;

    task-info)
      # Get detailed info about a task
      if [[ $# -lt 3 ]]; then
        echo "Usage: ck ecs task-info <cluster-name> <task-id>"
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
        echo "Usage: ck ecs exec <cluster-name> <task-id> <container-name> [command]"
        echo "Example: ck ecs exec my-cluster abc123 my-container /bin/bash"
        echo "Example: ck ecs exec my-cluster abc123 my-container ls -la"
        return 1
      fi

      local cluster="$2"
      local task="$3"
      local container="$4"
      shift 4
      local command="$*"

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
        echo "Usage: ck ecs exec-running <cluster-name> <container-name> [--service <service-name>] [command]"
        echo "Example: ck ecs exec-running my-cluster my-container /bin/bash"
        echo "Example: ck ecs exec-running my-cluster my-container --service my-service /bin/bash"
        echo "Example: ck ecs exec-running my-cluster my-container --service my-service ls -la"
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
      local command="$*"

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
      task_id="${task_arn##*/}"

      aws ecs execute-command \
        --cluster "$cluster" \
        --task "$task_id" \
        --container "$container" \
        --interactive \
        --command "$command"
      ;;

    logs)
      # Show recent log lines of a task's container from CloudWatch Logs
      if [[ $# -lt 3 ]]; then
        echo "Usage: ck ecs logs <cluster-name> <task-id> [--tail N] [--container <name>]"
        return 1
      fi

      local cluster="$2"
      local task="$3"
      local tail_lines="50"
      local container_name=""
      shift 3
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --tail)
            tail_lines="$2"
            shift 2
            ;;
          --container)
            container_name="$2"
            shift 2
            ;;
          *)
            echo "Unknown option: $1"
            echo "Usage: ck ecs logs <cluster-name> <task-id> [--tail N] [--container <name>]"
            return 1
            ;;
        esac
      done
      # get-log-events returns at most 10000 events
      if ! [[ "$tail_lines" =~ ^[0-9]+$ ]] || [[ $tail_lines -lt 1 || $tail_lines -gt 10000 ]]; then
        echo "Error: --tail must be a number from 1 to 10000"
        return 1
      fi

      local task_details
      task_details=$(aws ecs describe-tasks \
        --cluster "$cluster" \
        --tasks "$task" \
        --query 'tasks[0]' \
        --output json) || return 1
      if [[ -z "$task_details" || "$task_details" == "null" ]]; then
        echo "Error: task not found: $task"
        return 1
      fi

      if [[ -z "$container_name" ]]; then
        container_name=$(echo "$task_details" | jq -r '.containers[0].name')
      fi
      local task_arn task_id task_definition
      task_arn=$(echo "$task_details" | jq -r '.taskArn')
      task_id="${task_arn##*/}"
      task_definition=$(echo "$task_details" | jq -r '.taskDefinitionArn')

      # The awslogs driver writes to <prefix>/<container>/<task-id>
      local log_config driver group prefix log_region
      log_config=$(aws ecs describe-task-definition \
        --task-definition "$task_definition" \
        --query 'taskDefinition.containerDefinitions' \
        --output json | jq -c --arg name "$container_name" \
          '.[] | select(.name == $name) | .logConfiguration // {}')
      if [[ -z "$log_config" ]]; then
        echo "Error: container '$container_name' is not in task definition $task_definition"
        return 1
      fi
      driver=$(echo "$log_config" | jq -r '.logDriver // empty')
      group=$(echo "$log_config" | jq -r '.options["awslogs-group"] // empty')
      prefix=$(echo "$log_config" | jq -r '.options["awslogs-stream-prefix"] // empty')
      log_region=$(echo "$log_config" | jq -r '.options["awslogs-region"] // empty')

      echo "Task: $task_id"
      echo "Container: $container_name"
      if [[ "$driver" != "awslogs" ]]; then
        echo "Error: container '$container_name' uses the '${driver:-default}' log driver; ck ecs logs reads awslogs (CloudWatch Logs) only"
        return 1
      fi
      if [[ -z "$prefix" ]]; then
        echo "Error: no awslogs-stream-prefix, so the log stream name is unknown. Try: aws logs tail $group --follow"
        return 1
      fi

      local stream="$prefix/$container_name/$task_id"
      echo "Log: $group $stream"
      echo ""
      local region_args=()
      if [[ -n "$log_region" ]]; then
        region_args+=(--region "$log_region")
      fi
      aws logs get-log-events \
        "${region_args[@]}" \
        --log-group-name "$group" \
        --log-stream-name "$stream" \
        --limit "$tail_lines" \
        --output json | jq -r '.events[].message'
      ;;

    stop)
      # Stop a task
      if [[ $# -lt 3 ]]; then
        echo "Usage: ck ecs stop <cluster-name> <task-id> [reason]"
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
        echo "Usage: ck ecs describe <cluster-name> <service-name>"
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
Usage: ck ecs <command> [options]

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
  logs <cluster> <task-id> [--tail N] [--container <name>]
                          Show the last N log lines (default 50) of a container
                          that uses the awslogs driver
  stop <cluster> <task-id> [reason]
                          Stop a running task
  describe <cluster> <service>
                          Describe a service

Examples:
  ck ecs clusters
  ck ecs services my-cluster
  ck ecs tasks my-cluster --running
  ck ecs service-tasks my-cluster my-service --running
  ck ecs task-info my-cluster abc123def456
  ck ecs exec my-cluster abc123def456 my-container /bin/bash
  ck ecs exec my-cluster abc123def456 my-container ls -la /var/log
  ck ecs exec-running my-cluster my-container /bin/bash
  ck ecs exec-running my-cluster my-container --service my-service /bin/bash
  ck ecs exec-running my-cluster my-container ls -la /var/log
  ck ecs logs my-cluster abc123def456
  ck ecs logs my-cluster abc123def456 --tail 200 --container my-container
  ck ecs stop my-cluster abc123def456
  ck ecs describe my-cluster my-service
EOF
      return 1
      ;;
  esac
}