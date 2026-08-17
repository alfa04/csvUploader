terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # No remote backend here on purpose: this configuration creates the S3 bucket and DynamoDB
  # table that every environment's backend depends on. Its own state stays local and is applied
  # once, manually - see README.md.
}
