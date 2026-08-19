variable "name_prefix" {
  description = "Prefix for the user pool/client names, e.g. csvuploader-dev."
  type        = string
}

variable "password_minimum_length" {
  description = "Minimum password length enforced by the Cognito user pool's password policy."
  type        = number
  default     = 8
}

variable "deletion_protection" {
  description = "Whether the user pool can be deleted. Set to \"ACTIVE\" in prod."
  type        = string
  default     = "INACTIVE"
}
