# AWS 계정 ID 조회를 위한 데이터 소스 선언
data "aws_caller_identity" "current" {}

# KMS CMK 생성
resource "aws_kms_key" "secrets_cmk" {
  description             = "CMK for Secrets Manager and Sensitive Data (ISMS-P K-1)"
  deletion_window_in_days = 30   # K-4: 우발적 삭제 방지를 위한 대기기간(7~30일) 설정
  enable_key_rotation     = true # K-2: 연 1회 자동 키 로테이션 활성화

  # K-3: 최소 권한 키 정책 (Key Administrator와 Key User 분리)
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 1) 루트 계정에 키 관리 위임 (필수 기본 권한)
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # 2) Secrets Manager 서비스가 암호화/복호화에 키를 사용할 수 있도록 허용
      {
        Sid    = "AllowSecretsManagerService"
        Effect = "Allow"
        Principal = {
          Service = "secretsmanager.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name        = "cmk-prod-secrets"
    Environment = "prod"
    ManagedBy   = "terraform"
    Compliance  = "ISMS-P-2.7.2"
  }
}

resource "aws_kms_alias" "secrets_cmk_alias" {
  name          = "alias/prod-secrets-cmk"
  target_key_id = aws_kms_key.secrets_cmk.key_id
}

output "secrets_cmk_arn" {
  value       = aws_kms_key.secrets_cmk.arn
  description = "Secrets Manager용 CMK ARN"
}