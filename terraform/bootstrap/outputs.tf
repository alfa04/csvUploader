output "state_bucket_name" {
  description = "S3 bucket holding Terraform state for all environments."
  value       = aws_s3_bucket.terraform_state.id
}

output "aws_region" {
  description = "AWS region the state backend resources were created in."
  value       = var.aws_region
}
