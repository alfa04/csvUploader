variable "environment" {
  type = string
}

variable "upload_handler_function_name" {
  type = string
}

variable "upload_handler_invoke_arn" {
  type = string
}

variable "status_handler_function_name" {
  type = string
}

variable "status_handler_invoke_arn" {
  type = string
}

variable "records_handler_function_name" {
  type = string
}

variable "records_handler_invoke_arn" {
  type = string
}

variable "cognito_user_pool_arn" {
  description = "ARN of the Cognito User Pool that authenticates callers."
  type        = string
}

variable "throttle_rate_limit" {
  description = "Steady-state requests per second allowed (blanket stage-level throttle)."
  type        = number
  default     = 10
}

variable "throttle_burst_limit" {
  description = "Concurrent request burst allowed (blanket stage-level throttle)."
  type        = number
  default     = 20
}

variable "log_retention_days" {
  type    = number
  default = 30
}
