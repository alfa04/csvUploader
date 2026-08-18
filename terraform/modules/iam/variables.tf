variable "function_name" {
  description = "Name of the Lambda function this role is for (used to name the role)."
  type        = string
}

variable "inline_policy_json" {
  description = "JSON policy document (from data.aws_iam_policy_document) granting this function's specific permissions, on top of basic execution + X-Ray."
  type        = string
}
