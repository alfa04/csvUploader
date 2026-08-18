resource "aws_dynamodb_table" "uploads" {
  name         = var.uploads_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "upload_id"

  attribute {
    name = "upload_id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }
}

resource "aws_dynamodb_table" "records" {
  name         = var.records_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "upload_id"
  range_key    = "row_number"

  attribute {
    name = "upload_id"
    type = "S"
  }

  attribute {
    name = "row_number"
    type = "N"
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }
}
