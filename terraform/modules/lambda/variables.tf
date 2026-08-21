variable "function_name" {
  type = string
}

variable "source_dir" {
  description = "Path to the staged build directory for this function (shared/ + its own handler package)."
  type        = string
}

variable "handler" {
  description = "Module path and function name, e.g. 'upload_handler.handler.handler'."
  type        = string
}

variable "runtime" {
  type    = string
  default = "python3.13"
}

variable "role_arn" {
  type = string
}

variable "layer_arns" {
  type    = list(string)
  default = []
}

variable "environment_variables" {
  type    = map(string)
  default = {}
}

variable "timeout" {
  description = "Lambda timeout in seconds."
  type        = number
  default     = 10
}

variable "memory_size" {
  type    = number
  default = 256
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "enable_dlq" {
  description = "Whether to configure an async-invocation failure destination. Only relevant for asynchronously-invoked functions (e.g. the S3-triggered processor) - functions invoked synchronously through API Gateway have no use for it. Kept as a plain bool (rather than inferring it from dlq_target_arn being non-null) because that value comes from a resource created in this same apply and isn't known until apply - count/for_each can't branch on an unknown value."
  type        = bool
  default     = false
}

variable "dlq_target_arn" {
  description = "SQS ARN to route failed async invocations to. Required when enable_dlq is true."
  type        = string
  default     = null
}

variable "git_commit_sha" {
  description = "Full git commit SHA of the code being deployed, applied as a tag so the deployed function is self-describing (check the AWS console/CLI directly, no need to cross-reference git history)."
  type        = string
}
