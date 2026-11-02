# EC2 Tunnel: Send API Traffic to Your Laptop

The EC2 tunnel sends API requests to an app that runs on your laptop. You can debug your code while it answers calls that come through the API.

The requests take the normal path: API Gateway, then the Application Load Balancer (ALB), then the EC2 instance. API Gateway accepts calls only from allowed IP ranges, such as your corporate network, and the tunnel does not change that. Use the tunnel in non-production environments only.

The tunnel needs only `aws`, `ssh`, and `autossh` on your laptop. The instance needs no inbound SSH port.

## Contents

1. [How it works](#1-how-it-works)
2. [Why it needs an SSH key](#2-why-it-needs-an-ssh-key)
3. [Before you start](#3-before-you-start)
4. [Required policies](#4-required-policies)
5. [One-time setup](#5-one-time-setup)
6. [Daily use](#6-daily-use)
7. [Limits and safety](#7-limits-and-safety)
8. [Troubleshooting](#8-troubleshooting)

## 1) How it works

![Diagram: a client with an allowed IP calls API Gateway, which sends the request to the ALB, the target group, and sshd on port 8080 of the EC2 instance. sshd sends it through the SSH-over-SSM tunnel that the laptop opened, to the app on localhost:8080 of the developer laptop](images/ec2-tunnel.svg)

**Step A: your laptop opens the tunnel.** `ssh` starts an SSM session to the instance. SSM (AWS Systems Manager Session Manager) carries the connection over outbound HTTPS. The SSM agent on the instance connects it to sshd on port 22. sshd then listens on port `8080` on the instance, and sends what arrives there back to your laptop. This is a remote forward (`RemoteForward` in `~/.ssh/config`).

With the tunnel open, a request takes this path:

1. A client on the corporate network calls the API. API Gateway rejects every call that does not come from an allowed IP range.
2. API Gateway sends the request to the ALB.
3. The ALB sends it to its target group, which points to the EC2 instance on port `8080`.
4. sshd on the instance takes the request on port `8080`.
5. sshd sends the request through the tunnel to `localhost:8080` on your laptop.

The response goes back the same way.

## 2) Why it needs an SSH key

You log in to AWS with SSO, and the tunnel still needs an SSH key. Two parts check two different things:

- **SSM checks your AWS login.** Your IAM role decides if you can open a session to the instance.
- **sshd checks your SSH key.** sshd knows nothing about IAM or SSO. It compares your key with `~/.ssh/authorized_keys` on the instance.

SSM port forwarding alone cannot replace sshd. It sends traffic only from your laptop to the instance. The tunnel needs the other direction, and only sshd can open a remote forward.

## 3) Before you start

### What the environment already has

- API Gateway, with a resource policy that allows only your allowed IP ranges. See [API Gateway resource policy](#api-gateway-resource-policy).
- An ALB behind API Gateway. Clients must not be able to reach the ALB without API Gateway. Restrict the security group of the ALB so that only API Gateway can reach the listener. With a VPC link, allow only the security group of the VPC link. An internal ALB alone is not enough: hosts in the VPC, in a peered VPC, or on a VPN can still reach it. Otherwise a client can skip the IP check.
- A target group on the ALB that holds only the tunnel instance, registered on port `8080`. If the target group holds other targets, the ALB splits requests between them and your laptop.
- An instance that is used only for the tunnel. The sshd changes in the setup apply to every SSH user on the instance.
- A security group on the instance that allows port `8080` from the ALB only, and no inbound SSH.
- The SSM agent on the instance, and an instance role that allows SSM. See [EC2 instance role](#ec2-instance-role).

### Tools on your laptop

| Tool | Install (macOS) |
| --- | --- |
| AWS CLI v2 | `brew install awscli` |
| Session Manager plugin | `brew install --cask session-manager-plugin` |
| OpenSSH client | Included in macOS |
| autossh | `brew install autossh` |

### AWS access

- An AWS CLI profile in `~/.aws/config` for the account of the instance. SSO profiles work.
- Your role can open SSM sessions to the instance with the `AWS-StartSSHSession` document.
- For setup steps 5 and 8 only, your role can run SSM commands (`AWS-RunShellScript`) on the instance.
- See [IAM permissions for developers](#iam-permissions-for-developers) for both policies.

### Placeholders

Replace these values in the examples with your own.

| Placeholder | Meaning |
| --- | --- |
| `i-0123456789abcdef0` | ID of the EC2 instance |
| `us-east-1` | Region of the instance |
| `<account_id>` | ID of the AWS account of the instance |
| `<allowed_cidr_1>`, `<allowed_cidr_2>` | Public IP ranges that may call the API, such as your corporate network, in CIDR form |
| `<instance_role>` | Name of the IAM role and instance profile of the instance |
| `<aws_profile>` | Your AWS CLI profile |
| `<api_url>` | Invoke URL of the API Gateway stage |
| `<key_type>` | SSH key type that your security policy allows |
| `<developer>` | Your short name. It marks your key on the instance, so you can remove it later. It must be unique, and use only ASCII letters, digits, `_`, and `-`. Step 8 uses it as a pattern, so a character such as `.` can also remove the key of another developer. |
| `8080` | Port of the target group, and the port of your app |

## 4) Required policies

The tunnel needs three policies: one on API Gateway, one on the instance, and one for each developer.

### API Gateway resource policy

This resource policy denies every call that does not come from an allowed IP range:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": "*",
      "Action": "execute-api:Invoke",
      "Resource": "execute-api:/*"
    },
    {
      "Effect": "Deny",
      "Principal": "*",
      "Action": "execute-api:Invoke",
      "Resource": "execute-api:/*",
      "Condition": {
        "NotIpAddress": {
          "aws:SourceIp": ["<allowed_cidr_1>", "<allowed_cidr_2>"]
        }
      }
    }
  ]
}
```

- Only REST APIs support resource policies. HTTP APIs do not.
- This policy is for an API without IAM authorization. Such an API rejects every call that no `Allow` matches, so it needs the `Allow` statement. If your API uses IAM authorization, keep its own `Allow` statements and add only the `Deny` statement. An `Allow` for every principal would let any principal in the account call the API.
- An explicit `Deny` always wins over an `Allow`. A call from outside the allowed ranges is rejected with `403 Forbidden`.
- `aws:SourceIp` works only for public IP ranges. This policy is for a public API. For a private API, clients call through a VPC endpoint, and the endpoint replaces the source IP. Then deny calls when `aws:SourceVpce` is not the ID of your trusted endpoint, and use `aws:VpcSourceIp` with the private IP ranges of the clients, not the public ranges.
- Deploy the API again after every change to the resource policy. The change has no effect until you deploy.

### EC2 instance role

The SSM agent on the instance uses this role to connect to SSM. Without it, the instance does not show in SSM, and the tunnel cannot start.

**Trust policy.** It lets EC2 use the role:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "ec2.amazonaws.com" },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

**Permissions.** Attach the AWS managed policy `AmazonSSMManagedInstanceCore`. It gives the SSM agent what it needs for sessions and Run Command, and nothing else.

If the instance has no role yet, save the trust policy as `ec2-trust.json`, and run these commands. They need permission to create IAM roles, which the policies in this guide do not grant. If your role does not have it, ask the account admin to run them:

```bash
aws iam create-role --role-name <instance_role> --assume-role-policy-document file://ec2-trust.json --profile <aws_profile>
aws iam attach-role-policy --role-name <instance_role> --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore --profile <aws_profile>
aws iam create-instance-profile --instance-profile-name <instance_role> --profile <aws_profile>
aws iam add-role-to-instance-profile --instance-profile-name <instance_role> --role-name <instance_role> --profile <aws_profile>
aws ec2 associate-iam-instance-profile --instance-id i-0123456789abcdef0 --iam-instance-profile Name=<instance_role> --region us-east-1 --profile <aws_profile>
```

Check that the instance shows as online in SSM. This can take a few minutes:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=i-0123456789abcdef0" \
  --region us-east-1 \
  --profile <aws_profile> \
  --query 'InstanceInformationList[0].PingStatus'
```

The result must be `"Online"`.

### IAM permissions for developers

Each developer needs these permissions in their role. With SSO, add them to the permission set as an inline policy.

**Tunnel policy.** Every developer needs it. It allows SSH sessions to the tunnel instance only:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "StartSshSessionToTunnelInstance",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": [
        "arn:aws:ec2:us-east-1:<account_id>:instance/i-0123456789abcdef0",
        "arn:aws:ssm:*:*:document/AWS-StartSSHSession"
      ]
    },
    {
      "Sid": "ManageOwnSessions",
      "Effect": "Allow",
      "Action": ["ssm:TerminateSession", "ssm:ResumeSession"],
      "Resource": "arn:aws:ssm:*:*:session/${aws:userid}-*"
    },
    {
      "Sid": "OpenOwnDataChannel",
      "Effect": "Allow",
      "Action": "ssmmessages:OpenDataChannel",
      "Resource": "arn:aws:ssm:*:*:session/${aws:userid}-*"
    }
  ]
}
```

**Setup policy.** Only the [one-time setup](#5-one-time-setup) needs it: the instance owner for steps 2 to 4, and each developer for steps 5 and 8. It allows a shell session and Run Command on the tunnel instance:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ShellSessionToTunnelInstance",
      "Effect": "Allow",
      "Action": "ssm:StartSession",
      "Resource": [
        "arn:aws:ec2:us-east-1:<account_id>:instance/i-0123456789abcdef0",
        "arn:aws:ssm:us-east-1:<account_id>:document/SSM-SessionManagerRunShell"
      ]
    },
    {
      "Sid": "RunShellScriptOnTunnelInstance",
      "Effect": "Allow",
      "Action": "ssm:SendCommand",
      "Resource": [
        "arn:aws:ec2:us-east-1:<account_id>:instance/i-0123456789abcdef0",
        "arn:aws:ssm:us-east-1::document/AWS-RunShellScript"
      ]
    },
    {
      "Sid": "ReadCommandResults",
      "Effect": "Allow",
      "Action": "ssm:GetCommandInvocation",
      "Resource": "*"
    }
  ]
}
```

- `ssm:GetCommandInvocation` reads the result of a command. The setup uses it to wait for Run Command to finish. With `"Resource": "*"`, it can read the output of every Run Command in the account, and that output can hold sensitive data. Give the setup policy only to people who may read that output.
- `${aws:userid}` limits each developer to their own sessions.
- Grant the setup policy only while a person does setup steps 2 to 5 or step 8. Remove it after.

## 5) One-time setup

The setup has two parts:

- **Once for each instance: steps 2 to 4.** The instance owner does them, or someone the owner agrees to. Steps 3 and 4 change sshd on the instance. If the instance is already set up, skip these steps.
- **Once for each developer: steps 1 and 5 to 8.** Every developer does them with their own key, even when the instance is already set up.

### Step 1. Create an SSH key

```bash
ssh-keygen -t <key_type> -f ~/.ssh/ec2_tunnel -C "ec2-tunnel"
```

Use a new key for the tunnel only. Do not reuse a key that is already in `authorized_keys` on the instance. sshd uses the first line that matches a key, so an older line without restrictions would win over the restricted line from step 5.

### Step 2. Check that the image allows SSH logins

Some hardened images block SSH logins with `DenyUsers`, `DenyGroups`, `AllowUsers`, or `AllowGroups`. These rules can be in `/etc/ssh/sshd_config`, in a file in `/etc/ssh/sshd_config.d/`, or in a `Match` block. Open a shell on the instance:

```bash
aws ssm start-session --target i-0123456789abcdef0 --region us-east-1 --profile <aws_profile>
```

Then show the settings that sshd applies to `ec2-user`, from all files:

```bash
sudo sshd -T -C user=ec2-user,host=localhost,addr=127.0.0.1 | grep -E '^(denyusers|denygroups|allowusers|allowgroups) '
```

- No output means no rule blocks `ec2-user`.
- The values are patterns: `*` matches any text, and `?` matches one character. Compare each pattern with `ec2-user` and with its groups. Run `id -Gn ec2-user` to show the groups.
- A `denyusers` or `denygroups` pattern that matches blocks the login. For example, `denyusers *` blocks every SSH login.
- If there is an `allowusers` or `allowgroups` line, one of its patterns must match. For example, `allowusers ec2-*` allows `ec2-user`. If no pattern matches, the login is blocked.

If a rule blocks `ec2-user`, the tunnel cannot work on this instance. Stop here, and ask the image owner for an image that allows SSH logins for `ec2-user`. Do not change these rules yourself. They are a security control of the image.

### Step 3. Let the ALB reach the forwarded port

By default, sshd binds a remote forward to `127.0.0.1` on the instance. The ALB cannot reach that address. `~/.ssh/config` cannot change this, because sshd decides the bind address.

Set up sshd before you add any key. In the instance shell from step 2, turn on `GatewayPorts`, and limit forwarding to remote forwards:

```bash
echo 'GatewayPorts clientspecified' | sudo tee /etc/ssh/sshd_config.d/00-gateway-ports.conf
printf 'AllowTcpForwarding remote\nAllowStreamLocalForwarding no\n' | sudo tee /etc/ssh/sshd_config.d/00-tunnel-forwarding.conf
sudo sshd -t && sudo systemctl restart sshd
```

- `AllowTcpForwarding remote` allows remote forwards only. No key can use `ssh -L` or `ssh -D` to reach other services through the instance.
- `AllowStreamLocalForwarding no` turns off the forwarding of Unix sockets.

sshd uses the first value it reads, so an earlier setting can win over these files. `sshd -t` checks only the syntax. Check the values that sshd uses:

```bash
sudo sshd -T -C user=ec2-user,host=localhost,addr=127.0.0.1 | grep -E '^(gatewayports|allowtcpforwarding|allowstreamlocalforwarding) '
```

The result must be `gatewayports clientspecified`, `allowtcpforwarding remote`, and `allowstreamlocalforwarding no`. If a value is different, find the earlier setting with `sudo grep -rnE 'GatewayPorts|AllowTcpForwarding|AllowStreamLocalForwarding' /etc/ssh/`, and ask the instance owner to remove it.

- The example is for Amazon Linux 2023, which reads `/etc/ssh/sshd_config.d/`.
- `GatewayPorts` applies to every SSH user on the instance. That is why the instance must be used only for the tunnel. The key options from step 5 limit the tunnel key to port `8080`.

### Step 4. Make sshd close dead sessions

When your laptop sleeps or the network drops, the SSM agent does not always close its connection to sshd. sshd then keeps port `8080` open, and new tunnels fail with `remote port forwarding failed`. With these settings, sshd closes a silent session after about 90 seconds:

```bash
printf 'ClientAliveInterval 30\nClientAliveCountMax 3\n' | sudo tee /etc/ssh/sshd_config.d/00-client-alive.conf
sudo sshd -t && sudo systemctl restart sshd
```

As with step 3, an earlier setting can win over this file. Check the values that sshd uses:

```bash
sudo sshd -T -C user=ec2-user,host=localhost,addr=127.0.0.1 | grep -E '^clientalive(interval|countmax) '
```

The result must be `clientaliveinterval 30` and `clientalivecountmax 3`. If a value is different, find the earlier setting with `sudo grep -rn ClientAlive /etc/ssh/`, and ask the instance owner to remove it.

If a check in step 3 or 4 shows a wrong value, stop here, and do not add your key. Otherwise close the instance shell with `exit`, and do steps 5 to 7 in a terminal on your laptop.

### Step 5. Add your public key to the instance

Add the key only after the checks in steps 3 and 4 show the right values. Until then, sshd allows all forwarding, and the key could use `ssh -L` and `ssh -D`. Run the commands in this step in a terminal on your laptop: they read your public key and your AWS profile from there.

The key gets options that allow it to open the tunnel and nothing else:

- `restrict` turns off everything: shell, port forwarding, agent forwarding, and X11.
- `port-forwarding` turns port forwarding back on. Step 3 limits sshd to remote forwards only.
- `permitlisten="0.0.0.0:8080"` allows a remote forward on port `8080` only.
- `command="/bin/false"` stops the key from running commands on the instance.

Build the line for `authorized_keys`. `cut` drops the comment of your key, so a comment with special characters cannot break the command. The `\n` at the start puts the key on a new line, even when the file does not end with a newline. sshd ignores empty lines:

```bash
key_line="restrict,port-forwarding,permitlisten=\"0.0.0.0:8080\",command=\"/bin/false\" $(cut -d' ' -f1,2 ~/.ssh/ec2_tunnel.pub) ec2-tunnel-<developer>"
key_b64=$(printf '\n%s\n' "$key_line" | base64 | tr -d '\n')
```

Add the line to the instance with SSM Run Command, so you need no SSH access. `set -e` stops the script at the first command that fails, so the result is `Success` only when every command worked:

```bash
command_id=$(aws ssm send-command \
  --instance-ids i-0123456789abcdef0 \
  --document-name AWS-RunShellScript \
  --region us-east-1 \
  --profile <aws_profile> \
  --parameters "commands=[\"set -e\",\"mkdir -p /home/ec2-user/.ssh\",\"echo ${key_b64} | base64 -d >> /home/ec2-user/.ssh/authorized_keys\",\"chown -R ec2-user:ec2-user /home/ec2-user/.ssh\",\"chmod 700 /home/ec2-user/.ssh\",\"chmod 600 /home/ec2-user/.ssh/authorized_keys\"]" \
  --query 'Command.CommandId' \
  --output text)
```

Run Command runs in the background. Wait until it finishes, then check the result:

```bash
aws ssm wait command-executed \
  --command-id "$command_id" \
  --instance-id i-0123456789abcdef0 \
  --region us-east-1 \
  --profile <aws_profile>
aws ssm get-command-invocation \
  --command-id "$command_id" \
  --instance-id i-0123456789abcdef0 \
  --region us-east-1 \
  --profile <aws_profile> \
  --query 'Status' \
  --output text
```

The result must be `Success`. If the wait fails, or the result is not `Success`, stop and check the command output in the SSM console.

### Step 6. Add a `Host` entry to `~/.ssh/config`

```text
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

- `HostName` is the instance ID, not an IP address. The `ProxyCommand` passes it to SSM.
- `RemoteForward 0.0.0.0:8080 localhost:8080` sends traffic from port `8080` on the instance to `localhost:8080` on your laptop.
- `ServerAliveInterval` and `ServerAliveCountMax` make `ssh` exit when the connection is dead. autossh then reconnects.
- `ExitOnForwardFailure` makes `ssh` exit when sshd cannot open port `8080`, instead of running without a tunnel.

### Step 7. Test the connection

Log in to AWS if your credentials are not valid, then open the tunnel once with debug output:

```bash
aws sts get-caller-identity --profile <aws_profile> || aws sso login --profile <aws_profile>
ssh -v -N ec2-tunnel
```

The output must show a line that starts with `debug1: remote forward success`. Then close it with Ctrl+C.

The key cannot run commands on the instance, so `ssh ec2-tunnel <command>` does not work. Use an SSM shell for any check on the instance.

### Step 8. Remove your key when you stop using the tunnel

Stopping the tunnel does not remove your key. When you no longer need the tunnel, remove the key from the instance. Run this on your laptop:

```bash
command_id=$(aws ssm send-command \
  --instance-ids i-0123456789abcdef0 \
  --document-name AWS-RunShellScript \
  --region us-east-1 \
  --profile <aws_profile> \
  --parameters "commands=[\"set -e\",\"sed -i '/ ec2-tunnel-<developer>$/d' /home/ec2-user/.ssh/authorized_keys\"]" \
  --query 'Command.CommandId' \
  --output text)
```

Wait for this command and check its result with the `wait` and `get-command-invocation` commands from step 5. The result must be `Success`.

## 6) Daily use

**1. Start your app** on `localhost:8080`, and check it:

```bash
curl -i http://localhost:8080/
```

**2. Log in to AWS** if your SSO session expired:

```bash
aws sts get-caller-identity --profile <aws_profile> || aws sso login --profile <aws_profile>
```

**3. Check that no other tunnel runs on your laptop.** Two tunnels for one host fight for port `8080` on the instance:

```bash
pgrep -fl 'autossh .* ec2-tunnel$'
```

If the command prints a process, close that tunnel first.

**4. Start the tunnel:**

```bash
AUTOSSH_GATETIME=0 autossh -M 0 -N ec2-tunnel
```

- `-N` opens the tunnel and runs no command. The terminal shows nothing while the tunnel works.
- `-M 0` turns off the autossh monitor port. `ServerAliveInterval` finds dead connections instead.
- `AUTOSSH_GATETIME=0` makes autossh retry even when the first connection fails.

If `ssh` shows `remote port forwarding failed`, another tunnel holds port `8080`. See [Troubleshooting](#tunnel).

**5. Test the full path** from a machine on the corporate network:

```bash
curl -i <api_url>/
```

The request must show up in the log of your app.

**6. Stop the tunnel** with Ctrl+C when you are done.

## 7) Limits and safety

- **Non-production only.** Requests from the API reach your laptop. Do not use the tunnel for production traffic or production data.
- **One developer at a time.** Only one tunnel can hold port `8080` on the instance. Agree with your team who uses it.
- **No tunnel means errors.** When no tunnel is up, nothing listens on port `8080`, and the ALB returns `502 Bad Gateway`.
- **Health checks reach your laptop.** The ALB sends its health checks through the tunnel. Make your app answer the health check path, or the target shows as unhealthy.
- **Keep port `8080` closed to everything except the ALB.** After step 3, sshd listens on all addresses of the instance. The security group is what stops other hosts from reaching your laptop.
- **Anyone with the tunnel policy can reach an open tunnel.** `AWS-StartSSHSession` accepts any port in `portNumber`. A developer with the tunnel policy can open an SSM session to port `8080` on the instance, with no SSH key. While a tunnel is open, that session reaches the app on the laptop of the developer who opened it, and skips API Gateway and the ALB. Give the tunnel policy only to developers who may reach each other's tunnels.
- **Close the tunnel when you are done.** An open tunnel keeps a session open to the instance.

## 8) Troubleshooting

### Tunnel

**`Permission denied (publickey)`**

1. Check that your public key is in `/home/ec2-user/.ssh/authorized_keys` on the instance.
2. Check that `IdentityFile` points to the matching private key.
3. If the key is correct, check the sshd log in an SSM shell on the instance:

   ```bash
   sudo journalctl -u sshd | grep 'not allowed because'
   ```

   A line such as `not allowed because listed in DenyUsers` means a rule of the image blocks the login. No key or IAM permission can fix this. Ask the image owner for an image that allows SSH logins. See [step 2 of the setup](#step-2-check-that-the-image-allows-ssh-logins).

**`AccessDeniedException` when calling `StartSession` or `SendCommand`**

Your role is missing a permission. Check that your role has the policies in [IAM permissions for developers](#iam-permissions-for-developers).

**`remote port forwarding failed for listen port 8080`**

Something on the instance holds port `8080`. It can be another developer's tunnel, or a dead session of your own.

1. Ask your team if someone else has a tunnel open. If they do, wait until they close it. Do not stop their session.
2. If nobody has a tunnel open, it is a dead session. sshd closes it within about 90 seconds after [step 4 of the setup](#step-4-make-sshd-close-dead-sessions). Wait, then start the tunnel again.
3. If the error stays, ask the instance owner to check the port in an SSM shell with `sudo ss -ltnp 'sport = :8080'`. Only the instance owner decides whether to stop the process.

**`ssh` hangs, or shows `Connection timed out during banner exchange`**

Too many SSM sessions are open to the instance. Find old processes on your laptop, then kill them:

```bash
ps aux | grep -E 'autossh|session-manager-plugin'
```

**`SessionManagerPlugin is not found`**

Install the Session Manager plugin. See [Tools on your laptop](#tools-on-your-laptop).

**`An error occurred (ExpiredTokenException)` or `Token has expired`**

Your SSO session expired. Run `aws sso login --profile <aws_profile>`, then start the tunnel again.

### API

**`403 Forbidden` from API Gateway**

The call did not come from an allowed IP range. API Gateway rejects these calls by design, through its [resource policy](#api-gateway-resource-policy). Call the API from a machine on the corporate network.

**`502 Bad Gateway`**

The ALB cannot get a response on port `8080`. Check these in order:

1. The tunnel runs, and shows no errors.
2. Your app runs on `localhost:8080`.
3. sshd listens on `0.0.0.0:8080`, not on `127.0.0.1:8080`. Run `sudo ss -ltnp 'sport = :8080'` in a shell on the instance. If it shows `127.0.0.1`, do [step 3 of the setup](#step-3-let-the-alb-reach-the-forwarded-port), then restart the tunnel.
4. The security group of the instance allows port `8080` from the ALB.

**`503 Service Unavailable`**

The target group has no registered target. Ask the instance owner to register the instance on port `8080`.

**Only some `curl <api_url>/` requests reach your laptop**

The target group holds other targets too, and the ALB sends part of the requests to them. The target group must hold only the tunnel instance. See [What the environment already has](#what-the-environment-already-has).

**`504 Gateway Timeout`**

Your app took too long to answer. API Gateway and the ALB each have a time limit for a response. Make the request faster, or check that your app is not stopped in a debugger.
