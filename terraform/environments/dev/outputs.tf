output "api_invoke_url" {
  description = "Base URL of the deployed API. Append /uploads, /uploads/{id}, etc."
  value       = module.api_gateway.invoke_url
}

output "cognito_user_pool_id" {
  description = "Cognito user pool ID. Not needed for the sign-up/sign-in flow itself (that only needs the client id) - useful for admin operations against the pool via the AWS CLI or console."
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

output "frontend_url" {
  description = "CloudFront URL serving the dashboard frontend."
  value       = "https://${module.frontend_hosting.cloudfront_domain_name}"
}

output "frontend_bucket_name" {
  description = "S3 bucket the frontend's built assets are synced to."
  value       = module.frontend_hosting.bucket_name
}

output "frontend_cloudfront_distribution_id" {
  description = "CloudFront distribution id, needed to invalidate its cache after a deploy."
  value       = module.frontend_hosting.cloudfront_distribution_id
}
