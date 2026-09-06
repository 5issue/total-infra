# Provider, Terraform 기본 설정 및 Route53 Zone Data
terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.75"
    }
  }
}

provider "aws" {
  region = var.aws_region # ap-northeast-2
}

provider "aws" {
  alias  = "cloudfront"
  region = var.cloudfront_region # us-east-1
}

# Route 53 호스팅 영역 조회
data "aws_route53_zone" "selected" {
  name         = "${var.domain_name}." # Route 53 검색 규격을 위해 마침표 포함
  private_zone = false
}