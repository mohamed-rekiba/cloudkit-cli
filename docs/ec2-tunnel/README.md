# EC2 Tunnel: Send API Traffic to Your Laptop

The EC2 tunnel sends API requests to an app that runs on your laptop. You can debug your code while it answers calls that come through the API.

The requests take the normal path: API Gateway, then a VPC link, then the Application Load Balancer (ALB), then the EC2 instance. API Gateway accepts calls only from allowed IP ranges, such as your corporate network, and the tunnel does not change that. Use the tunnel in non-production environments only.

The tunnel needs only `aws`, `ssh`, and `autossh` on your laptop. The instance needs no inbound SSH port.

## Contents

1. [How it works](#1-how-it-works)
2. [Why it needs an SSH key](#2-why-it-needs-an-ssh-key)
3. [Deploy the AWS resources](#3-deploy-the-aws-resources)
4. [Developer setup](#4-developer-setup)
5. [Daily use](#5-daily-use)
6. [Limits and safety](#6-limits-and-safety)
7. [Troubleshooting](#7-troubleshooting)

## 1) How it works

![Diagram: a client with an allowed IP calls API Gateway, which sends the request through a VPC link to the ALB, the target group, and sshd on port 8080 of the EC2 instance. sshd sends it through the SSH-over-SSM tunnel that the laptop opened, to the app on localhost:8080 of the developer laptop](images/ec2-tunnel.svg)

**Step A: your laptop opens the tunnel.** `ssh` starts an SSM session to the instance. SSM (AWS Systems Manager Session Manager) carries the connection over outbound HTTPS. The SSM agent on the instance connects it to sshd on port 22. sshd then listens on port `8080` on the instance, and sends what arrives there back to your laptop. This is a remote forward (`RemoteForward` in `~/.ssh/config`).

With the tunnel open, a request takes this path:

1. A client on the corporate network calls the API. API Gateway rejects every call that does not come from an allowed IP range.
2. API Gateway sends the request through a VPC link to the ALB, inside the VPC.
3. The ALB sends it to its target group, which points to the EC2 instance on port `8080`.
4. sshd on the instance takes the request on port `8080`.
5. sshd sends the request through the tunnel to `localhost:8080` on your laptop.

The response goes back the same way.

## 2) Why it needs an SSH key

You log in to AWS with SSO, and the tunnel still needs an SSH key. Two parts check two different things:

- **SSM checks your AWS login.** Your IAM role decides if you can open a session to the instance.
- **sshd checks your SSH key.** sshd knows nothing about IAM or SSO. It compares your key with `~/.ssh/authorized_keys` on the instance.

SSM port forwarding alone cannot replace sshd. It sends traffic only from your laptop to the instance. The tunnel needs the other direction, and only sshd can open a remote forward.

## 3) Deploy the AWS resources

The instance owner does this part once for each environment. Developers skip to [Developer setup](#4-developer-setup).

### What must already exist

- **API Gateway** (REST API), with a resource policy that allows only your allowed IP ranges. See [API Gateway resource policy](#api-gateway-resource-policy).
- **A VPC link from API Gateway to an ALB.** The security group of the ALB must allow only the security group of the VPC link, so that every request comes through API Gateway. An internal ALB alone is not enough: hosts in the VPC, in a peered VPC, or on a VPN can still reach it and skip the IP check.
- **A private subnet** with outbound HTTPS to SSM, through a NAT gateway or VPC endpoints. Its Availability Zone must be enabled on the ALB, or the ALB does not send requests to the instance.
- **An API resource for the tunnel**, such as `/dev-tunnel/{proxy+}`, with a private integration through the VPC link.
- **A path for the tunnel only**, or a listener for the tunnel only. The listener rule sends only this path to the tunnel. A pattern such as `/*` on a shared listener would also take requests meant for other targets.
- **The path that the ALB sees.** In a private integration, API Gateway adds the stage name to the path. For the `dev` stage, a call to `/dev-tunnel/orders` reaches the ALB as `/dev/dev-tunnel/orders`. Set `listener_rule_path_patterns` to that path, such as `/dev/dev-tunnel/*`. Or remove the stage name with a parameter mapping that overrides `$context.requestOverride.path`, and match the path without it.

### Terraform

[terraform/](terraform/) creates everything else: the instance and its role, its security group, a target group that holds only the instance, a listener rule, an SSM session document, and the developer policy. An SSM association sets up sshd on the instance and writes the developer keys. See [terraform/README.md](terraform/README.md) for every input and output.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: the network, the ALB, and one public key for each developer.
terraform init
terraform apply
```

`terraform apply` waits for the setup script on the instance, and fails if the script fails. The script checks the values that sshd will use before it restarts sshd and writes any key. If a check fails, it does not restart sshd, and it removes every key.

After the apply:

1. Give each developer the policy from the `developer_policy_arn` output. With SSO, add the `developer_policy_json` output to the permission set as an inline policy.
2. Give developers the `ssh_config` output. It is the `Host` entry for [step 3 of the developer setup](#step-3-add-the-host-entry).

**Add or remove a developer:** change `developer_keys` in `terraform.tfvars`, and run `terraform apply`. The instance stays the same. The script writes the whole `authorized_keys` file again, so it holds only the keys in the map. An empty map removes every key.

### API Gateway resource policy

The API already exists, so the Terraform does not change it. This resource policy denies every call that does not come from an allowed IP range:

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

- Replace `<allowed_cidr_1>` and `<allowed_cidr_2>` with the public IP ranges that may call the API, such as your corporate network, in CIDR form.
- The `Allow` statement is for an API without IAM authorization. If your API uses IAM authorization, keep its own `Allow` statements and add only the `Deny` statement.
- For a private API, deny calls when `aws:SourceVpce` is not the ID of your trusted VPC endpoint, and use `aws:VpcSourceIp` with the private IP ranges of the clients.
- Deploy the API again after every change to the resource policy. The change has no effect until you deploy.

## 4) Developer setup

Do these steps once. You need the policy from the instance owner, and these tools:

| Tool | Install (macOS) |
| --- | --- |
| AWS CLI v2 | `brew install awscli` |
| Session Manager plugin | `brew install --cask session-manager-plugin` |
| OpenSSH client | Included in macOS |
| autossh | `brew install autossh` |

### Step 1. Create an SSH key

```bash
ssh-keygen -t <key_type> -f ~/.ssh/ec2_tunnel -C "ec2-tunnel"
```

Replace `<key_type>` with a key type that your security policy allows, such as `ed25519`. Use a new key for the tunnel only.

### Step 2. Send your public key to the instance owner

```bash
cut -d' ' -f1,2 ~/.ssh/ec2_tunnel.pub
```

Send the output and a short name to the instance owner. The name marks your key on the instance. It must be unique, and use only ASCII letters, digits, `_`, and `-`. The owner adds both to `developer_keys` and runs `terraform apply`.

### Step 3. Add the Host entry

Add the `ssh_config` output from the instance owner to `~/.ssh/config`. Replace `<aws_profile>` with your AWS CLI profile for the account of the instance. It looks like this:

```text
Host ec2-tunnel
    HostName i-0123456789abcdef0
    User ec2-user
    IdentityFile ~/.ssh/ec2_tunnel
    RemoteForward 0.0.0.0:8080 localhost:8080
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ExitOnForwardFailure yes
    ProxyCommand sh -c "aws ssm start-session --target %h --document-name ec2-tunnel-ssh --region us-east-1 --profile <aws_profile>"
```

- `HostName` is the instance ID, not an IP address. The `ProxyCommand` passes it to SSM.
- `--document-name ec2-tunnel-ssh` is the session document from the Terraform. It always connects to port 22 of the instance.
- `RemoteForward 0.0.0.0:8080 localhost:8080` sends traffic from port `8080` on the instance to `localhost:8080` on your laptop.
- `ServerAliveInterval` and `ServerAliveCountMax` make `ssh` exit when the connection is dead. autossh then reconnects.
- `ExitOnForwardFailure` makes `ssh` exit when sshd cannot open port `8080`, instead of running without a tunnel.

### Step 4. Test the connection

```bash
aws sts get-caller-identity --profile <aws_profile> || aws sso login --profile <aws_profile>
ssh -v -N ec2-tunnel
```

The output must show a line that starts with `debug1: remote forward success`. Then close it with Ctrl+C.

The key cannot run commands on the instance, so `ssh ec2-tunnel <command>` does not work.

## 5) Daily use

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

If `ssh` shows `remote port forwarding failed`, another tunnel holds port `8080`. Stop autossh with Ctrl+C right away. autossh keeps retrying, and takes the port as soon as the other tunnel closes. API traffic then goes to your laptop without notice. Agree with your team who uses the tunnel before you start it again. See [Troubleshooting](#tunnel).

**5. Test the full path** from a machine on the corporate network:

```bash
curl -i <api_url>/dev-tunnel/
```

Replace `<api_url>` with the invoke URL of the API Gateway stage, and `/dev-tunnel/` with the API resource for the tunnel. The request must show up in the log of your app.

**6. Stop the tunnel** with Ctrl+C when you are done.

## 6) Limits and safety

- **Non-production only.** Requests from the API reach your laptop. Do not use the tunnel for production traffic or production data.
- **One developer at a time.** Only one tunnel can hold port `8080` on the instance. Agree with your team who uses it.
- **No tunnel means errors.** When no tunnel is up, nothing listens on port `8080`, and the ALB returns `502 Bad Gateway`.
- **Health checks reach your laptop.** The ALB sends its health checks through the tunnel. Make your app answer the health check path, or the target shows as unhealthy.
- **The instance is for the tunnel only.** The sshd settings apply to every SSH user on it: `GatewayPorts clientspecified`, remote forwards only, and no Unix socket forwards. Each key can open a remote forward on port `8080` only, and cannot run commands.
- **Port `8080` stays closed to everything except the ALB.** sshd listens on all addresses of the instance. The security group is what stops other hosts from reaching your laptop.
- **The developer policy allows SSH sessions only.** It allows the Terraform session document, which always connects to port 22. It does not allow `AWS-StartSSHSession` or other documents that accept a port, so a developer cannot reach port `8080` through SSM without the SSH key.
- **Close the tunnel when you are done.** An open tunnel keeps a session open to the instance.

## 7) Troubleshooting

### Tunnel

**`Permission denied (publickey)`**

1. Check with the instance owner that your key is in `developer_keys`, and that `terraform apply` ran after the change.
2. Check that `IdentityFile` points to the matching private key.

**`AccessDeniedException` when calling `StartSession`**

Your role is missing the developer policy, or the `ProxyCommand` uses another document than the one in the `ssm_document_name` output. Ask the instance owner.

**`remote port forwarding failed for listen port 8080`**

Something on the instance holds port `8080`. It can be another developer's tunnel, or a dead session of your own.

1. Stop your autossh with Ctrl+C first, so that it does not take the port when it becomes free.
2. Ask your team if someone else has a tunnel open. If they do, wait until they close it, and agree who uses the tunnel next. Do not stop their session.
3. If nobody has a tunnel open, it is a dead session. sshd closes it within about 90 seconds. Wait, then start the tunnel again.
4. If the error stays, ask the instance owner to check the port on the instance with `sudo ss -ltnp 'sport = :8080'`. Only the instance owner decides whether to stop the process.

**`ssh` hangs, or shows `Connection timed out during banner exchange`**

Too many SSM sessions are open to the instance. Find old processes on your laptop, then kill them:

```bash
ps aux | grep -E 'autossh|session-manager-plugin'
```

**`SessionManagerPlugin is not found`**

Install the Session Manager plugin. See [Developer setup](#4-developer-setup).

**`An error occurred (ExpiredTokenException)` or `Token has expired`**

Your SSO session expired. Run `aws sso login --profile <aws_profile>`, then start the tunnel again.

### API

**`403 Forbidden` from API Gateway**

The call did not come from an allowed IP range. API Gateway rejects these calls by design, through its [resource policy](#api-gateway-resource-policy). Call the API from a machine on the corporate network.

**`502 Bad Gateway`**

The ALB cannot get a response on port `8080`. Check these in order:

1. The tunnel runs, and shows no errors.
2. Your app runs on `localhost:8080`.
3. The security group of the ALB allows outbound traffic to the instance on port `8080`. If it does not, the instance owner sets `create_alb_egress_rule = true` in the Terraform.

**`curl <api_url>/dev-tunnel/` does not reach your laptop, and the tunnel shows no errors**

The listener rule does not match the path that the ALB sees, so the ALB sends the request to its default action. API Gateway adds the stage name to the path, so for the `dev` stage the ALB sees `/dev/dev-tunnel/...`. Ask the instance owner to check `listener_rule_path_patterns`. See [What must already exist](#what-must-already-exist).

**`504 Gateway Timeout`**

Your app took too long to answer. API Gateway and the ALB each have a time limit for a response. Make the request faster, or check that your app is not stopped in a debugger.

### Terraform apply

**`terraform apply` fails while it waits for the SSM association**

The setup script failed on the instance, or the SSM agent did not come online. Open the association in the SSM console (State Manager), and read the output of the last run. A line that starts with `ec2-tunnel: sshd would not use` means an earlier sshd setting on the image wins over the Terraform file. Use the default Amazon Linux 2023 AMI, or ask the image owner to remove that setting.
