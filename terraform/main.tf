data "aws_caller_identity" "current" {}
data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

locals {
  name        = "${var.project}-${var.environment}"
  log_group   = "/${var.project}/${var.environment}/app"
  grafana_ssm = "/${var.project}/${var.environment}/grafana_admin_password"
}

# --- Key Pair ---
# আপনার লোকাল মেশিনের এসএসএইচ কি (id_ed25519.pub) এডব্লিউএস-এ রেজিস্টার করার জন্য
resource "aws_key_pair" "deployer" {
  key_name   = "${local.name}-local-key"
  public_key = file("~/.ssh/id_ed25519.pub")
}

# --- Network ---
resource "aws_security_group" "app" {
  name        = "${local.name}-sg"
  description = "App (8080) and Grafana (3000) allowed globally"
  vpc_id      = data.aws_vpc.default.id
}

# Port 8080 Inbound Rule (App)
resource "aws_vpc_security_group_ingress_rule" "app" {
  security_group_id = aws_security_group.app.id
  description       = "App"
  from_port         = 8080
  to_port           = 8080
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

# Port 3000 Inbound Rule (Grafana - সবার জন্য উন্মুক্ত করা হয়েছে)
resource "aws_vpc_security_group_ingress_rule" "grafana" {
  security_group_id = aws_security_group.app.id
  description       = "Grafana (public access)"
  from_port         = 3000
  to_port           = 3000
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.app.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# --- Logs with explicit retention ---
resource "aws_cloudwatch_log_group" "app" {
  name              = local.log_group
  retention_in_days = var.log_retention_days
}

# --- Compute ---
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "app" {
  ami                         = data.aws_ssm_parameter.ubuntu.value
  instance_type               = var.instance_type
  subnet_id                   = sort(data.aws_subnets.default.ids)[0]
  vpc_security_group_ids      = [aws_security_group.app.id]
  iam_instance_profile        = aws_iam_instance_profile.app.name
  associate_public_ip_address = true
  key_name                    = aws_key_pair.deployer.key_name

  metadata_options {
    http_tokens               = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_gb
    encrypted   = true
  }

  user_data = templatefile("${path.module}/userdata.sh.tftpl", {
    repo_url        = var.repo_url
    repo_branch     = var.repo_branch
    ecr_repo        = var.ecr_repository_url
    region          = var.region
    environment     = var.environment
    log_group       = local.log_group
    grafana_ssm     = local.grafana_ssm
  })

  tags = { Name = local.name }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# Port 22 Inbound Rule (SSH)
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.app.id
  description       = "SSH access"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_eip" "app" {
  instance   = aws_instance.app.id
  domain     = "vpc"
  tags       = { Name = local.name }
}
