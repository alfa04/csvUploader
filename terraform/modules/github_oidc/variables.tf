variable "github_repo" {
  description = "GitHub 'org/repo' allowed to assume this role via OIDC, e.g. 'alfa04/csvUploader'."
  type        = string
}

variable "github_branch" {
  description = "Branch allowed to assume this role - only pushes to this branch can deploy."
  type        = string
  default     = "main"
}

# Repos created after 2026-07-15 use GitHub's immutable OIDC subject format
# (repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:...) instead of the older repo:OWNER/REPO:ref:... form.
# Find these via: curl https://api.github.com/repos/<owner>/<repo> | jq '.owner.id, .id'
variable "github_owner_id" {
  description = "Numeric GitHub owner (user/org) ID, for the immutable subject claim format."
  type        = string
}

variable "github_repo_id" {
  description = "Numeric GitHub repository ID, for the immutable subject claim format."
  type        = string
}

variable "permissions_policy_json" {
  description = "JSON policy document (from data.aws_iam_policy_document) granting exactly what CI needs: Terraform state backend access plus managing this environment's resources."
  type        = string
}
