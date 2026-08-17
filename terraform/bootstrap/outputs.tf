output "state_bucket_name" {
  description = "S3 bucket holding Terraform state for all environments."
  value       = aws_s3_bucket.terraform_state.id
}

output "lock_table_name" {
  description = "DynamoDB table used for Terraform state locking."
  value       = aws_dynamodb_table.terraform_lock.name
}

output "aws_region" {
  description = "AWS region the state backend resources were created in."
  value       = var.aws_region
}
