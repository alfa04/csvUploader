output "api_invoke_url" {
  description = "Base URL of the deployed API. Append /uploads, /uploads/{id}, etc."
  value       = module.api_gateway.invoke_url
}

output "api_key_value" {
  description = "Value to send as the x-api-key header. Fetch with: terraform output -raw api_key_value"
  value       = module.api_gateway.api_key_value
  sensitive   = true
}

output "dashboard_name" {
  value = module.monitoring.dashboard_name
}
