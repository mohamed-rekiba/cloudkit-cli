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

`ec2 tunnel` makes a port on your machine available as a port on an EC2 instance. Traffic to port `8080` on the instance goes to `localhost:8080` on your machine. The instance needs no open SSH port.

### How it works

1. **SSM carries the connection.** The `ProxyCommand` in `~/.ssh/config` opens an SSM session to port 22 on the instance. Your AWS login (SSO or other) controls who can open this session.
2. **sshd on the instance does the login.** sshd knows nothing about IAM or SSO. It checks your SSH key against `authorized_keys`. This is why the tunnel needs a key even when SSO works.
3. **sshd opens the forwarded port.** `RemoteForward` asks sshd to listen on the instance port. sshd decides the bind address, not your `~/.ssh/config`.
4. **autossh keeps it up.** When the connection drops, autossh reconnects.

> **Warning:** some hardened images set `DenyUsers *` in `/etc/ssh/sshd_config`. That blocks every SSH login, so the tunnel cannot work. Check this before you start. See [Troubleshooting](#ec2-tunnel) for how to check and what to ask the image owner.

### One-time setup

Do steps 1 to 4 once per instance. Replace the instance ID, region, and profile with your own.

**Step 1. Create an SSH key** for the tunnel. You can also use an existing key, such as `~/.ssh/id_ed12345`. Then use its path in steps 2 and 5.

```bash
ssh-keygen -t ed12345 -f ~/.ssh/ec2_tunnel -C "ec2-tunnel"
```

**Step 2. Add the public key to the instance.** This command uses SSM Run Command, so it needs no SSH access:

```bash
aws ssm send-command \
  --instance-ids i-0123456789abcdef0 \
  --document-name AWS-RunShellScript \
  --region us-east-1 \
  --profile <aws_profile> \
  --parameters "commands=[\"mkdir -p /home/ec2-user/.ssh\",\"echo '$(cat ~/.ssh/ec2_tunnel.pub)' >> /home/ec2-user/.ssh/authorized_keys\",\"chown -R ec2-user:ec2-user /home/ec2-user/.ssh\",\"chmod 700 /home/ec2-user/.ssh\",\"chmod 600 /home/ec2-user/.ssh/authorized_keys\"]"
```

The command prints a `CommandId`. Use it to check that the command succeeded:

```bash
aws ssm list-command-invocations \
  --command-id <command-id> \
  --details \
  --region us-east-1 \
  --profile <aws_profile> \
  --query 'CommandInvocations[0].Status'
```

**Step 3. Let other hosts reach the forwarded port.** Do this step when `RemoteForward` binds to `0.0.0.0`, as in step 5. By default, sshd binds a remote forward to `127.0.0.1` on the instance, even when `RemoteForward` asks for `0.0.0.0`. You cannot change this in `~/.ssh/config`.

Open a shell on the instance with `ec2 session i-0123456789abcdef0`. Then enable `GatewayPorts` and restart sshd:

```bash
echo 'GatewayPorts clientspecified' | sudo tee /etc/ssh/sshd_config.d/00-gateway-ports.conf
sudo sshd -t && sudo systemctl restart sshd
```

- The example is for Amazon Linux 2023, which reads `/etc/ssh/sshd_config.d/`.
- sshd uses the first value it reads. The `00-` prefix makes this file win over other files.
- The security group of the instance must allow inbound traffic on the forwarded port (`8080` in the example).
- If a tunnel is already open, restart it.

**Step 4. Make sshd close dead sessions** (optional, recommended). When your machine sleeps or the network drops, the SSM agent does not always close its connection to sshd. sshd then keeps the forwarded port open, and new tunnels fail with `remote port forwarding failed`. With these settings, sshd closes a silent session after about 90 seconds:

```bash
printf 'ClientAliveInterval 30\nClientAliveCountMax 3\n' | sudo tee /etc/ssh/sshd_config.d/00-client-alive.conf
sudo sshd -t && sudo systemctl restart sshd
```

**Step 5. Add a `Host` entry to `~/.ssh/config`.** `ec2 tunnel` uses `ec2-tunnel` as the default host name:

```
Host ec2-tunnel
    HostName i-0123456789abcdef0
    User ec2-user
    IdentityFile ~/.ssh/ec2_tunnel
    RemoteForward 0.0.0.0:8080 localhost:8080
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
    ProxyCommand sh -c "aws ssm start-session --target %h --document-name AWS-StartSSHSession --parameters 'portNumber=%p' --region us-east-1 --profile <aws_profile>"
```

- `HostName` is the instance ID, not an IP address. SSM resolves it.
- `RemoteForward <instance-bind>:<instance-port> <local-host>:<local-port>` sends traffic from port `8080` on the instance to `localhost:8080` on your machine.
- `ec2 tunnel` reads `--profile` and `--region` from the `ProxyCommand` line. It uses them to check your credentials and look up the instance IP.
- For a second tunnel, add another `Host` entry and run `ec2 tunnel <host>`.

**Step 6. Test the connection** once without the tunnel:

```bash
ssh ec2-tunnel 'echo connected'
```

### What `ec2 tunnel` does on each run

1. Checks your AWS credentials, and runs SSO login when the session expired.
2. Refuses to start when a tunnel for the same host already runs on your machine. Two tunnels for one host fight for the same instance port.
3. Kills any `sshd` process on the instance that still holds the forwarded port from a dead tunnel. It kills only `sshd` processes. This step needs passwordless `sudo` for the SSH user, which `ec2-user` on Amazon Linux has. The tunnel still starts if this step fails.
4. Starts `autossh`, which reconnects when the connection drops. Press Ctrl+C to close the tunnel.

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

**`Permission denied (publickey)`**

1. Check that the public key is in `/home/ec2-user/.ssh/authorized_keys` on the instance.
2. Check that `IdentityFile` points to the matching private key.
3. If the key is correct, check the sshd log. Run `ec2 session <instance-id>`, then:

   ```bash
   sudo journalctl -u sshd | grep DenyUsers
   ```

   The line `not allowed because listed in DenyUsers` means the image blocks all SSH logins. No key or IAM permission can fix this.

4. Get approval from the image owner before you continue. This fix turns off a security control. Then allow `ec2-user` only:

   ```bash
   sudo sed -i -E 's/^(DenyUsers|DenyGroups) \*/# &/' /etc/ssh/sshd_config
   echo 'AllowUsers ec2-user' | sudo tee /etc/ssh/sshd_config.d/01-allow-ec2-user.conf
   sudo sshd -t && sudo systemctl restart sshd
   ```

   You must edit `sshd_config` itself. A drop-in file cannot remove `DenyUsers`, because sshd joins all `DenyUsers` lines into one list. The fix lasts until the instance is replaced. For a lasting fix, the image owner must change the image.

**`a tunnel for '<host>' is already running`**
Another `ec2 tunnel` for the same host is still open, maybe in another terminal. Close it with Ctrl+C, or run the `kill <pid>` command that the error shows.

**`remote port forwarding failed`, again and again**
Something on the instance holds the port. Usually it is a dead tunnel session. `ec2 tunnel` tries to clear it at start. If the error stays:

1. Run `ec2 session <instance-id>`.
2. See what holds the port:

   ```bash
   sudo ss -ltnp | grep :<port>
   ```

3. If it is `sshd` or `sshd-session`, kill that process. If it is another program, pick a different port in `RemoteForward`.
4. To stop this from happening again, do [step 4 of the setup](#one-time-setup) (`ClientAliveInterval`).

**`ec2 tunnel` hangs, or `ssh` shows `Connection timed out during banner exchange`**
Too many SSM sessions are open to the instance. Find old processes on your machine, then kill them:

```bash
ps aux | grep -E 'autossh|session-manager-plugin'
```

**Other hosts cannot reach the forwarded port**

1. Check that `RemoteForward` binds to `0.0.0.0`.
2. Do [step 3 of the setup](#one-time-setup) (`GatewayPorts`).
3. Check that the security group allows the port.

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
