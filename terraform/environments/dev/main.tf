data "aws_caller_identity" "current" {}

locals {
  name_prefix = "csvuploader-${var.environment}"
  build_dir   = "${path.root}/../../../build"
}

# --- Storage ---

module "s3" {
  source = "../../modules/s3"

  bucket_name     = "${local.name_prefix}-raw-uploads-${data.aws_caller_identity.current.account_id}"
  expiration_days = var.s3_expiration_days
}

module "dynamodb" {
  source = "../../modules/dynamodb"

  uploads_table_name = "${local.name_prefix}-uploads"
  records_table_name = "${local.name_prefix}-records"
}

resource "aws_sqs_queue" "process_handler_dlq" {
  name                      = "${local.name_prefix}-process-dlq"
  sqs_managed_sse_enabled   = true
  message_retention_seconds = 1209600 # 14 days (SQS max) - ample time to notice and investigate
}

# --- Shared Lambda dependency layer: aws-lambda-powertools + boto3/botocore pinned to the exact
# versions tested locally (see scripts/build_lambda_packages.sh) ---

data "archive_file" "dependencies_layer" {
  type        = "zip"
  source_dir  = "${local.build_dir}/layer"
  output_path = "${local.build_dir}/layer.zip"
}

resource "aws_lambda_layer_version" "dependencies" {
  layer_name          = "${local.name_prefix}-dependencies"
  filename            = data.archive_file.dependencies_layer.output_path
  source_code_hash    = data.archive_file.dependencies_layer.output_base64sha256
  compatible_runtimes = ["python3.13"]
}

# --- IAM: one least-privilege execution role per function ---

