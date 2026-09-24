# ==============================================================================
# 1. CloudTrail 및 S3 버킷 (항목 4.5, 4.7 대응)
# ==============================================================================

# CloudTrail 로그 저장용 임시 S3 버킷
resource "aws_s3_bucket" "cloudtrail_bucket" {
  count         = var.enable_audit_logging ? 1 : 0
  bucket_prefix = "audit-cloudtrail-logs-"
  force_destroy = true # 점검 후 삭제/정리 용이하도록 설정
}

# CloudTrail S3 Bucket Policy
resource "aws_s3_bucket_policy" "cloudtrail_bucket_policy" {
  count  = var.enable_audit_logging ? 1 : 0
  bucket = aws_s3_bucket.cloudtrail_bucket[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.cloudtrail_bucket[0].arn
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.cloudtrail_bucket[0].arn}/prefix/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# CloudTrail 생성 (Multi-region 및 글로벌 이벤트 포함 - 필수 감사 조건 충족)
resource "aws_cloudtrail" "audit_trail" {
  count                         = var.enable_audit_logging ? 1 : 0
  name                          = "audit-inspection-trail"
  s3_bucket_name                = aws_s3_bucket.cloudtrail_bucket[0].id
  s3_key_prefix                 = "prefix"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  depends_on = [aws_s3_bucket_policy.cloudtrail_bucket_policy]

  tags = {
    Name        = "audit-inspection-trail"
    Environment = "prod"
  }
}

# ==============================================================================
# 2. VPC Flow Logs 및 CloudWatch Logs (항목 4.11 대응)
# ==============================================================================

# CloudWatch Log Group
resource "aws_cloudwatch_log_group" "flow_log_group" {
  count             = var.enable_audit_logging ? 1 : 0
  name              = "/aws/vpc/flow-logs-audit"
  retention_in_days = 1 # 비용 최소화 (1일 보관)
}

# VPC Flow Logs용 IAM Role & Policy
resource "aws_iam_role" "flow_log_role" {
  count = var.enable_audit_logging ? 1 : 0
  name  = "vpc-flow-logs-audit-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "vpc-flow-logs.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "flow_log_policy" {
  count = var.enable_audit_logging ? 1 : 0
  name  = "vpc-flow-logs-audit-policy"
  role  = aws_iam_role.flow_log_role[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams"
        ]
        Effect   = "Allow"
        Resource = "*"
      }
    ]
  })
}

# VPC Flow Logs 본체
# (기존 network.tf 등에서 정의된 VPC ID 리소스를 참조하세요. 예: aws_vpc.main.id 또는 module.vpc.vpc_id)
resource "aws_flow_log" "vpc_flow_log" {
  count                = var.enable_audit_logging ? 1 : 0
  iam_role_arn         = aws_iam_role.flow_log_role[0].arn
  log_destination      = aws_cloudwatch_log_group.flow_log_group[0].arn
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.main.id

  tags = {
    Name = "vpc-flow-log-audit"
  }
}

resource "aws_ssm_document" "session_manager_run_shell" {
  name          = "SSM-SessionManagerRunShell"
  document_type = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager Logging Configuration"
    sessionType   = "Standard_Stream"
    inputs = {
      s3BucketName                = "kurly-security-logs-ap-northeast-2"
      s3KeyPrefix                 = "session-logs"
      s3EncryptionEnabled         = true
      cloudWatchLogGroupName      = ""
      cloudWatchEncryptionEnabled = false
    }
  })
}
