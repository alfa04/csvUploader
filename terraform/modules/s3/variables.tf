variable "bucket_name" {
  description = "Name of the S3 bucket for raw CSV uploads."
  type        = string
}

variable "expiration_days" {
  description = "Number of days after which raw uploaded CSVs are automatically deleted."
  type        = number
  default     = 90
}
