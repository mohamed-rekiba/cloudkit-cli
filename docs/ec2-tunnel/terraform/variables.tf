variable "region" {
  description = "AWS Region of the VPC, the ALB, and the tunnel instance."
  type        = string
}

variable "name" {
  description = "Name for the resources that this configuration creates. Use letters, digits, and hyphens."
  type        = string
  default     = "ec2-tunnel"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]{0,19}$", var.name))
    error_message = "name must be 1 to 20 letters, digits, or hyphens, and start with a letter or digit."
  }
}

variable "vpc_id" {
  description = "ID of the VPC of the ALB."
  type        = string
}

variable "subnet_id" {
  description = "ID of a private subnet for the instance. It needs outbound HTTPS to SSM, through a NAT gateway or VPC endpoints. Its Availability Zone must be enabled on the ALB, or the ALB does not send requests to the instance."
  type        = string
}

variable "alb_security_group_id" {
  description = "ID of the security group of the ALB. Only this group can reach the tunnel port on the instance."
  type        = string
}

variable "create_alb_egress_rule" {
  description = "Add an outbound rule to the ALB security group for the tunnel port. Set it to true when that group does not allow all outbound traffic, and no other Terraform state manages its rules inline."
  type        = bool
  default     = false
}

variable "alb_listener_arn" {
  description = "ARN of the ALB listener that API Gateway calls."
  type        = string
}

variable "listener_rule_priority" {
  description = "Priority of the listener rule that sends requests to the tunnel. It must be unique on the listener."
  type        = number

  validation {
    condition     = var.listener_rule_priority >= 1 && var.listener_rule_priority <= 50000
    error_message = "listener_rule_priority must be from 1 to 50000."
  }
}

variable "listener_rule_path_patterns" {
  description = "Path patterns that the listener rule sends to the tunnel, as the ALB sees them. In a private integration, API Gateway adds the stage name to the path, so for the dev stage use [\"/dev/dev-tunnel/*\"], unless a parameter mapping removes the stage name. Use a path for the tunnel only. A pattern such as /* on a shared listener also takes requests from other rules and from the default action."
  type        = list(string)

  validation {
    condition     = length(var.listener_rule_path_patterns) > 0
    error_message = "listener_rule_path_patterns must hold at least one path pattern."
  }
}

variable "tunnel_port" {
  description = "Port on the instance that the ALB calls, and the port of the app on the laptop."
  type        = number
  default     = 8080

  validation {
    condition     = var.tunnel_port >= 1024 && var.tunnel_port <= 65535
    error_message = "tunnel_port must be from 1024 to 65535."
  }
}

variable "health_check_path" {
  description = "Path of the ALB health check. The health check goes through the tunnel to the app on the laptop."
  type        = string
  default     = "/"
}

variable "health_check_matcher" {
  description = "HTTP codes that the ALB health check accepts as healthy."
  type        = string
  default     = "200-399"
}

variable "ami_id" {
  description = "AMI for the instance. Leave it null to use the latest Amazon Linux 2023 AMI for x86_64. Another AMI must run the SSM agent and read /etc/ssh/sshd_config.d/."
  type        = string
  default     = null
}

variable "instance_type" {
  description = "EC2 instance type. It must match the architecture of the AMI."
  type        = string
  default     = "t3.micro"
}

variable "developer_keys" {
  description = "Public SSH key of each developer, by name. The name marks the key on the instance. The value is the key type and the key, without a comment, as in `cut -d' ' -f1,2 ~/.ssh/ec2_tunnel.pub`. A change to this map runs the setup script again. The instance stays the same. An empty map removes every key."
  type        = map(string)

  validation {
    condition     = alltrue([for name in keys(var.developer_keys) : can(regex("^[A-Za-z0-9_-]{1,64}$", name))])
    error_message = "Each developer name must be 1 to 64 ASCII letters, digits, underscores, or hyphens."
  }

  validation {
    condition     = alltrue([for key in values(var.developer_keys) : can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\\.com|sk-ecdsa-sha2-nistp256@openssh\\.com) [A-Za-z0-9+/]+={0,3}$", key))])
    error_message = "Each key must be a key type and a base64 key, separated by one space, with no comment."
  }
}

variable "tags" {
  description = "Tags for every resource that this configuration creates."
  type        = map(string)
  default     = {}
}
