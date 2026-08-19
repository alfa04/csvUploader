# Fetches GitHub's current OIDC signing certificate rather than hardcoding a thumbprint -
# thumbprints rotate, and a stale/mistyped one silently breaks CI auth.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

locals {
  github_owner     = split("/", var.github_repo)[0]
  github_repo_name = split("/", var.github_repo)[1]
}

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Accepts both subject formats: the classic repo:OWNER/REPO:ref:... form, and the immutable
    # repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:... form GitHub uses by default for repos created
    # after 2026-07-15 (this one included). Listing both makes this resilient either way.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:ref:refs/heads/${var.github_branch}",
        "repo:${local.github_owner}@${var.github_owner_id}/${local.github_repo_name}@${var.github_repo_id}:ref:refs/heads/${var.github_branch}",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name               = "csvuploader-github-actions-deploy"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy" "deploy_permissions" {
  name   = "csvuploader-github-actions-deploy-permissions"
  role   = aws_iam_role.github_actions_deploy.id
  policy = var.permissions_policy_json
}
