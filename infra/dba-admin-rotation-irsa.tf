resource "aws_iam_policy" "mysql_dba_admin_rotate" {
  name        = "mysql-dba-admin-rotate-policy"
  description = "Rotate shared-mysql-dba-admin secret only"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadWriteMysqlDbaAdminSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue"
        ]
        Resource = aws_secretsmanager_secret.dba_admin["mysql"].arn
      },
      {
        Sid      = "DecryptEncryptViaSecretsManager"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = data.aws_kms_alias.secrets_cmk.target_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
          StringLike = {
            "kms:EncryptionContext:SecretARN" = aws_secretsmanager_secret.dba_admin["mysql"].arn
          }
        }
      }
    ]
  })
}

module "mysql_dba_admin_rotator_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "mysql-dba-admin-rotator"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["backend:mysql-dba-admin-rotator"]
    }
  }

  role_policy_arns = {
    rotate = aws_iam_policy.mysql_dba_admin_rotate.arn
  }
}

resource "aws_iam_policy" "pg_dba_admin_rotate" {
  name        = "pg-dba-admin-rotate-policy"
  description = "Rotate shared-pg-dba-admin-credentials secret only"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadWritePgDbaAdminSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue",
          "secretsmanager:PutSecretValue"
        ]
        Resource = aws_secretsmanager_secret.dba_admin["postgresql"].arn
      },
      {
        Sid      = "DecryptEncryptViaSecretsManager"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = data.aws_kms_alias.secrets_cmk.target_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
          StringLike = {
            "kms:EncryptionContext:SecretARN" = aws_secretsmanager_secret.dba_admin["postgresql"].arn
          }
        }
      }
    ]
  })
}

module "pg_dba_admin_rotator_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "pg-dba-admin-rotator"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["backend:pg-dba-admin-rotator"]
    }
  }

  role_policy_arns = {
    rotate = aws_iam_policy.pg_dba_admin_rotate.arn
  }
}
