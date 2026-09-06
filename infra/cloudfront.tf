# ==============================================================================
# 1. CloudFront Origin Access Control (OAC) 생성
# ==============================================================================
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.project_name}-s3-oac"
  description                       = "OAC for Static S3 Bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# # AWS 관리형 정책 조회 (동적 조회)
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# data "aws_cloudfront_origin_request_policy" "all_viewer" {
#   name = "Managed-AllViewerExceptHostHeader"
# }

# S3 버킷 조회
data "aws_s3_bucket" "static_assets" {
  bucket = "${var.project_name}-static-assets"
}

data "aws_acm_certificate" "cloudfront" {
  provider    = aws.us_east_1
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

# ==============================================================================
# 2. CloudFront 배포 (Distribution) 생성 (alb_dns_name이 존재할 때만 생성)
# ==============================================================================
resource "aws_cloudfront_distribution" "main" {
  count = var.alb_dns_name != "" ? 1 : 0

  origin {
    domain_name = var.alb_dns_name
    origin_id   = "EKS-ALB-Origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only" # ALB 443 HTTPS 통신
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  origin {
    domain_name              = data.aws_s3_bucket.static_assets.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
    origin_id                = "S3-StaticAssets"
  }

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = ""
  # Route 53과 연동할 도메인 별칭
  aliases             = [var.domain_name, "www.${var.domain_name}"]

  # 기본 캐시 동작 (EKS ALB로 인입되는 모든 트래픽)
  default_cache_behavior {
    target_origin_id       = "EKS-ALB-Origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods  = ["GET", "HEAD", "OPTIONS"]

    cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.alb_origin_policy.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  # us-east-1 리전 ACM SSL 인증서 연결
  viewer_certificate {
    acm_certificate_arn      = data.aws_acm_certificate.cloudfront.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Name        = "${var.project_name}-cloudfront"
    Environment = "Production"
  }
}

# ==============================================================================
# 3. S3 버킷 정책 (CloudFront OAC 전용 접근 허용)
# ==============================================================================
resource "aws_s3_bucket_policy" "static_assets" {
  count  = var.alb_dns_name != "" ? 1 : 0
  bucket = data.aws_s3_bucket.static_assets.id
  
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudFrontServicePrincipalReadOnly"
        Effect    = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${data.aws_s3_bucket.static_assets.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.main[0].arn
          }
        }
      }
    ]
  })
}

# ------------------------------------------------------------------------------
# ALB에 Host 헤더(cloudyim.store)를 전달하기 위한 커스텀 Origin Request Policy
# ------------------------------------------------------------------------------
resource "aws_cloudfront_origin_request_policy" "alb_origin_policy" {
  name    = "${var.project_name}-alb-origin-policy"
  comment = "Forward Host header to ALB for SSL cert match"

  cookies_config {
    cookie_behavior = "all"
  }

  headers_config {
    header_behavior = "whitelist"
    headers {
      items = ["Host", "User-Agent", "Referer", "Accept", "Accept-Language"]
    }
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}