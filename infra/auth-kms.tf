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




