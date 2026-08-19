resource "aws_cognito_user_pool" "this" {
  name = "${var.name_prefix}-users"

  username_attributes      = ["email"]
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
  mfa_configuration   = "OFF"
  deletion_protection = var.deletion_protection
}

resource "aws_cognito_user_pool_client" "this" {
  name         = "${var.name_prefix}-client"
  user_pool_id = aws_cognito_user_pool.this.id

  # No client secret: a customer authenticating directly shouldn't have to manage yet another
  # permanent secret alongside their password.
  generate_secret = false

  # Without this, Cognito's InitiateAuth/ForgotPassword error responses differ depending on
  # whether the account exists - leaking account existence, which contradicts this project's
  # own "404 for both doesn't-exist and not-yours" design principle (see docs/adr/0006).
  prevent_user_existence_errors = "ENABLED"

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}