data "aws_iam_policy_document" "upload_handler_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem"]
    resources = [module.dynamodb.uploads_table_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${module.s3.bucket_arn}/raw/*"]
  }
}

module "iam_upload_handler" {
  source = "../../modules/iam"

  function_name      = "${local.name_prefix}-upload-handler"
  inline_policy_json = data.aws_iam_policy_document.upload_handler_permissions.json
}

data "aws_iam_policy_document" "process_handler_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:UpdateItem"]
    resources = [module.dynamodb.uploads_table_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:PutItem", "dynamodb:BatchWriteItem"]
    resources = [module.dynamodb.records_table_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${module.s3.bucket_arn}/raw/*"]
  }

  # Lambda validates this at the time the async-invocation failure destination is configured -
  # without it, PutFunctionEventInvokeConfig itself fails.
  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.process_handler_dlq.arn]
  }
}

module "iam_process_handler" {
  source = "../../modules/iam"

  function_name      = "${local.name_prefix}-process-handler"
  inline_policy_json = data.aws_iam_policy_document.process_handler_permissions.json
}

data "aws_iam_policy_document" "status_handler_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem"]
    resources = [module.dynamodb.uploads_table_arn]
  }
}

module "iam_status_handler" {
  source = "../../modules/iam"

  function_name      = "${local.name_prefix}-status-handler"
  inline_policy_json = data.aws_iam_policy_document.status_handler_permissions.json
}

data "aws_iam_policy_document" "records_handler_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem"]
    resources = [module.dynamodb.uploads_table_arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:Query"]
    resources = [module.dynamodb.records_table_arn]
  }
}

module "iam_records_handler" {
  source = "../../modules/iam"

  function_name      = "${local.name_prefix}-records-handler"
  inline_policy_json = data.aws_iam_policy_document.records_handler_permissions.json
}

# --- Lambda functions ---

module "lambda_upload_handler" {
  source = "../../modules/lambda"

  function_name      = "${local.name_prefix}-upload-handler"
  source_dir         = "${local.build_dir}/functions/upload_handler"
  handler            = "upload_handler.handler.handler"
  role_arn           = module.iam_upload_handler.role_arn
  layer_arns         = [aws_lambda_layer_version.dependencies.arn]
  log_retention_days = var.log_retention_days

  environment_variables = {
    UPLOADS_TABLE_NAME = module.dynamodb.uploads_table_name
    UPLOAD_BUCKET_NAME = module.s3.bucket_name
  }
}

module "lambda_process_handler" {
  source = "../../modules/lambda"

  function_name      = "${local.name_prefix}-process-handler"
  source_dir         = "${local.build_dir}/functions/process_handler"
  handler            = "process_handler.handler.handler"
  role_arn           = module.iam_process_handler.role_arn
  layer_arns         = [aws_lambda_layer_version.dependencies.arn]
  timeout            = 300
  memory_size        = 512
  log_retention_days = var.log_retention_days
  enable_dlq         = true
  dlq_target_arn     = aws_sqs_queue.process_handler_dlq.arn

  environment_variables = {
    UPLOADS_TABLE_NAME = module.dynamodb.uploads_table_name
    RECORDS_TABLE_NAME = module.dynamodb.records_table_name
  }
}

module "lambda_status_handler" {
  source = "../../modules/lambda"

  function_name      = "${local.name_prefix}-status-handler"
  source_dir         = "${local.build_dir}/functions/status_handler"
  handler            = "status_handler.handler.handler"
  role_arn           = module.iam_status_handler.role_arn
  layer_arns         = [aws_lambda_layer_version.dependencies.arn]
  log_retention_days = var.log_retention_days

  environment_variables = {
    UPLOADS_TABLE_NAME = module.dynamodb.uploads_table_name
  }
}

module "lambda_records_handler" {
  source = "../../modules/lambda"

  function_name      = "${local.name_prefix}-records-handler"
  source_dir         = "${local.build_dir}/functions/records_handler"
  handler            = "records_handler.handler.handler"
  role_arn           = module.iam_records_handler.role_arn
  layer_arns         = [aws_lambda_layer_version.dependencies.arn]
  log_retention_days = var.log_retention_days

  environment_variables = {
    UPLOADS_TABLE_NAME = module.dynamodb.uploads_table_name
    RECORDS_TABLE_NAME = module.dynamodb.records_table_name
  }
}

# --- S3 -> process_handler trigger ---

resource "aws_lambda_permission" "s3_invoke_process_handler" {
  statement_id  = "AllowS3InvokeProcessHandler"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda_process_handler.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = module.s3.bucket_arn
}

resource "aws_s3_bucket_notification" "raw_uploads" {
  bucket = module.s3.bucket_name

  lambda_function {
    lambda_function_arn = module.lambda_process_handler.function_arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "raw/"
  }

  depends_on = [aws_lambda_permission.s3_invoke_process_handler]
}

# --- API Gateway ---

module "api_gateway" {
  source = "../../modules/api_gateway"

  environment = var.environment

  upload_handler_function_name  = module.lambda_upload_handler.function_name
  upload_handler_invoke_arn     = module.lambda_upload_handler.invoke_arn
  status_handler_function_name  = module.lambda_status_handler.function_name
  status_handler_invoke_arn     = module.lambda_status_handler.invoke_arn
  records_handler_function_name = module.lambda_records_handler.function_name
  records_handler_invoke_arn    = module.lambda_records_handler.invoke_arn

  throttle_rate_limit  = var.throttle_rate_limit
  throttle_burst_limit = var.throttle_burst_limit
  quota_limit          = var.quota_limit
  log_retention_days   = var.log_retention_days
}

# --- Monitoring ---

module "monitoring" {
  source = "../../modules/monitoring"

  environment = var.environment

  lambda_function_names = {
    upload-handler  = module.lambda_upload_handler.function_name
    process-handler = module.lambda_process_handler.function_name
    status-handler  = module.lambda_status_handler.function_name
    records-handler = module.lambda_records_handler.function_name
  }

  api_gateway_name = module.api_gateway.api_name
  dlq_queue_name   = aws_sqs_queue.process_handler_dlq.name
  alert_email      = var.alert_email
}

# --- CI/CD: GitHub Actions OIDC deploy role (dev only - CI never touches prod) ---
#
# The "ManageDevResources" statement below is scoped by our "csvuploader-dev*" naming
# convention rather than to exact resource ARNs, since Terraform itself creates those resources
# and their ARNs aren't knowable ahead of time. iam:PassRole is the one statement kept tightly
# scoped regardless, since it's the classic privilege-escalation vector if left broad. This
# policy gets exercised for the first time in Milestone 7 (CI/CD) - expect to refine it then if
# CI surfaces a missing permission.

data "aws_iam_policy_document" "github_actions_deploy_permissions" {
  statement {
    sid    = "TerraformStateBackend"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::csvuploader-tfstate-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::csvuploader-tfstate-${data.aws_caller_identity.current.account_id}/dev/*",
    ]
  }

  statement {
    sid       = "TerraformStateLock"
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = ["arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.current.account_id}:table/csvuploader-tfstate-lock"]
  }

  statement {
    sid    = "ManageDevResources"
    effect = "Allow"
    actions = [
      "dynamodb:*",
      "s3:*",
      "lambda:*",
      "logs:*",
      "sqs:*",
      "sns:*",
      "cloudwatch:*",
      "iam:GetRole",
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:TagRole",
      "iam:GetRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:CreateOpenIDConnectProvider",
      "iam:GetOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint",
      "iam:TagOpenIDConnectProvider",
    ]
    resources = [
      "arn:aws:dynamodb:*:*:table/csvuploader-dev*",
      "arn:aws:s3:::csvuploader-dev*",
      "arn:aws:s3:::csvuploader-dev*/*",
      "arn:aws:lambda:*:*:function:csvuploader-dev*",
      "arn:aws:lambda:*:*:layer:csvuploader-dev*",
      "arn:aws:logs:*:*:log-group:/aws/lambda/csvuploader-dev*",
      "arn:aws:logs:*:*:log-group:/aws/apigateway/csvuploader-dev*",
      "arn:aws:sqs:*:*:csvuploader-dev*",
      "arn:aws:sns:*:*:csvuploader-dev*",
      "arn:aws:cloudwatch:*:*:alarm:csvuploader-dev*",
      "arn:aws:cloudwatch::*:dashboard/csvuploader-dev",
      # The deploy role manages its own role/policy too (e.g. this very policy document, and
      # trust-policy updates), not just the app's csvuploader-dev* resources.
      "arn:aws:iam::*:role/csvuploader-dev*",
      "arn:aws:iam::*:role/csvuploader-github-actions-deploy",
      "arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com",
    ]
  }

  # logs:DescribeLogGroups doesn't support resource-level permissions - AWS requires "*" for it
  # regardless of naming, unlike the other CloudWatch Logs actions above.
  statement {
    sid       = "LogsDescribe"
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "PassLambdaExecutionRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::*:role/csvuploader-dev*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["lambda.amazonaws.com"]
    }
  }

  # API Gateway's management API isn't scoped by resource-name-prefixable ARNs the way the
  # other services are, and splits resources across several top-level paths (REST APIs, API
  # keys, and usage plans are each separate from one another, not nested under /restapis).
  statement {
    sid     = "ManageApiGateway"
    effect  = "Allow"
    actions = ["apigateway:*"]
    resources = [
      "arn:aws:apigateway:*::/restapis*",
      "arn:aws:apigateway:*::/apikeys*",
      "arn:aws:apigateway:*::/usageplans*",
    ]
  }
}

module "github_oidc" {
  source = "../../modules/github_oidc"

  github_repo             = var.github_repo
  github_branch           = var.github_branch
  github_owner_id         = var.github_owner_id
  github_repo_id          = var.github_repo_id
  permissions_policy_json = data.aws_iam_policy_document.github_actions_deploy_permissions.json
}
