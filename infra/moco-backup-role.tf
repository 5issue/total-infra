resource "aws_iam_policy" "moco_s3_backup" {
  name        = "moco-s3-backup-policy"
  description = "IAM Policy for MoCo MySQLCluster S3 backup"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::${var.moco_backup_bucket}/moco/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = [
          "arn:aws:s3:::${var.moco_backup_bucket}"
        ]
        Condition = {
          StringLike = {
            "s3:prefix" = ["moco/*"]
          }
        }
      }
    ]
  })
}

module "moco_backup_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "moco-s3-backup-role"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["backend:shared-mysql-backup"]
    }
  }

  role_policy_arns = {
    s3_backup = aws_iam_policy.moco_s3_backup.arn
  }
}