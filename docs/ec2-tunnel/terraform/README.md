# EC2 Tunnel: Terraform

This Terraform creates the AWS resources for the EC2 tunnel, on top of an existing VPC, ALB, and API Gateway. See the [EC2 tunnel guide](../README.md) for how the tunnel works and how developers use it.

It creates:

- The tunnel instance, with no public IP, no SSH key pair, IMDSv2, and an encrypted disk.
- An SSM association that runs [tunnel_setup.sh.tftpl](tunnel_setup.sh.tftpl) on the instance. The script sets up sshd, checks the values that sshd uses, and only then writes the developer keys with their restrictions. `terraform apply` waits for the script, and fails if it fails.
- The instance role and instance profile, with `AmazonSSMManagedInstanceCore`.
- The security group of the instance: the tunnel port from the ALB only, and outbound HTTPS for SSM.
- A target group that holds only the instance, and a listener rule on the existing ALB listener.
- An SSM session document that always connects to port 22 of the instance.
- The IAM policy for developers.

## Use

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars.
terraform init
terraform plan
terraform apply
```

- Configure a backend for the state before you share this setup with a team. The example uses local state.
- A change to `developer_keys` runs the setup script again. A removed key stops only new connections. A tunnel that is already open stays open until it ends.
- A new Amazon Linux release does not replace the instance. To move to the latest AMI, run `terraform apply -replace=aws_instance.tunnel`. The instance ID changes, so developers update `HostName` in `~/.ssh/config`.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.9.0 |
| aws | ~> 6.71 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | ~> 6.71 |
| terraform | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_instance_profile.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_policy.tunnel](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.instance](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.ssm_core](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.tunnel](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_lb_listener_rule.tunnel](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener_rule) | resource |
| [aws_lb_target_group.tunnel](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_lb_target_group_attachment.tunnel](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group_attachment) | resource |
| [aws_security_group.tunnel](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_ssm_association.tunnel_setup](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_association) | resource |
| [aws_ssm_document.ssh](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_document) | resource |
| [aws_vpc_security_group_egress_rule.alb_to_tunnel](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_egress_rule.https](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [aws_vpc_security_group_ingress_rule.tunnel_from_alb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_ingress_rule) | resource |
| [terraform_data.tunnel_setup](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.ec2_trust](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.tunnel](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_ssm_parameter.al2023](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ssm_parameter) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| alb\_listener\_arn | ARN of the ALB listener that API Gateway calls. | `string` | n/a | yes |
| alb\_security\_group\_id | ID of the security group of the ALB. Only this group can reach the tunnel port on the instance. | `string` | n/a | yes |
| developer\_keys | Public SSH key of each developer, by name. The name marks the key on the instance. The value is the key type and the key, without a comment, as in `cut -d' ' -f1,2 ~/.ssh/ec2_tunnel.pub`. A change to this map runs the setup script again. The instance stays the same. An empty map removes every key. | `map(string)` | n/a | yes |
| listener\_rule\_path\_patterns | Path patterns that the listener rule sends to the tunnel, as the ALB sees them. In a private integration, API Gateway adds the stage name to the path, so for the dev stage use ["/dev/dev-tunnel/*"], unless a parameter mapping removes the stage name. Use a path for the tunnel only. A pattern such as /* on a shared listener also takes requests from other rules and from the default action. | `list(string)` | n/a | yes |
| listener\_rule\_priority | Priority of the listener rule that sends requests to the tunnel. It must be unique on the listener. | `number` | n/a | yes |
| region | AWS Region of the VPC, the ALB, and the tunnel instance. | `string` | n/a | yes |
| subnet\_id | ID of a private subnet for the instance. It needs outbound HTTPS to SSM, through a NAT gateway or VPC endpoints. Its Availability Zone must be enabled on the ALB, or the ALB does not send requests to the instance. | `string` | n/a | yes |
| vpc\_id | ID of the VPC of the ALB. | `string` | n/a | yes |
| ami\_id | AMI for the instance. Leave it null to use the latest Amazon Linux 2023 AMI for x86\_64. Another AMI must run the SSM agent and read /etc/ssh/sshd\_config.d/. | `string` | `null` | no |
| create\_alb\_egress\_rule | Add an outbound rule to the ALB security group for the tunnel port. Set it to true when that group does not allow all outbound traffic, and no other Terraform state manages its rules inline. | `bool` | `false` | no |
| health\_check\_matcher | HTTP codes that the ALB health check accepts as healthy. | `string` | `"200-399"` | no |
| health\_check\_path | Path of the ALB health check. The health check goes through the tunnel to the app on the laptop. | `string` | `"/"` | no |
| instance\_type | EC2 instance type. It must match the architecture of the AMI. | `string` | `"t3.micro"` | no |
| name | Name for the resources that this configuration creates. Use letters, digits, and hyphens. | `string` | `"ec2-tunnel"` | no |
| tags | Tags for every resource that this configuration creates. | `map(string)` | `{}` | no |
| tunnel\_port | Port on the instance that the ALB calls, and the port of the app on the laptop. | `number` | `8080` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| developer\_policy\_arn | ARN of the IAM policy that developers need. Attach it to their roles. |
| developer\_policy\_json | The same developer policy as JSON, for an inline policy in an SSO permission set. |
| instance\_id | ID of the tunnel instance. Developers use it as HostName in ~/.ssh/config. |
| security\_group\_id | ID of the security group of the tunnel instance. |
| ssh\_config | Host entry for ~/.ssh/config. Replace <aws\_profile> with the AWS CLI profile of the developer. |
| ssm\_document\_name | Name of the SSM session document that connects to port 22 of the instance. |
| target\_group\_arn | ARN of the target group that holds only the tunnel instance. |
<!-- END_TF_DOCS -->
