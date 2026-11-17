data "aws_caller_identity" "current" {}
data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Latest Ubuntu 24.04 LTS AMI published by Canonical (public SSM parameter, works in any region).
# `ignore_changes = [ami]` below stops a new AMI release from replacing a running instance.
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

locals {
  name        = "${var.project}-${var.environment}"
  log_group   = "/${var.project}/${var.environment}/app"
  grafana_ssm = "/${var.project}/${var.environment}/grafana_admin_password"
}

# ---- Network: only what is needed. No SSH: shell access is via SSM Session Manager. ----
resource "aws_security_group" "app" {
  name        = "${local.name}-sg"
  description = "App (8080) and Grafana (3000, admin IPs only)"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "app" {
  for_each          = toset(var.app_ingress_cidrs)
  security_group_id = aws_security_group.app.id
  description       = "App"
  from_port         = 8080
  to_port           = 8080
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "grafana" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.app.id
  description       = "Grafana (admin only)"
  from_port         = 3000
  to_port           = 3000
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- Logs with explicit retention ----
resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

# ---- Compute ----
resource "aws_instance" "app" {
  ami                         = nonsensitive(data.aws_ssm_parameter.ubuntu.value)
  instance_type               = var.instance_type
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # containers cannot reach instance credentials
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  user_data = templatefile("${path.module}/userdata.sh.tftpl", {
    repo_url    = var.repo_url
    repo_branch = var.repo_branch
    ecr_repo    = var.ecr_repository_url
    region      = var.region
    environment = var.environment
    log_group   = local.log_group
    grafana_ssm = local.grafana_ssm
  })

  tags = { Name = local.name }

  lifecycle {
    ignore_changes = [ami, user_data] # deploys happen through CI, not instance replacement
  }
}

resource "aws_eip" "app" {
  instance = aws_instance.app.id
  domain   = "vpc"
  tags     = { Name = local.name }
}
