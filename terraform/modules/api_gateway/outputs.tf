output "invoke_url" {
  description = "Base URL of the deployed API stage."
  value       = aws_api_gateway_stage.this.invoke_url
}

output "api_key_value" {
  description = "The API key value clients must send as the x-api-key header."
  value       = aws_api_gateway_api_key.this.value
  sensitive   = true
}

output "rest_api_id" {
  value = aws_api_gateway_rest_api.this.id
}

output "api_name" {
  value = aws_api_gateway_rest_api.this.name
}
