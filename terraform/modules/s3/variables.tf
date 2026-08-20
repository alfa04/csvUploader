variable "bucket_name" {
  description = "Name of the S3 bucket for raw CSV uploads."
  type        = string
}

variable "expiration_days" {
  description = "Number of days after which raw uploaded CSVs are automatically deleted."
  type        = number
  default     = 90
}

variable "cors_allowed_origins" {
  description = "Origins allowed to make cross-origin browser requests (POST) to this bucket. Empty list disables CORS entirely - the default, since prod has no frontend yet."
  type        = list(string)
  default     = []
}
