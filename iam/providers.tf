terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.75"
    }
  }

  # ==============================================================================
  # IAM 전용 원격 백엔드 설정 (key 경로 분리 필수!)
  # ==============================================================================
  backend "s3" {
    bucket         = "issue-tfstate-ap-northeast-2"
    key            = "iam/terraform.tfstate"       # infra/ 대신 iam/ 경로 사용
    region         = "ap-northeast-2"
    dynamodb_table = "issue-tfstate-locks"
    encrypt        = true
  }

}

provider "aws" {
  region = "ap-northeast-2"
}