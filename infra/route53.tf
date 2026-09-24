# Route 53 호스팅 영역 조회 (기존 도메인이 등록되어 있는 경우)
data "aws_route53_zone" "main" {
  name         = "${var.domain_name}."
  private_zone = false
}

# cloudyim.store-> CloudFront 연결 (CloudFront가 생성되었을 때만 생성)
resource "aws_route53_record" "main" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# www.cloudyim.store -> CloudFront 연결
resource "aws_route53_record" "www" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.main[0].domain_name
    zone_id                = aws_cloudfront_distribution.main[0].hosted_zone_id
    evaluate_target_health = false
  }
}

# api.cloudyim.store -> ALB 직접 연결 (운영 백엔드 & AI API)
resource "aws_route53_record" "api" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "api.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = "ZWKZPGTI48KDX" # 서울(ap-northeast-2) 리전 ALB 고정 Hosted Zone ID
    evaluate_target_health = true
  }
}

# ==============================================================================
# 관리자 도구 서브도메인 -> ALB 연결 (A 레코드 Alias로 통일)
# Ingress 생성 후 ALB DNS가 나왔을 때(var.alb_dns_name이 채워졌을 때)만 생성
# ==============================================================================

# argocd.cloudyim.store -> ALB
resource "aws_route53_record" "argocd" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "argocd.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = "ZWKZPGTI48KDX" # 서울(ap-northeast-2) 리전 ALB 고정 Hosted Zone ID
    evaluate_target_health = true
  }
}

# grafana.cloudyim.store -> ALB
resource "aws_route53_record" "grafana" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "grafana.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = "ZWKZPGTI48KDX"
    evaluate_target_health = true
  }
}

# dev.cloudyim.store -> ALB 직접 연결 (DAST 점검용)
resource "aws_route53_record" "dev" {
  count   = var.alb_dns_name != "" ? 1 : 0
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "dev.${var.domain_name}"
  type    = "A"

  alias {
    name                   = var.alb_dns_name
    zone_id                = "ZWKZPGTI48KDX"
    evaluate_target_health = true
  }
}
