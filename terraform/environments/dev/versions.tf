terraform {
  required_version = ">= 1.9.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    bucket         = "csvuploader-tfstate-230167091710"
    key            = "dev/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "csvuploader-tfstate-lock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}
