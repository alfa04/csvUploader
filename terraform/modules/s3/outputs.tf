output "bucket_name" {
  description = "Name of the raw-uploads S3 bucket."
  value       = aws_s3_bucket.raw_uploads.id
}

output "bucket_arn" {
  description = "ARN of the raw-uploads S3 bucket."
  value       = aws_s3_bucket.raw_uploads.arn
}
