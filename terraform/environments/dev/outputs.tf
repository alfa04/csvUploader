output "api_invoke_url" {
  description = "Base URL of the deployed API. Append /uploads, /uploads/{id}, etc."
  value       = module.api_gateway.invoke_url
}

output "cognito_user_pool_id" {
  description = "Pass as the X-Amz-Target ClientMetadata / pool id for Cognito SignUp/InitiateAuth calls."
  value       = module.cognito.user_pool_id
}

output "cognito_client_id" {
  description = "App client id for Cognito SignUp/InitiateAuth calls."
  value       = module.cognito.client_id
}

output "github_actions_role_arn" {
  description = "Role ARN for the GitHub Actions CI workflow to assume."
  value       = module.github_oidc.role_arn
}

output "dashboard_name" {
  value = module.monitoring.dashboard_name
}
