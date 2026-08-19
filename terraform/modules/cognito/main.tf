resource "aws_cognito_user_pool" "this" {
  name = "${var.name_prefix}-users"

  alias_attributes         = ["email"]
  auto_verified_attributes = ["email"]

  # Self-service sign-up: customers register themselves, no operator involvement.
  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  password_policy {
    minimum_length    = var.password_minimum_length
    require_uppercase = true
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
  }

  # "Optional" isn't meaningfully different from "off" without an enrollment flow, which isn't
  # being built - see docs/adr/0006-cognito-auth.md.
  mfa_configuration = "OFF"
}

resource "aws_cognito_user_pool_client" "this" {
  name         = "${var.name_prefix}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  # No client secret: a customer authenticating directly shouldn't have to manage yet another
  # permanent secret alongside their password.
  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}
