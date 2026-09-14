# 1. CNPG S3 백업 버킷 접근 정책
resource "aws_iam_policy" "cnpg_s3_backup" {
  name        = "cnpg-s3-backup-policy"
  description = "IAM Policy for CNPG cluster S3 archiving and backup"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::kurly-db-backup",
          "arn:aws:s3:::kurly-db-backup/*"
        ]
      }
    ]
  })
}

module "cnpg_backup_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "cnpg-s3-backup-role"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["backend:shared-pg"]
    }
  }

  role_policy_arns = {
    s3_backup = aws_iam_policy.cnpg_s3_backup.arn
  }
}