data "archive_file" "this" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${var.source_dir}.zip"
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${var.function_name}"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "this" {
  function_name    = var.function_name
  filename         = data.archive_file.this.output_path
  source_code_hash = data.archive_file.this.output_base64sha256
  handler          = var.handler
  runtime          = var.runtime
  role             = var.role_arn
  layers           = var.layer_arns
  timeout          = var.timeout
  memory_size      = var.memory_size

  environment {
    variables = var.environment_variables
  }

  tracing_config {
    mode = "Active"
  }

  tags = {
    GitCommit = var.git_commit_sha
  }

  depends_on = [aws_cloudwatch_log_group.this]
}

resource "aws_lambda_function_event_invoke_config" "failure_destination" {
  count = var.enable_dlq ? 1 : 0

  function_name = aws_lambda_function.this.function_name

  destination_config {
    on_failure {
      destination = var.dlq_target_arn
    }
  }
}
