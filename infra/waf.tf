# infra/waf.tf

# ==============================================================================
# AWS WAFv2 Web ACL (ALB 연동용 - REGIONAL)
# ==============================================================================
resource "aws_wafv2_web_acl" "alb_waf" {
  count = var.enable_waf ? 1 : 0

  name        = "${var.project_name}-alb-waf"
  description = "WAF for EKS ALB (Rate Limiting and Common Attacks Defense)"
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # ----------------------------------------------------------------------------
  # Rule 1: IP 기반 DoS 및 무차별 대입 완화 (5분당 1,000회 초과 시 차단)
  # ----------------------------------------------------------------------------
  rule {
    name     = "RateLimitRule"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRuleMetric"
      sampled_requests_enabled   = true
    }
  }

  # ----------------------------------------------------------------------------
  # Rule 2: AWS Managed Rules - Core Rule Set (SQLi, XSS, 취약점 기본 방어)
  # ----------------------------------------------------------------------------
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "CommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # ----------------------------------------------------------------------------
  # Rule 3: 악성 IP 평판 차단 (Amazon IP Reputation List)
  # ----------------------------------------------------------------------------
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 3

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AmazonIpReputationMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.project_name}-alb-waf-metric"
    sampled_requests_enabled   = true
  }

  tags = {
    Name        = "${var.project_name}-alb-waf"
    Environment = "Production"
    ManagedBy   = "Terraform"
  }
}

