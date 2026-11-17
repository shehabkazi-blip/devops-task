# terraform init -backend-config=envs/staging.backend.hcl -backend-config="bucket=<state_bucket output>"
key          = "devops-task/staging/terraform.tfstate"
region       = "us-west-2"
encrypt      = true
use_lockfile = true # S3-native state locking (no DynamoDB table needed)
