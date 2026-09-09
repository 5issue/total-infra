# ==============================================================================
# [보안 요구사항] IAM Access Key 60일 주기 로테이션 점검 규칙
# 60일 초과된 키가 발견되면 AWS Config에서 규정 미준수(NON_COMPLIANT)로 감지
# ==============================================================================
# ==============================================================================
# 1. AWS Config 서비스 역할 (IAM Role)
# ==============================================================================
resource "aws_iam_role" "config_role" {
  name = "aws-config-service-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "config_role_attach" {
  role       = aws_iam_role.config_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# ==============================================================================
# 2. Config 스냅샷 저장용 S3 버킷 및 정책
# ==============================================================================
resource "aws_s3_bucket" "config_bucket" {
  bucket        = "config-bucket-596601390909-ap-northeast-2"
  force_destroy = true
}

resource "aws_s3_bucket_policy" "config_bucket_policy" {
  bucket = aws_s3_bucket.config_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config_bucket.arn
      },
      {
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config_bucket.arn}/AWSLogs/596601390909/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}

# ==============================================================================
# 3. Config Recorder 및 전송 채널 (기록기 활성화)
# ==============================================================================
resource "aws_config_configuration_recorder" "main" {
  name     = "default"
  role_arn = aws_iam_role.config_role.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "default"
  s3_bucket_name = aws_s3_bucket.config_bucket.bucket
  depends_on     = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.main]
}

# ==============================================================================
# 4. [보안 요구사항] IAM Access Key 60일 주기 로테이션 점검 규칙
# ==============================================================================
resource "aws_config_config_rule" "access_keys_rotated" {
  name = "access-keys-rotated"

  source {
    owner             = "AWS"
    source_identifier = "ACCESS_KEYS_ROTATED"
  }

  input_parameters = jsonencode({
    maxAccessKeyAge = "60"
  })

  depends_on = [aws_config_configuration_recorder_status.main]
}