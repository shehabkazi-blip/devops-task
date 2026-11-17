output "instance_id" { value = aws_instance.app.id }
output "public_ip" { value = aws_eip.app.public_ip }
output "app_url" { value = "http://${aws_eip.app.public_ip}:8080" }
output "grafana_url" { value = "http://${aws_eip.app.public_ip}:3000" }
output "log_group" { value = aws_cloudwatch_log_group.app.name }
output "deploy_role_arn" { value = aws_iam_role.deploy.arn }
output "grafana_ssm_parameter" { value = local.grafana_ssm }
