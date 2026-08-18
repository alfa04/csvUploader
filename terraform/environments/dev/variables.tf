variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "github_repo" {
  description = "GitHub 'org/repo' allowed to deploy this environment via CI OIDC."
  type        = string
  default     = "alfa04/csvUploader"
}

variable "github_branch" {
  type    = string
  default = "main"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "throttle_rate_limit" {
  type    = number
  default = 10
}

variable "throttle_burst_limit" {
  type    = number
  default = 20
}

variable "quota_limit" {
  type    = number
  default = 10000
}

variable "s3_expiration_days" {
  type    = number
  default = 90
}

variable "alert_email" {
  type    = string
  default = null
}
