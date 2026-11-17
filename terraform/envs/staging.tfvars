environment        = "staging"
instance_type      = "t3.small"
log_retention_days = 7

# --- EDIT THESE ---
github_repo        = "YOUR_GITHUB_USER/YOUR_REPO"
repo_url           = "https://github.com/YOUR_GITHUB_USER/YOUR_REPO.git"
admin_cidrs        = ["203.0.113.10/32"] # your public IP: curl -s https://checkip.amazonaws.com
ecr_repository_url = "123456789012.dkr.ecr.us-west-2.amazonaws.com/devops-task"
ecr_repository_arn = "arn:aws:ecr:us-west-2:123456789012:repository/devops-task"
