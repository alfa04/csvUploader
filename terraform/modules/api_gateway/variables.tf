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

variable "throttle_rate_limit" {
  description = "Steady-state requests per second allowed."
  type        = number
  default     = 10
}

variable "throttle_burst_limit" {
  description = "Concurrent request burst allowed."
  type        = number
  default     = 20
}

variable "quota_limit" {
  description = "Maximum requests allowed per quota_period."
  type        = number
  default     = 10000
}

variable "quota_period" {
  type    = string
  default = "DAY"
}

variable "log_retention_days" {
  type    = number
  default = 30
}
