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

resource "aws_api_gateway_authorizer" "cognito" {
  name          = "csvuploader-${var.environment}-cognito"
  rest_api_id   = aws_api_gateway_rest_api.this.id
  type          = "COGNITO_USER_POOLS"
  provider_arns = [var.cognito_user_pool_arn]
}

# --- POST /uploads -> upload_handler ---

resource "aws_api_gateway_method" "post_uploads" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.uploads.id
  http_method   = "POST"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
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

# --- GET /uploads -> list_handler ---

resource "aws_api_gateway_method" "list_uploads" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.uploads.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id
}

resource "aws_api_gateway_integration" "list_uploads" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.uploads.id
  http_method             = aws_api_gateway_method.list_uploads.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.list_handler_invoke_arn
}

resource "aws_lambda_permission" "list_uploads" {
  statement_id  = "AllowAPIGatewayInvokeListHandler"
  action        = "lambda:InvokeFunction"
  function_name = var.list_handler_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/${aws_api_gateway_method.list_uploads.http_method}${aws_api_gateway_resource.uploads.path}"
}

# --- GET /uploads/{upload_id} -> status_handler ---

resource "aws_api_gateway_method" "get_upload_status" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.upload_id.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

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
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.records.id
  http_method   = "GET"
  authorization = "COGNITO_USER_POOLS"
  authorizer_id = aws_api_gateway_authorizer.cognito.id

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

# --- CORS preflight (OPTIONS) on every resource - browsers preflight any request carrying a
# non-safelisted header (every request here carries Authorization), and MOCK-integration OPTIONS
# is the standard way to answer that without invoking Lambda. Access-Control-Allow-Origin is "*"
# here (matching the real responses' header in shared/http.py) since auth is a bearer token, not
# a cookie - there's no CSRF exposure a wildcard origin would create. ---

resource "aws_api_gateway_method" "options_uploads" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.uploads.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_uploads" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.uploads.id
  http_method = aws_api_gateway_method.options_uploads.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "options_uploads" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.uploads.id
  http_method = aws_api_gateway_method.options_uploads.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_uploads" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.uploads.id
  http_method = aws_api_gateway_method.options_uploads.http_method
  status_code = aws_api_gateway_method_response.options_uploads.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.options_uploads]
}

resource "aws_api_gateway_method" "options_upload_id" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.upload_id.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_upload_id" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.upload_id.id
  http_method = aws_api_gateway_method.options_upload_id.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "options_upload_id" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.upload_id.id
  http_method = aws_api_gateway_method.options_upload_id.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_upload_id" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.upload_id.id
  http_method = aws_api_gateway_method.options_upload_id.http_method
  status_code = aws_api_gateway_method_response.options_upload_id.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.options_upload_id]
}

resource "aws_api_gateway_method" "options_records" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.records.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_records" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.records.id
  http_method = aws_api_gateway_method.options_records.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "options_records" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.records.id
  http_method = aws_api_gateway_method.options_records.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_records" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.records.id
  http_method = aws_api_gateway_method.options_records.http_method
  status_code = aws_api_gateway_method_response.options_records.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.options_records]
}

# --- Deployment / stage ---

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.uploads.id,
      aws_api_gateway_resource.upload_id.id,
      aws_api_gateway_resource.records.id,
      aws_api_gateway_authorizer.cognito.id,
      aws_api_gateway_method.post_uploads.id,
      aws_api_gateway_method.list_uploads.id,
      aws_api_gateway_method.get_upload_status.id,
      aws_api_gateway_method.get_records.id,
      aws_api_gateway_method.options_uploads.id,
      aws_api_gateway_method.options_upload_id.id,
      aws_api_gateway_method.options_records.id,
      aws_api_gateway_integration.post_uploads.id,
      aws_api_gateway_integration.list_uploads.id,
      aws_api_gateway_integration.get_upload_status.id,
      aws_api_gateway_integration.get_records.id,
      aws_api_gateway_integration.options_uploads.id,
      aws_api_gateway_integration.options_upload_id.id,
      aws_api_gateway_integration.options_records.id,
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
      callerSub               = "$context.authorizer.claims.sub"
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
