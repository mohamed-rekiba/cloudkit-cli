## CloudKit CLI -- User Guide

Shell helpers for AWS and GCloud. Source one file, get interactive session management, service wrappers, and a color-coded prompt -- across both clouds.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 1) Prerequisites

**Common**

- Install `jq` for JSON parsing (macOS: `brew install jq`)
- Install `python3` (3.6+) for cross-platform credential expiry parsing

**AWS**

- Install AWS CLI v2 (`aws --version`)
- Configure AWS profiles in `~/.aws/config` (SSO, static keys, or credential_process -- all supported)
- Install `expect` for file upload functionality (macOS: `brew install expect`)
- Install `nc` (netcat) for file transfers (usually pre-installed on macOS/Linux)

**GCloud**

- Install Google Cloud SDK / `gcloud` CLI (`gcloud --version`)
- Create at least one gcloud configuration (`gcloud config configurations create <name>`)

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

### 2) Setup

Source `main.sh` to load all helpers into your shell.

- **One-time (current shell only):**

```bash
source /path/cloudkit-cli/main.sh
```

- **Permanent (every new shell):**
  Add the line above to `~/.zshrc`, `~/.bashrc`, or `~/.bash_profile`.

Notes:
- `main.sh` exports `CLOUDKIT_DIR` and loads all helper functions and aliases.
- An alias `sso_login` is created for convenience: `sso_login <profile>`.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 3) Commands -- AWS

- `aws_session`
  - Lists all configured AWS profiles from `~/.aws/config` -- SSO, static keys, and credential_process
  - If only one profile exists, it is auto-selected (no prompt)
  - Performs SSO login if not already authenticated (SSO profiles only)
  - After authentication, detects **chained profiles** (profiles with `source_profile`):
    - **One chained profile**: auto-selects it
    - **Multiple chained profiles**: displays a selection table
    - **No chained profiles**: continues with the base profile
  - Clears the terminal and displays account/profile/region in a styled table
  - Updates the shell prompt with `[profile:region]` (bash and zsh)
  - Warns if credentials will expire in ≤ 15 minutes (yellow) or ≤ 5 minutes (red)

- `aws_logout`
  - Unsets all AWS session environment variables (`AWS_PROFILE`, `AWS_REGION`, etc.)
  - Restores the original shell prompt
  - Does not delete any files from `~/.aws/`

- `aws_switch`
  - Switches to a different profile without re-running the full `aws_session` flow
  - Triggers SSO login automatically if the selected profile needs it
  - Updates the prompt and checks for upcoming expiry

- `sso_login <profile>` (alias)
  - Shortcut for `aws sso login --profile <profile>`

- `ec2` helper with subcommands:
  - `ec2 ls` -- list all EC2 instances (id, name, state)
  - `ec2 ls-running` -- list only running EC2 instances
  - `ec2 ls-stopped` -- list only stopped EC2 instances
  - `ec2 session <instance-id>` -- start an SSM shell session
  - `ec2 run <instance-id>` -- start (run) an EC2 instance
  - `ec2 stop <instance-id>` -- stop an EC2 instance
  - `ec2 port-forward <remote-port> <local-port> <instance-id> [host]` -- start SSM port forwarding
    - **Without host:** forwards from the EC2 instance itself (e.g., web server on the instance)
    - **With host:** forwards from a remote service through the EC2 instance (e.g., RDS, ElastiCache)
  - `ec2 upload <instance-id> <local-file> [remote-path] [port]` -- upload a file to an EC2 instance via SSM port forwarding

- `ecs` helper with subcommands:
  - `ecs clusters` -- list all ECS clusters
  - `ecs services <cluster>` -- list services in a cluster
  - `ecs tasks <cluster> [--running]` -- list tasks in a cluster (optionally only running)
  - `ecs service-tasks <cluster> <service> [--running]` -- list tasks for a specific service
  - `ecs task-info <cluster> <task-id>` -- get detailed task information (status, container, image, uptime)
  - `ecs exec <cluster> <task-id> <container> [command]` -- execute command in a container (default: /bin/bash)
  - `ecs logs <cluster> <task-id> [--tail N]` -- get task information and container logs
  - `ecs stop <cluster> <task-id> [reason]` -- stop a running task
  - `ecs describe <cluster> <service>` -- describe a service (status, running/desired count, task definition)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 4) Commands -- GCloud

- `gcloud_session [--reauth]`
  - Lists all gcloud configurations and lets you select one
  - If only one configuration exists, it is auto-selected (no prompt)
  - Validates existing credentials or initiates `gcloud auth login`
  - Pass `--reauth` to force re-authentication
  - Clears the terminal and displays account/config/project/region in a styled table
  - Updates the shell prompt with `[gcloud:account:project]` (bash and zsh)

- `gcloud_logout`
  - Unsets gcloud session environment variables (`GCLOUD_ACTIVE_CONFIG`, `GCLOUD_ACCOUNT`, `GCLOUD_PROJECT`)
  - Restores the original shell prompt

