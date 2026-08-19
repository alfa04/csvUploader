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

# See terraform/modules/github_oidc/variables.tf for why these are needed.
variable "github_owner_id" {
  type    = string
  default = "7761589"
}

variable "github_repo_id" {
  type    = string
  default = "1338629019"
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

variable "s3_expiration_days" {
  type    = number
  default = 90
}

variable "alert_email" {
  type    = string
  default = null
}
