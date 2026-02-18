## AWS Helpers – User Guide

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 1) Prerequisites

- Install AWS CLI v2 (`aws --version`)
- Configure AWS SSO profiles in `~/.aws/config` (must include `sso_account_id` and `region`)
- Install `jq` for JSON parsing
- Install `expect` for file upload functionality (macOS: `brew install expect`)
- Install `nc` (netcat) for file transfers (usually pre-installed on macOS/Linux)

Example AWS profiles (in `~/.aws/config`):

```ini
[sso-session my-session]
sso_start_url = https://example.awsapps.com/start
sso_region = us-east-1
sso_registration_scopes = sso:account:access

[profile my-sso-profile]
sso_session = my-session
sso_account_id = 123456789012
sso_role_name = ReadOnly
region = us-east-1
output = json
```

Chained profiles (role assumption via `source_profile`) are also supported:

```ini
[profile dev-admin]
source_profile = my-sso-profile
role_arn = arn:aws:iam::098765432109:role/AdminRole
region = eu-west-1

[profile prod-readonly]
role_arn = arn:aws:iam::111222333444:role/ReadOnly
source_profile = my-sso-profile
region = us-west-2
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 2) Setup (Load the helpers into your shell)

- Decide how you want to load the helpers:
  - **One-time (current shell only):**
    - Run:

```bash
source /path/aws-cli-helpers/main.sh
```

  - **Permanent (every new shell):**
    - Add to `~/.zshrc`, `~/.bashrc`(or `~/.bash_profile`:

Notes:
- `main.sh` exports `AWS_HELPERS_DIR` and loads all helper functions and aliases.
- An alias `sso_login` is created for convenience: `sso_login <profile>`.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 3) Commands Provided

-  `aws_session`
  - Interactively select an AWS SSO profile (parses `~/.aws/config` for `sso_account_id` and `region`)
  - If only one SSO profile exists, it is auto-selected (no prompt)
  - Performs SSO login if not already authenticated
  - After authentication, detects **chained profiles** (profiles with `source_profile` pointing to the selected profile):
    - **One chained profile**: auto-selects it and switches `AWS_PROFILE` / `AWS_DEFAULT_PROFILE`
    - **Multiple chained profiles**: displays a selection table for the user to choose
    - **No chained profiles**: continues with the base profile as before
  - Clears the terminal and displays account/profile/region in a styled table
  - Sets a helpful prompt showing `user@account:profile:region`

- `sso_login <profile>` (alias)
  - Shortcut for `aws sso login --profile <profile>`

- `ec2` helper with subcommands:
  - `ec2 ls` — list all EC2 instances (id, name, state)
  - `ec2 ls-running` — list only running EC2 instances
  - `ec2 ls-stopped` — list only stopped EC2 instances
  - `ec2 session <instance-id>` — start an SSM shell session
  - `ec2 run <instance-id>` — start (run) an EC2 instance
  - `ec2 stop <instance-id>` — stop an EC2 instance
  - `ec2 port-forward <remote-port> <local-port> <instance-id> [host]` — start SSM port forwarding
    - **Without host:** forwards from the EC2 instance itself (e.g., web server on the instance)
    - **With host:** forwards from a remote service through the EC2 instance (e.g., RDS, ElastiCache)
  - `ec2 upload <instance-id> <local-file> [remote-path] [port]` — upload a file to an EC2 instance via SSM port forwarding
    - **Arguments:**
      - `<instance-id>` — EC2 instance ID (e.g., `i-0123456789abcdef0`)
      - `<local-file>` — Path to the local file to upload
      - `[remote-path]` — (Optional) Remote file path (default: `/home/ec2-user/<filename>`)
      - `[port]` — (Optional) Port number for transfer (default: random port 50000-59999)
    - **Features:**
      - Uses SSM port forwarding for secure file transfer
      - Automatically creates remote directory if needed
      - Displays file size and MD5 checksums for verification
      - Verifies file was successfully uploaded
      - Cleans up SSM sessions automatically

- `ecs` helper with subcommands:
  - `ecs clusters` — list all ECS clusters
  - `ecs services <cluster>` — list services in a cluster
  - `ecs tasks <cluster> [--running]` — list tasks in a cluster (optionally only running)
  - `ecs service-tasks <cluster> <service> [--running]` — list tasks for a specific service
  - `ecs task-info <cluster> <task-id>` — get detailed task information (status, container, image, uptime)
  - `ecs exec <cluster> <task-id> <container> [command]` — execute command in a container (default: /bin/bash)
  - `ecs logs <cluster> <task-id> [--tail N]` — get task information and container logs
  - `ecs stop <cluster> <task-id> [reason]` — stop a running task
  - `ecs describe <cluster> <service>` — describe a service (status, running/desired count, task definition)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 4) Typical Workflow

- Load the helpers (see Setup above)
- Run `aws_session`
  - If only one SSO profile exists, it is auto-selected; otherwise select from the interactive list
  - If prompted, complete SSO login in your browser
  - If chained profiles exist for the selected base profile, choose one (or it auto-selects if only one)
  - Verify the printed table shows the expected Account, Profile, Region
- Use EC2 helpers as needed, for example:
  - `ec2 ls`
  - `ec2 ls-running`
  - `ec2 ls-stopped`
  - `ec2 session i-0123456789abcdef0`
  - `ec2 run i-0123456789abcdef0`
  - `ec2 stop i-0123456789abcdef0`
  - `ec2 port-forward 8080 8080 i-0123456789abcdef0` (forward to EC2 instance itself)
  - `ec2 port-forward 3306 3306 i-0123456789abcdef0 mydb.123456789012.us-west-2.rds.amazonaws.com` (forward to RDS through EC2)
  - `ec2 upload i-0123456789abcdef0 /local/file.txt`
  - `ec2 upload i-0123456789abcdef0 /local/file.txt /home/ec2-user/file.txt`
  - `ec2 upload i-0123456789abcdef0 /local/file.txt /home/ec2-user/file.txt 8888`
- Use ECS helpers as needed, for example:
  - `ecs clusters`
  - `ecs services my-cluster`
  - `ecs tasks my-cluster --running`
  - `ecs service-tasks my-cluster my-service --running`
  - `ecs task-info my-cluster abc123def456`
  - `ecs exec my-cluster abc123def456 my-container /bin/bash`
  - `ecs exec my-cluster abc123def456 my-container ls -la /var/log`
  - `ecs logs my-cluster abc123def456`
  - `ecs stop my-cluster abc123def456`
  - `ecs describe my-cluster my-service`

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 5) Verification Steps (Success Criteria)

- Running `aws_session` shows a table with:
  - Correct AWS Account (formatted `XXXX-XXXX-XXXX`)
  - Selected AWS Profile (or chained profile if applicable)
  - Current Region
  - Identity ARN
  - User ID
- If only one SSO profile exists, it is auto-selected without prompting
- Chained profiles (via `source_profile`) are detected and offered after authentication
- `ec2 ls` outputs instances data as JSON lines (via `jq -r`), without errors
- `ec2 session <instance-id>` starts an interactive SSM shell session
- `ec2 port-forward <remote-port> <local-port> <instance-id>` forwards from the EC2 instance itself
- `ec2 port-forward <remote-port> <local-port> <instance-id> <host>` forwards from a remote service through EC2
- `ec2 upload <instance-id> <local-file>` uploads a file to the instance and displays verification (file size, MD5 checksums)
- `ecs clusters` lists all available ECS clusters
- `ecs services <cluster>` lists services in the specified cluster
- `ecs tasks <cluster>` displays a formatted table with task ID, status, container, and uptime
- `ecs exec <cluster> <task-id> <container>` starts an interactive shell in the container
- `ecs describe <cluster> <service>` shows service details in a table format
- Your shell prompt updates to include `user@account:profile:region`

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 6) Troubleshooting

- `jq: command not found`
  - Install `jq` (macOS: `brew install jq`)

- `aws: command not found` or AWS CLI v1 detected
  - Install `awscli` (macOS: `brew install awscli`)

- No profiles listed in `aws_session`
  - Ensure your `~/.aws/config` profiles include both `sso_account_id` and `region`
  - Example provided in the Prerequisites section

- Chained profile not detected
  - Ensure the chained profile has `source_profile = <base-profile-name>` matching the selected SSO profile name exactly
  - The chained profile must be defined in `~/.aws/config` with a `[profile name]` section header

- Chained profile fails to assume role
  - Verify the `role_arn` in the chained profile is correct and your SSO user has permission to assume it
  - The session will fall back to the base SSO profile automatically

- SSM session errors
  - Ensure the instance has SSM agent installed and proper IAM role
  - Ensure network/VPC endpoints allow SSM

- ECS exec command fails
  - Ensure ECS Exec is enabled on the service (`enableExecuteCommand: true`)
  - Verify the task role has required permissions for SSM
  - Check that the container has a shell available at the specified path

- ECS tasks showing incorrect uptime
  - Ensure system time is synchronized
  - Verify `jq` version supports time functions (jq 1.5+)

- File upload fails
  - Ensure `expect` is installed (`which expect`)
  - Ensure `nc` (netcat) is available on both local and remote systems
  - Verify the instance has SSM agent running and proper IAM permissions
  - Check that the specified port is not already in use (script uses random port 50000-59999 by default)
  - Ensure the remote directory path exists or can be created

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 7) Repository Structure

- `main.sh` — Entrypoint; exports `AWS_HELPERS_DIR`, loads sessions and EC2/ECS helpers
- `session.sh` — Session orchestration: profile picker (with auto-select), SSO login, chained profile detection, table display
- `services/ec2.sh` — `ec2` command group: list instances, SSM session, port forwarding, file upload
- `services/_ec2_upload.sh` — File upload script using Expect for SSM port forwarding transfers
- `services/ecs.sh` — `ecs` command group: clusters, services, tasks, exec, logs, stop, describe

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 8) Development / Testing

- **Lint (Shellcheck)**  
  Install [Shellcheck](https://github.com/koalaman/shellcheck) (e.g. `brew install shellcheck` on macOS), then run:
  ```bash
  make shellcheck
  ```
  Or: `shellcheck -x main.sh session.sh services/ec2.sh services/ecs.sh`

- **Smoke tests** (no AWS credentials required):
  ```bash
  make test
  ```
  Or: `bash test/run.sh` from the repo root. Tests verify that sourcing `main.sh` succeeds and that `ec2` / `ecs` with no arguments print usage and exit non-zero.

- **CI**  
  On push or pull request to `main`, GitHub Actions runs Shellcheck and the smoke tests. See `.github/workflows/ci.yml`.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 9) Uninstall / Disable

- Remove or comment out the `source /path/aws-cli-helpers/main.sh` line from:
  - `~/.zshrc` (Zsh) or
  - `~/.bashrc` / `~/.bash_profile` (Bash)
- Restart your terminal (or re-source the rc file)