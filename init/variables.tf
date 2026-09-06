variable "aws_region" {
  description = "ALB 및 기본 인프라 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "cloudfront_region" {
  description = "CloudFront ACM 인증서 전용 리전"
  type        = string
  default     = "us-east-1"
}

variable "domain_name" {
  description = "Route 53에 등록된 메인 단일 도메인"
  type        = string
  default     = "cloudyim.store"
}

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "kurly-food"
}