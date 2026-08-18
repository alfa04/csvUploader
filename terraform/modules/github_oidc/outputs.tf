output "role_arn" {
  description = "Role ARN for GitHub Actions to assume via aws-actions/configure-aws-credentials."
  value       = aws_iam_role.github_actions_deploy.arn
}
