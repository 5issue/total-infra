locals {
  workload_publication_role_name = "total-workload-publication"
  workload_publication_group     = "total:workload-publication"
  redis_credentials_secret_name  = "prod/total/redis-credentials"
}

# target-infra is a team-managed external role. Reference it without taking
# Terraform ownership of its trust or permission policies.
data "aws_iam_role" "target_infra" {
  name = "target-infra"
}

data "aws_secretsmanager_secret" "redis_credentials" {
  name = local.redis_credentials_secret_name
}

resource "aws_iam_role" "workload_publication" {
  name                 = local.workload_publication_role_name
  description          = "Least-privilege role for workload material publication to EKS"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowTargetInfraRole"
        Effect    = "Allow"
        Action    = "sts:AssumeRole"
        Principal = { AWS = data.aws_iam_role.target_infra.arn }
      }
    ]
  })

  tags = {
    Name        = local.workload_publication_role_name
    Environment = "prod"
    ManagedBy   = "terraform"
    Purpose     = "workload-publication"
  }
}

resource "aws_iam_role_policy" "workload_publication" {
  name = local.workload_publication_role_name
  role = aws_iam_role.workload_publication.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeEksCluster"
        Effect   = "Allow"
        Action   = "eks:DescribeCluster"
        Resource = module.eks.cluster_arn
      },
      {
        Sid    = "ReadRedisCredentials"
        Effect = "Allow"
        Action = [
          "secretsmanager:DescribeSecret",
          "secretsmanager:GetSecretValue"
        ]
        Resource = data.aws_secretsmanager_secret.redis_credentials.arn
      },
      {
        Sid      = "DecryptRedisCredentialsViaSecretsManager"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = data.aws_kms_alias.secrets_cmk.target_key_arn
        Condition = {
          StringEquals = {
            "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
          }
          StringLike = {
            "kms:EncryptionContext:SecretARN" = data.aws_secretsmanager_secret.redis_credentials.arn
          }
        }
      }
    ]
  })
}
