terraform {
  required_version = ">= 1.5.0"
  required_providers {
    vultr = {
      source  = "vultr/vultr"
      version = "~> 2.31"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "vultr" {}

provider "aws" {
  region = "us-east-1"
}
