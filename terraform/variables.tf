variable "region" {
  type    = string
  default = "us-west-2"
}

variable "project" {
  type    = string
  default = "devops-task"
}

variable "environment" {
  type        = string
  description = "staging or production. Must match the GitHub environment name."
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be 'staging' or 'production'."
  }
}

variable "instance_type" {
  type        = string
  description = "t3.small is the minimum that runs app + full monitoring stack; t3.micro (free tier) will OOM."
}

variable "root_volume_gb" {
  type    = number
  default = 30
}

variable "app_ingress_cidrs" {
  type        = list(string)
  default     = ["0.0.0.0/0"]
  description = "Who may reach the app on 8080"
}

variable "admin_cidrs" {
  type        = list(string)
  description = "Who may reach Grafana on 3000 (your public IP, /32). Never 0.0.0.0/0."
  validation {
    condition     = alltrue([for c in var.admin_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "admin_cidrs must be valid CIDRs and must not be 0.0.0.0/0."
  }
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "ecr_repository_url" {
  type        = string
  description = "From bootstrap output"
}

variable "ecr_repository_arn" {
  type        = string
  description = "From bootstrap output"
}

variable "github_repo" {
  type        = string
  description = "owner/repo; allowed to assume the deploy role for this environment"
}

variable "repo_url" {
  type        = string
  description = "Public HTTPS clone URL of the repo (compose + observability config live there)"
}

variable "repo_branch" {
  type    = string
  default = "main"
}
