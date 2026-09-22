# ==============================================================================
# RabbitMQ Application credential containers
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

# SecretVersion은 Terraform에서 관리하지 않습니다.
resource "aws_secretsmanager_secret" "rabbitmq_wms_credentials" {
  name                    = "prod/total/rabbitmq-wms-credentials"
  description             = "RabbitMQ total-wms application credentials for total-prod"
  kms_key_id              = data.aws_kms_alias.secrets_cmk.target_key_arn
  recovery_window_in_days = 7

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
    Compliance  = "ISMS-P-2.7.2"
  }
}

# SecretVersion은 Terraform에서 관리하지 않습니다.
resource "aws_secretsmanager_secret" "rabbitmq_oms_credentials" {
  name                    = "prod/total/rabbitmq-oms-credentials"
  description             = "RabbitMQ total-oms application credentials for total-prod"
  kms_key_id              = data.aws_kms_alias.secrets_cmk.target_key_arn
  recovery_window_in_days = 7

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
    Compliance  = "ISMS-P-2.7.2"
  }
}

# ==============================================================================
# Redis credential container
# ==============================================================================

# SecretVersion과 실제 password는 Terraform에서 관리하지 않습니다.
resource "aws_secretsmanager_secret" "redis_credentials" {
  name                    = "prod/total/redis-credentials"
  description             = "Redis password shared by the backend workload and applications"
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
