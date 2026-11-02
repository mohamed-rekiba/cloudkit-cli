# CloudKit CLI

Shell helpers for AWS and GCloud. Source one file to get interactive session management, service wrappers, and a color-coded prompt for both clouds.

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Setup](#2-setup)
3. [Commands: AWS](#3-commands-aws)
4. [Commands: GCloud](#4-commands-gcloud)
5. [EC2 tunnel](#5-ec2-tunnel)
6. [Typical workflow](#6-typical-workflow)
7. [Verification steps](#7-verification-steps)
8. [Troubleshooting](#8-troubleshooting)
9. [Repository structure](#9-repository-structure)
10. [Development and testing](#10-development-and-testing)
11. [Uninstall](#11-uninstall)

## 1) Prerequisites

### Tools

**Common**

- `jq` for JSON parsing (macOS: `brew install jq`)
- `python3` (3.6+) for cross-platform parsing of credential expiry

**AWS**

- AWS CLI v2 (`aws --version`)
- `expect` and `nc` (netcat) for `ec2 upload` (macOS: `brew install expect`; `nc` is usually installed)
- The [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for SSM sessions, port forwarding, and `ec2 tunnel`
- `autossh` for `ec2 tunnel` (macOS: `brew install autossh`; Debian/Ubuntu: `sudo apt install autossh`)

**GCloud**

- Google Cloud SDK / `gcloud` CLI (`gcloud --version`)
- At least one gcloud configuration (see below)

### AWS configuration

Put your profiles in `~/.aws/config`. SSO, static keys, and `credential_process` profiles all work.

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

Chained profiles (role assumption with `source_profile`) also work:

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

### GCloud configuration

gcloud stores each configuration as a separate file in `~/.config/gcloud/configurations/`. Create them with the `gcloud` CLI:

```bash
# Create a configuration for a project
gcloud config configurations create my-project
gcloud config set core/account user@example.com
gcloud config set core/project my-gcp-project
gcloud config set compute/region us-central1
gcloud config set compute/zone us-central1-a

# Create another configuration for a different project
gcloud config configurations create staging
gcloud config set core/account user@example.com
gcloud config set core/project my-staging-project
gcloud config set compute/region europe-west1
gcloud config set compute/zone europe-west1-b
```

The file for `my-project` (`~/.config/gcloud/configurations/config_my-project`) then looks like this:

```ini
[core]
account = user@example.com
project = my-gcp-project

[compute]
region = us-central1
zone = us-central1-a
```

`gcloud_session` finds these configurations with `gcloud config configurations list` and lets you pick one.

## 2) Setup

Source `main.sh` to load all helpers into your shell.

- **Current shell only:**

  ```bash
  source /path/cloudkit-cli/main.sh
  ```

- **Every new shell:** add the line above to `~/.zshrc`, `~/.bashrc`, or `~/.bash_profile`.

`main.sh` exports `CLOUDKIT_DIR` and loads all helper functions and aliases. It also creates the alias `sso_login <profile>`.

## 3) Commands: AWS

### Session

- `aws_session`
  - Lists all profiles in `~/.aws/config`: SSO, static keys, and `credential_process`.
  - Selects the profile without a prompt when only one exists.
  - Runs SSO login when the profile is an SSO profile and is not logged in.
  - After login, looks for **chained profiles** (profiles with `source_profile`):
    - **One chained profile:** selects it.
    - **More than one:** shows a table to pick from.
    - **None:** keeps the base profile.
  - Clears the terminal and shows account, profile, and region in a table.
  - Sets the shell prompt to `[profile:region]` (bash and zsh).
  - Warns when the credentials expire in 15 minutes or less (yellow) or 5 minutes or less (red).

- `aws_logout`
  - Unsets the AWS session variables (`AWS_PROFILE`, `AWS_REGION`, and others).
  - Restores the original shell prompt.
  - Deletes no files in `~/.aws/`.

- `aws_switch`
  - Switches to another profile without the full `aws_session` flow.
  - Runs SSO login when the new profile needs it.
  - Updates the prompt and checks the expiry time.

- `sso_login <profile>` (alias)
  - Runs `aws sso login --profile <profile>`.

### `ec2`

| Command | What it does |
|---|---|
| `ec2 ls` | List all instances (ID, name, state) |
| `ec2 ls-running` | List running instances |
| `ec2 ls-stopped` | List stopped instances |
| `ec2 session <instance-id>` | Open an SSM shell on the instance |
| `ec2 run <instance-id>` | Start the instance |
| `ec2 stop <instance-id>` | Stop the instance |
| `ec2 port-forward <remote-port> <local-port> <instance-id> [host]` | Forward a port to your machine over SSM. Without `host`, the port is on the instance itself (for example a web server). With `host`, the port is on a service the instance can reach (for example RDS or ElastiCache). |
| `ec2 upload <instance-id> <local-file> [remote-path] [port]` | Upload a file to the instance over SSM port forwarding |
| `ec2 tunnel [ssh-host]` | Open a reverse SSH tunnel over SSM, and reconnect when it drops. The default `ssh-host` is `ec2-tunnel`. Needs a one-time setup: see [EC2 tunnel](#5-ec2-tunnel). |

### `ecs`

| Command | What it does |
|---|---|
| `ecs clusters` | List all clusters |
| `ecs services <cluster>` | List the services in a cluster |
| `ecs tasks <cluster> [--running]` | List the tasks in a cluster, or only the running ones |
| `ecs service-tasks <cluster> <service> [--running]` | List the tasks of one service |
| `ecs task-info <cluster> <task-id>` | Show task details: status, container, image, uptime |
| `ecs exec <cluster> <task-id> <container> [command]` | Run a command in a container. The default command is `/bin/bash`. |
| `ecs exec-running <cluster> <container> [--service <service>] [command]` | Run a command in the first running task of the cluster, or of one service. The default command is `/bin/bash`. |
| `ecs logs <cluster> <task-id> [--tail N]` | Show task details and container logs |
| `ecs stop <cluster> <task-id> [reason]` | Stop a running task |
| `ecs describe <cluster> <service>` | Show a service: status, running and desired count, task definition |

## 4) Commands: GCloud

### Session

- `gcloud_session [--reauth]`
  - Lists all gcloud configurations and lets you pick one.
  - Selects the configuration without a prompt when only one exists.
  - Checks the existing credentials, or runs `gcloud auth login`.
  - `--reauth` forces a new login.
  - Clears the terminal and shows account, configuration, project, and region in a table.
  - Sets the shell prompt to `[gcloud:account:project]` (bash and zsh).

- `gcloud_logout`
  - Unsets the gcloud session variables (`GCLOUD_ACTIVE_CONFIG`, `GCLOUD_ACCOUNT`, `GCLOUD_PROJECT`).
  - Restores the original shell prompt.

- `gcloud_switch`
  - Switches to another configuration without a full login.
  - Updates the prompt and the session table.

### `gce`

| Command | What it does |
|---|---|
| `gce ls [--filter <pattern>]` | List instances, optionally filtered by name |
| `gce ssh <instance> [--zone <zone>] [command]` | SSH to a VM, optionally running one command |
| `gce scp <source> <destination> [--zone <zone>]` | Copy files to or from a VM |

### `gce-ig`

| Command | What it does |
|---|---|
| `gce-ig list [--region <region>]` | List managed instance groups |
| `gce-ig describe <group> --region <region>` | Describe a managed instance group |
| `gce-ig recreate <group> --region <region>` | Replace the instances (rolling replace) |
| `gce-ig restart <group> --region <region>` | Restart the instances (rolling restart) |

## 5) EC2 tunnel

`ec2 tunnel` opens a reverse SSH tunnel over SSM. Traffic to a port on an EC2 instance goes to a port on your machine, for example from port `8080` on the instance to `localhost:8080`. The instance needs no inbound SSH port.

Do the setup in [docs/ec2-tunnel.md](docs/ec2-tunnel.md) first. That guide covers how the tunnel works, the AWS environment and policies it needs, the one-time setup, limits, and troubleshooting. This section covers only what the CLI adds.

### Usage

```bash
ec2 tunnel              # use the Host entry "ec2-tunnel" in ~/.ssh/config
ec2 tunnel <ssh-host>   # use another Host entry
```

Press Ctrl+C to close the tunnel.

### What `ec2 tunnel` reads from `~/.ssh/config`

| Setting | How the CLI uses it |
|---|---|
| `HostName` | Must be an instance ID (`i-...` or `mi-...`). Otherwise the CLI stops with an error. |
| `RemoteForward` | Must be set. The CLI shows the first one in its banner, and warns when it binds to the loopback address of the instance. autossh opens every forward in the entry. |
| `--profile` and `--region` in `ProxyCommand` | The CLI uses them to check your credentials and to look up the instance IP, so both use the account that the tunnel connects to. |

### What `ec2 tunnel` does on each run

1. Checks that `ssh`, `aws`, and `autossh` are installed.
2. Checks your AWS credentials. For an SSO profile, it runs `aws sso login` when the session expired.
3. Looks up the IP of the instance, and shows it in the banner with the forward.
4. Stops with an error when a tunnel for the same host already runs on your machine. Two tunnels for one host fight for the same instance port.
5. Tries to close an old tunnel session on the instance. Over SSH, it runs `sudo ss` and kills `sshd` processes that listen on the forwarded port. This step is best effort: the tunnel starts even when it fails. It does nothing with the restricted key from the setup guide, because that key cannot run commands.
6. Starts `AUTOSSH_GATETIME=0 autossh -M 0 -N <ssh-host>`. autossh reconnects when the connection drops.

## 6) Typical workflow

**AWS**

```bash
source /path/cloudkit-cli/main.sh
aws_session            # select profile, SSO login, view session table
ec2 ls-running         # list running instances
ec2 session i-0123...  # SSM into an instance
aws_switch             # switch to another profile mid-session
aws_logout             # clear session
```

**GCloud**

```bash
source /path/cloudkit-cli/main.sh
gcloud_session         # select config, authenticate, view session table
gce ls                 # list GCE instances
gce ssh my-vm --zone us-central1-a
gce-ig list            # list managed instance groups
gcloud_switch          # switch to another config
gcloud_logout          # clear session
```

## 7) Verification steps

**AWS**

- `aws_session` shows a table with the account (formatted `XXXX-XXXX-XXXX`), profile, region, identity ARN, and user ID.
- With one profile, `aws_session` selects it without a prompt.
- `aws_session` finds chained profiles (with `source_profile`) and offers them after login.
- The shell prompt changes to `[profile:region]`.
- `ec2 ls` shows instance data without errors.
- `ecs clusters` lists the ECS clusters.

**GCloud**

- `gcloud_session` shows a table with the account, configuration, project, and region.
- With one configuration, `gcloud_session` selects it without a prompt.
- The shell prompt changes to `[gcloud:account:project]`.
- `gce ls` lists the GCE instances.
- `gce-ig list` lists the managed instance groups.

## 8) Troubleshooting

### Common

**`jq: command not found`**
Install `jq` (macOS: `brew install jq`).

### AWS

**`aws: command not found`, or AWS CLI v1 found**
Install AWS CLI v2 (macOS: `brew install awscli`).

**No profiles listed in `aws_session`**
Check that each profile in `~/.aws/config` has `sso_account_id`, `aws_access_key_id`, or `credential_process`.

**Chained profile not found**
Check that the profile has `source_profile = <base-profile-name>`, and that the name matches exactly.

**Chained profile fails to assume the role**
Check that `role_arn` is correct and that the base profile is allowed to assume it.

**SSM session errors**
Check that the SSM agent runs on the instance and that the instance role allows SSM.

**`ecs exec` fails**
Check that ECS Exec is on for the service (`enableExecuteCommand: true`) and that the task role has SSM permissions.

**`ec2 upload` fails**
Check that `expect` and `nc` are installed, that the SSM agent runs, and that the port is free.

### EC2 tunnel

These entries cover errors from the CLI. For errors from SSH, SSM, or the API, see [Troubleshooting in docs/ec2-tunnel.md](docs/ec2-tunnel.md#8-troubleshooting).

**`Error: autossh is required. Please install it.`**
Install the tool that the error names. For `autossh` on macOS: `brew install autossh`.

**`HostName for '<host>' in ~/.ssh/config is not an instance ID`**
Set `HostName` in the `Host` entry to the instance ID, for example `i-0123456789abcdef0`.

**`No RemoteForward found for '<host>' in ~/.ssh/config`**
Add a `RemoteForward` line to the `Host` entry. See the `Host` entry step in [docs/ec2-tunnel.md](docs/ec2-tunnel.md).

**`AWS credentials are not valid for profile '<profile>'`**
The profile is not an SSO profile, and its credentials do not work. Run `aws configure list --profile <profile>` to check it.

**`a tunnel for '<host>' is already running`**
Another `ec2 tunnel` for the same host is still open, maybe in another terminal. Close it with Ctrl+C, or run the `kill <pid>` command that the error shows.

**`Note: the forward binds to the instance loopback only`**
Other hosts, such as the ALB, cannot reach the forwarded port. Set the bind address in `RemoteForward`, for example `0.0.0.0:8080`, and turn on `GatewayPorts` on the instance as described in [docs/ec2-tunnel.md](docs/ec2-tunnel.md).

### GCloud

**`gcloud: command not found`**
Install the Google Cloud SDK.

**No configurations listed**
Create one with `gcloud config configurations create <name>`, then set the account and project.

**Login fails**
Run `gcloud_session --reauth` to force a new login.

**`gce ssh` permission denied**
Check that your account has `compute.instances.osLogin`, or that OS Login is set up.

**`gce-ig` asks for a region**
Most `gce-ig` commands need `--region <region>`.

## 9) Repository structure

| File | Contents |
|---|---|
| `main.sh` | Entry point. Exports `CLOUDKIT_DIR` and loads the session and service helpers. |
| `session.sh` | Session management for AWS and GCloud: profile and configuration picker, login, session table, prompt |
| `services/ec2.sh` | `ec2` commands: list, SSM session, start and stop, port forwarding, upload, tunnel |
| `services/_ec2_upload.sh` | File upload script. Uses Expect over SSM port forwarding. |
| `services/ecs.sh` | `ecs` commands: clusters, services, tasks, exec, logs, stop, describe |
| `services/gce.sh` | `gce` commands: list, SSH, SCP |
| `services/gce_ig.sh` | `gce-ig` commands: list, describe, recreate, restart |
| `test/` | Bash tests with mocks for `aws`, `ssh`, and `autossh`. They need no cloud credentials. |
| `docs/ec2-tunnel.md` | EC2 tunnel guide: environment, required policies, setup, daily use, and troubleshooting. The diagram is in `docs/images/`. |

## 10) Development and testing

Install [Shellcheck](https://github.com/koalaman/shellcheck) (macOS: `brew install shellcheck`).

| Command | What it runs |
|---|---|
| `make shellcheck` | Shellcheck on the Bash scripts |
| `make test` | All tests. They need no AWS or GCloud credentials. |
| `make ci` | Shellcheck, then all tests. Run this before you push. |

Close any open `ec2 tunnel` before you run the tests. The `ec2 tunnel` tests fail while a real tunnel for `ec2-tunnel` runs on your machine, because the "already running" check finds it.

On push or pull request to `main`, GitHub Actions runs Shellcheck and the tests. See `.github/workflows/ci.yml`.

## 11) Uninstall

1. Remove or comment out the `source /path/cloudkit-cli/main.sh` line in `~/.zshrc`, `~/.bashrc`, or `~/.bash_profile`.
2. Open a new terminal, or source the rc file again.
