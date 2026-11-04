data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == null ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region
  ami_id     = var.ami_id != null ? var.ami_id : data.aws_ssm_parameter.al2023[0].insecure_value
}

# ---------------------------------------------------------------
# Network: only the ALB reaches the tunnel port, and the instance
# reaches out only on HTTPS, for SSM.
# ---------------------------------------------------------------

resource "aws_security_group" "tunnel" {
  name_prefix = "${var.name}-"
  description = "EC2 tunnel instance: tunnel port from the ALB only, no inbound SSH"
  vpc_id      = var.vpc_id

  tags = {
    Name = var.name
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "tunnel_from_alb" {
  security_group_id            = aws_security_group.tunnel.id
  description                  = "Tunnel port from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = var.tunnel_port
  to_port                      = var.tunnel_port
  referenced_security_group_id = var.alb_security_group_id
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.tunnel.id
  description       = "HTTPS to SSM"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_tunnel" {
  count = var.create_alb_egress_rule ? 1 : 0

  security_group_id            = var.alb_security_group_id
  description                  = "ALB to the tunnel port of the EC2 tunnel instance"
  ip_protocol                  = "tcp"
  from_port                    = var.tunnel_port
  to_port                      = var.tunnel_port
  referenced_security_group_id = aws_security_group.tunnel.id
}

# ---------------------------------------------------------------
# Instance role: the SSM agent uses it to connect to SSM.
# ---------------------------------------------------------------

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name_prefix        = "${var.name}-"
  description        = "EC2 tunnel instance: lets the SSM agent connect to SSM"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.instance.name
}

# ---------------------------------------------------------------
# Instance: the association below sets it up, so a change to the
# developer keys does not replace it, and its ID stays the same.
# ---------------------------------------------------------------

resource "aws_instance" "tunnel" {
  ami                         = local.ami_id
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.tunnel.id]
  iam_instance_profile        = aws_iam_instance_profile.instance.name
  associate_public_ip_address = false
  ebs_optimized               = true
  monitoring                  = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    encrypted   = true
    volume_type = "gp3"
  }

  tags = {
    Name = var.name
  }

  lifecycle {
    # A new Amazon Linux release would otherwise replace the instance on
    # the next apply. To move to the latest AMI, replace the instance with
    # terraform apply -replace=aws_instance.tunnel.
    ignore_changes = [ami]
  }
}

# The setup script, and what it runs on. A change to either one creates
# the association again, so that apply waits for the script to succeed.
locals {
  tunnel_setup_script = templatefile("${path.module}/tunnel_setup.sh.tftpl", {
    developer_keys = var.developer_keys
    tunnel_port    = var.tunnel_port
  })
}

resource "terraform_data" "tunnel_setup" {
  input = {
    instance_id = aws_instance.tunnel.id
    script      = sha256(local.tunnel_setup_script)
  }
}

resource "aws_ssm_association" "tunnel_setup" {
  name                             = "AWS-RunShellScript"
  association_name                 = "${var.name}-setup"
  wait_for_success_timeout_seconds = 900

  targets {
    key    = "InstanceIds"
    values = [aws_instance.tunnel.id]
  }

  parameters = {
    commands = local.tunnel_setup_script
  }

  lifecycle {
    replace_triggered_by = [terraform_data.tunnel_setup]
  }
}

# ---------------------------------------------------------------
# ALB: a target group that holds only the tunnel instance.
# ---------------------------------------------------------------

resource "aws_lb_target_group" "tunnel" {
  #checkov:skip=CKV_AWS_378:TLS ends at the ALB. The ALB calls the instance inside the VPC, and sshd forwards plain TCP to the app on the laptop.
  name        = "${var.name}-${var.tunnel_port}"
  port        = var.tunnel_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    enabled  = true
    path     = var.health_check_path
    matcher  = var.health_check_matcher
    port     = "traffic-port"
    protocol = "HTTP"
  }
}

resource "aws_lb_target_group_attachment" "tunnel" {
  target_group_arn = aws_lb_target_group.tunnel.arn
  target_id        = aws_instance.tunnel.id
  port             = var.tunnel_port
}

resource "aws_lb_listener_rule" "tunnel" {
  listener_arn = var.alb_listener_arn
  priority     = var.listener_rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tunnel.arn
  }

  condition {
    path_pattern {
      values = var.listener_rule_path_patterns
    }
  }
}

# ---------------------------------------------------------------
# SSH over SSM: a session document that always connects to port 22,
# and the policy that developers need.
# ---------------------------------------------------------------

resource "aws_ssm_document" "ssh" {
  name            = "${var.name}-ssh"
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "SSH to the EC2 tunnel instance. The port is fixed to 22."
    sessionType   = "Port"
    properties = {
      portNumber = "22"
    }
  })
}

data "aws_iam_policy_document" "tunnel" {
  statement {
    sid     = "StartSshSessionToTunnelInstance"
    effect  = "Allow"
    actions = ["ssm:StartSession"]
    resources = [
      aws_instance.tunnel.arn,
      aws_ssm_document.ssh.arn,
    ]

    condition {
      test     = "BoolIfExists"
      variable = "ssm:SessionDocumentAccessCheck"
      values   = ["true"]
    }
  }

  statement {
    sid       = "ManageOwnSessions"
    effect    = "Allow"
    actions   = ["ssm:TerminateSession", "ssm:ResumeSession"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:session/$${aws:userid}-*"]
  }

  statement {
    sid       = "OpenOwnDataChannel"
    effect    = "Allow"
    actions   = ["ssmmessages:OpenDataChannel"]
    resources = ["arn:${local.partition}:ssm:${local.region}:${local.account_id}:session/$${aws:userid}-*"]
  }
}

resource "aws_iam_policy" "tunnel" {
  name_prefix = "${var.name}-developer-"
  description = "EC2 tunnel: SSH sessions over SSM to the tunnel instance only"
  policy      = data.aws_iam_policy_document.tunnel.json
}
