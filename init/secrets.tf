# ==============================================================================
# RabbitMQ Application credential container
# ==============================================================================

# SecretVersion은 Terraform에서 관리하지 않습니다.
resource "aws_secretsmanager_secret" "rabbitmq_app_credentials" {
  name                    = "prod/total/rabbitmq-app-credentials"
  description             = "RabbitMQ total-backend application credentials for total-prod"
  kms_key_id              = data.aws_kms_alias.secrets_cmk.target_key_arn
  recovery_window_in_days = 7

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
    Compliance  = "ISMS-P-2.7.2"
  }
}

data "aws_kms_alias" "secrets_cmk" {
  name = "alias/prod-secrets-cmk"
}