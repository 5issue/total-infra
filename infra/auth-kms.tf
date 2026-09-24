resource "aws_kms_key" "auth_jwt_signing" {
  description              = "Asymmetric signing key for auth-service JWT (ES256 / ECDSA_SHA_256)"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 30
  enable_key_rotation = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      }
    ]
  })

  tags = {
    Name        = "auth-jwt-signing-key"
    Environment = "prod"
    ManagedBy   = "terraform"
    Compliance  = "ISMS-P-1.3.2"
  }
}

resource "aws_kms_alias" "auth_jwt_signing" {
  name          = "alias/auth-jwt-signing"
  target_key_id = aws_kms_key.auth_jwt_signing.key_id
}

resource "aws_iam_policy" "auth_kms_sign" {
  name        = "auth-service-kms-sign-policy"
  description = "Allow auth-service to Sign/GetPublicKey on its dedicated JWT signing key only"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Sign",
          "kms:GetPublicKey",
          "kms:DescribeKey"
        ]
        Resource = [aws_kms_key.auth_jwt_signing.arn]
      }
    ]
  })
}

module "auth_kms_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "auth-service-kms-signer-role"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["backend:auth-service-sa"]
    }
  }

  role_policy_arns = {
    kms_sign = aws_iam_policy.auth_kms_sign.arn
  }
}


