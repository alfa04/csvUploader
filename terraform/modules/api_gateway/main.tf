resource "aws_api_gateway_rest_api" "this" {
  name = "csvuploader-${var.environment}"
}

# /uploads
resource "aws_api_gateway_resource" "uploads" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "uploads"
}

# /uploads/{upload_id}
resource "aws_api_gateway_resource" "upload_id" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.uploads.id
  path_part   = "{upload_id}"
}

# /uploads/{upload_id}/records
resource "aws_api_gateway_resource" "records" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.upload_id.id
  path_part   = "records"
}

# --- POST /uploads -> upload_handler ---

resource "aws_api_gateway_method" "post_uploads" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.uploads.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "post_uploads" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.uploads.id
  http_method             = aws_api_gateway_method.post_uploads.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.upload_handler_invoke_arn
}

resource "aws_lambda_permission" "post_uploads" {
  statement_id  = "AllowAPIGatewayInvokeUploadHandler"
  action        = "lambda:InvokeFunction"
  function_name = var.upload_handler_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/${aws_api_gateway_method.post_uploads.http_method}${aws_api_gateway_resource.uploads.path}"
}

# --- GET /uploads/{upload_id} -> status_handler ---

resource "aws_api_gateway_method" "get_upload_status" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.upload_id.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = true

  request_parameters = {
    "method.request.path.upload_id" = true
  }
}

resource "aws_api_gateway_integration" "get_upload_status" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.upload_id.id
  http_method             = aws_api_gateway_method.get_upload_status.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.status_handler_invoke_arn
}

resource "aws_lambda_permission" "get_upload_status" {
  statement_id  = "AllowAPIGatewayInvokeStatusHandler"
  action        = "lambda:InvokeFunction"
  function_name = var.status_handler_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/${aws_api_gateway_method.get_upload_status.http_method}${aws_api_gateway_resource.upload_id.path}"
}

# --- GET /uploads/{upload_id}/records -> records_handler ---

resource "aws_api_gateway_method" "get_records" {
  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.records.id
  http_method      = "GET"
  authorization    = "NONE"
  api_key_required = true

  request_parameters = {
    "method.request.path.upload_id" = true
  }
}

resource "aws_api_gateway_integration" "get_records" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.records.id
  http_method             = aws_api_gateway_method.get_records.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.records_handler_invoke_arn
}

resource "aws_lambda_permission" "get_records" {
  statement_id  = "AllowAPIGatewayInvokeRecordsHandler"
  action        = "lambda:InvokeFunction"
  function_name = var.records_handler_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/${aws_api_gateway_method.get_records.http_method}${aws_api_gateway_resource.records.path}"
}

# --- Deployment / stage ---

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.uploads.id,
      aws_api_gateway_resource.upload_id.id,
      aws_api_gateway_resource.records.id,
      aws_api_gateway_method.post_uploads.id,
      aws_api_gateway_method.get_upload_status.id,
      aws_api_gateway_method.get_records.id,
      aws_api_gateway_integration.post_uploads.id,
      aws_api_gateway_integration.get_upload_status.id,
      aws_api_gateway_integration.get_records.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "access_logs" {
  name              = "/aws/apigateway/csvuploader-${var.environment}"
  retention_in_days = var.log_retention_days
}

resource "aws_api_gateway_stage" "this" {
  deployment_id        = aws_api_gateway_deployment.this.id
  rest_api_id          = aws_api_gateway_rest_api.this.id
  stage_name           = var.environment
  xray_tracing_enabled = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access_logs.arn
    format = jsonencode({
      requestId               = "$context.requestId"
      sourceIp                = "$context.identity.sourceIp"
      requestTime             = "$context.requestTime"
      httpMethod              = "$context.httpMethod"
      resourcePath            = "$context.resourcePath"
      status                  = "$context.status"
      protocol                = "$context.protocol"
      responseLength          = "$context.responseLength"
      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_api_gateway_method_settings" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled        = true
    logging_level          = "INFO"
    data_trace_enabled     = false # avoid logging request/response bodies (may contain upload data)
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }
}

# --- API key / usage plan (our chosen auth mechanism - see docs/adr) ---

resource "aws_api_gateway_api_key" "this" {
  name = "csvuploader-${var.environment}-key"
}

resource "aws_api_gateway_usage_plan" "this" {
  name = "csvuploader-${var.environment}-usage-plan"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    rate_limit  = var.throttle_rate_limit
    burst_limit = var.throttle_burst_limit
  }

  quota_settings {
    limit  = var.quota_limit
    period = var.quota_period
  }
}

resource "aws_api_gateway_usage_plan_key" "this" {
  key_id        = aws_api_gateway_api_key.this.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.this.id
}
