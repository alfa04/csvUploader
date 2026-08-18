variable "github_repo" {
  description = "GitHub 'org/repo' allowed to assume this role via OIDC, e.g. 'alfa04/csvUploader'."
  type        = string
}

variable "github_branch" {
  description = "Branch allowed to assume this role - only pushes to this branch can deploy."
  type        = string
  default     = "main"
}

variable "permissions_policy_json" {
  description = "JSON policy document (from data.aws_iam_policy_document) granting exactly what CI needs: Terraform state backend access plus managing this environment's resources."
  type        = string
}
