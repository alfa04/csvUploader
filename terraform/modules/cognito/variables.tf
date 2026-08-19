variable "name_prefix" {
  description = "Prefix for the user pool/client names, e.g. csvuploader-dev."
  type        = string
}

variable "password_minimum_length" {
  type    = number
  default = 8
}
