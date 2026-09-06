# ==============================================================================
# 1. 도메인 및 Route 53 호스팅 영역 출력
# ==============================================================================
output "domain_name" {
  description = "메인 도메인 이름"
  value       = var.domain_name
}

output "route53_zone_id" {
  description = "Route 53 메인 Hosted Zone ID"
  value       = data.aws_route53_zone.selected.zone_id
}

# ==============================================================================
# 2. ACM 인증서 ARN 출력 
# ==============================================================================
output "alb_certificate_arn" {
  description = "ALB에 장착할 ACM 인증서 ARN (기본 리전)"
  value       = aws_acm_certificate_validation.alb_cert_wait.certificate_arn
}

output "cloudfront_certificate_arn" {
  description = "CloudFront에 장착할 ACM 인증서 ARN (CloudFront 전용 리전)"
  value       = aws_acm_certificate_validation.cf_cert_wait.certificate_arn
}
# ==============================================================================
# 3. Terraform Backend 리소스 출력 
# ==============================================================================
output "tfstate_s3_bucket" {
  description = "Terraform Remote Backend S3 버킷명"
  value       = aws_s3_bucket.tfstate.bucket
}

output "tfstate_dynamodb_table" {
  description = "Terraform State Lock DynamoDB 테이블명"
  value       = aws_dynamodb_table.tfstate_lock.name
}
# ==============================================================================
# 4. 이미지 저장소, ECR 및 CDN 출력
# ==============================================================================
output "static_assets_s3_bucket" {
  description = "정적/이미지 자산 저장용 S3 버킷명"
  value       = aws_s3_bucket.static_assets.bucket
}

output "ecr_repository_urls" {
  description = "서비스별 ECR 레포지토리 URL 맵"
  value       = { for k, v in aws_ecr_repository.repos : k => v.repository_url }
}