- `gcloud_switch`
  - Switches to a different gcloud configuration without re-running full authentication
  - Updates the prompt and session table

- `gce` helper with subcommands:
  - `gce ls [--filter <pattern>]` -- list GCE instances (optional name filter)
  - `gce ssh <instance> [--zone <zone>] [command]` -- SSH to a GCE VM (optional remote command)
  - `gce scp <source> <destination> [--zone <zone>]` -- copy files to/from a GCE VM

- `gce-ig` helper with subcommands:
  - `gce-ig list [--region <region>]` -- list managed instance groups
  - `gce-ig describe <group> --region <region>` -- describe a managed instance group
  - `gce-ig recreate <group> --region <region>` -- replace instances (rolling replace)
  - `gce-ig restart <group> --region <region>` -- restart instances (rolling restart)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 5) Typical Workflow

**AWS**

```
source /path/cloudkit-cli/main.sh
aws_session            # select profile, SSO login, view session table
ec2 ls-running         # list running instances
ec2 session i-0123...  # SSM into an instance
aws_switch             # switch to another profile mid-session
aws_logout             # clear session
```

**GCloud**

```
source /path/cloudkit-cli/main.sh
gcloud_session         # select config, authenticate, view session table
gce ls                 # list GCE instances
gce ssh my-vm --zone us-central1-a
gce-ig list            # list managed instance groups
gcloud_switch          # switch to another config
gcloud_logout          # clear session
```

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 6) Verification Steps

**AWS**

- `aws_session` shows a table with correct Account (formatted `XXXX-XXXX-XXXX`), Profile, Region, Identity ARN, and User ID
- Single-profile auto-selection works without prompting
- Chained profiles (via `source_profile`) are detected and offered after authentication
- Shell prompt updates to `[profile:region]`
- `ec2 ls` outputs instance data without errors
- `ecs clusters` lists available ECS clusters

**GCloud**

- `gcloud_session` shows a table with Account, Configuration, Project, and Region
- Single-config auto-selection works without prompting
- Shell prompt updates to `[gcloud:account:project]`
- `gce ls` lists GCE instances
- `gce-ig list` lists managed instance groups

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 7) Troubleshooting

**Common**

- `jq: command not found` -- install `jq` (macOS: `brew install jq`)

**AWS**

- `aws: command not found` or AWS CLI v1 detected -- install `awscli` (macOS: `brew install awscli`)
- No profiles listed in `aws_session` -- ensure `~/.aws/config` profiles include `sso_account_id`, `aws_access_key_id`, or `credential_process`
- Chained profile not detected -- ensure it has `source_profile = <base-profile-name>` matching exactly
- Chained profile fails to assume role -- verify the `role_arn` is correct and permissions allow it
- SSM session errors -- ensure the instance has SSM agent installed and proper IAM role
- ECS exec fails -- ensure ECS Exec is enabled (`enableExecuteCommand: true`) and the task role has SSM permissions
- File upload fails -- ensure `expect` and `nc` are installed, SSM agent is running, and the port is available

**GCloud**

- `gcloud: command not found` -- install the Google Cloud SDK
- No configurations listed -- create one with `gcloud config configurations create <name>` and set account/project
- Authentication fails -- try `gcloud_session --reauth` to force re-login
- `gce ssh` permission denied -- ensure your account has `compute.instances.osLogin` or OS Login is configured
- `gce-ig` region required -- most instance group commands require `--region <region>`

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 8) Repository Structure

- `main.sh` -- entrypoint; exports `CLOUDKIT_DIR`, loads session and service helpers
- `session.sh` -- session management for both AWS and GCloud: profile/config picker, SSO/auth login, session table, prompt updates
- `services/ec2.sh` -- `ec2` command group: list instances, SSM session, port forwarding, file upload
- `services/_ec2_upload.sh` -- file upload script using Expect for SSM port forwarding transfers
- `services/ecs.sh` -- `ecs` command group: clusters, services, tasks, exec, logs, stop, describe
- `services/gce.sh` -- `gce` command group: list instances, SSH, SCP
- `services/gce_ig.sh` -- `gce-ig` command group: list, describe, recreate, restart managed instance groups

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 9) Development / Testing

- **Lint (Shellcheck)**
  Install [Shellcheck](https://github.com/koalaman/shellcheck) (e.g. `brew install shellcheck` on macOS), then run:
  ```bash
  make shellcheck
  ```

- **Smoke tests** (no AWS/GCloud credentials required):
  ```bash
  make test
  ```

- **CI**
  On push or pull request to `main`, GitHub Actions runs Shellcheck and the smoke tests. See `.github/workflows/ci.yml`.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

### 10) Uninstall / Disable

- Remove or comment out the `source /path/cloudkit-cli/main.sh` line from:
  - `~/.zshrc` (Zsh) or
  - `~/.bashrc` / `~/.bash_profile` (Bash)
- Restart your terminal (or re-source the rc file)
