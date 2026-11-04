output "instance_id" {
  description = "ID of the tunnel instance. Developers use it as HostName in ~/.ssh/config."
  value       = aws_instance.tunnel.id
}

output "ssm_document_name" {
  description = "Name of the SSM session document that connects to port 22 of the instance."
  value       = aws_ssm_document.ssh.name
}

output "target_group_arn" {
  description = "ARN of the target group that holds only the tunnel instance."
  value       = aws_lb_target_group.tunnel.arn
}

output "security_group_id" {
  description = "ID of the security group of the tunnel instance."
  value       = aws_security_group.tunnel.id
}

output "developer_policy_arn" {
  description = "ARN of the IAM policy that developers need. Attach it to their roles."
  value       = aws_iam_policy.tunnel.arn
}

output "developer_policy_json" {
  description = "The same developer policy as JSON, for an inline policy in an SSO permission set."
  value       = data.aws_iam_policy_document.tunnel.json
}

output "ssh_config" {
  description = "Host entry for ~/.ssh/config. Replace <aws_profile> with the AWS CLI profile of the developer."
  value       = <<-EOT
    Host ${var.name}
        HostName ${aws_instance.tunnel.id}
        User ec2-user
        IdentityFile ~/.ssh/ec2_tunnel
        RemoteForward 0.0.0.0:${var.tunnel_port} localhost:${var.tunnel_port}
        ServerAliveInterval 30
        ServerAliveCountMax 3
        ExitOnForwardFailure yes
        ProxyCommand sh -c "aws ssm start-session --target %h --document-name ${aws_ssm_document.ssh.name} --region ${local.region} --profile <aws_profile>"
  EOT
}
