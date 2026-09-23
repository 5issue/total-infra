locals {
  dba_admin_engines = {
    mysql      = "mysql"
    postgresql = "postgresql"
  }
}

resource "random_password" "dba_admin" {
  for_each = local.dba_admin_engines
  length           = 12
  special          = true
  override_special = "!$%&*()-_=+<>"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "time_static" "dba_admin_created" {
  for_each = local.dba_admin_engines
}

resource "aws_secretsmanager_secret" "dba_admin" {
  for_each                = local.dba_admin_engines
  name                    = "prod/total/dba-admin-${each.key}"
  description             = "Managed by Terraform - dba_admin credential for ${each.value} (jaehyeok, jongwon only)"
  kms_key_id              = data.aws_kms_alias.secrets_cmk.target_key_arn
  recovery_window_in_days = 7

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
    Service     = "dba-admin"
    Engine      = each.value
    Compliance  = "ISMS-P-2.7.2"
  }
}

resource "aws_secretsmanager_secret_version" "dba_admin_val" {
  for_each  = local.dba_admin_engines
  secret_id = aws_secretsmanager_secret.dba_admin[each.key].id
  secret_string = jsonencode({
    username = "dba_admin"
    password = random_password.dba_admin[each.key].result
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

locals {
  dba_admin_creds = {
    for k, v in aws_secretsmanager_secret_version.dba_admin_val :
    k => jsondecode(v.secret_string)
  }
}

resource "kubernetes_secret_v1" "shared_mysql_dba_admin" {
  depends_on = [module.eks, kubernetes_namespace_v1.backend]

  metadata {
    name      = "shared-mysql-dba-admin"
    namespace = kubernetes_namespace_v1.backend.metadata[0].name
    annotations = {
      "dba-admin/last-rotated" = time_static.dba_admin_created["mysql"].rfc3339
    }
  }

  data = {
    "username" = local.dba_admin_creds["mysql"]["username"]
    "password" = local.dba_admin_creds["mysql"]["password"]
  }

  type = "Opaque"

  lifecycle {
    ignore_changes = [data, metadata[0].annotations]
  }
}

resource "kubernetes_secret_v1" "shared_pg_dba_admin_credentials" {
  depends_on = [module.eks, kubernetes_namespace_v1.backend]

  metadata {
    name      = "shared-pg-dba-admin-credentials"
    namespace = kubernetes_namespace_v1.backend.metadata[0].name
    annotations = {
      "dba-admin/last-rotated" = time_static.dba_admin_created["postgresql"].rfc3339
    }
  }

  data = {
    "username" = local.dba_admin_creds["postgresql"]["username"]
    "password" = local.dba_admin_creds["postgresql"]["password"]
  }

  type = "Opaque"

  lifecycle {
    ignore_changes = [data, metadata[0].annotations]
  }
}
