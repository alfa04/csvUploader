variable "uploads_table_name" {
  description = "Name of the DynamoDB table storing upload metadata/status."
  type        = string
}

variable "records_table_name" {
  description = "Name of the DynamoDB table storing parsed CSV rows."
  type        = string
}

variable "enable_point_in_time_recovery" {
  description = "Whether to enable DynamoDB point-in-time recovery on both tables."
  type        = bool
  default     = true
}
