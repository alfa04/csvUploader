output "uploads_table_name" {
  value = aws_dynamodb_table.uploads.name
}

output "uploads_table_arn" {
  value = aws_dynamodb_table.uploads.arn
}

output "records_table_name" {
  value = aws_dynamodb_table.records.name
}

output "records_table_arn" {
  value = aws_dynamodb_table.records.arn
}
