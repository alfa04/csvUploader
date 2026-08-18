variable "environment" {
  type = string
}

variable "lambda_function_names" {
  description = "Map of logical name => actual Lambda function name, for per-function error/throttle alarms and the dashboard."
  type        = map(string)
}

variable "api_gateway_name" {
  type = string
}

variable "dlq_queue_name" {
  type = string
}

variable "alert_email" {
  description = "Email to subscribe to the alerts SNS topic. Null means the topic/alarms exist but nothing is subscribed yet."
  type        = string
  default     = null
}
