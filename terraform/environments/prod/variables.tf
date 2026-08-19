variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "throttle_rate_limit" {
  type    = number
  default = 50
}

variable "throttle_burst_limit" {
  type    = number
  default = 100
}

variable "s3_expiration_days" {
  type    = number
  default = 90
}

variable "alert_email" {
  type    = string
  default = null
}
