# ==============================================================================
# 1. AWS Secrets Manager 리소스 및 초기값 생성 (100% 코드 관리)
# ==============================================================================

# 1-1. client-secret에 사용할 암호화 무작위 문자열 자동 생성
resource "random_password" "client_secret" {
  length  = 32
  special = false
}

# 1-2. AWS Secrets Manager 시크릿 생성
resource "aws_secretsmanager_secret" "total_client_secret" {
  name_prefix = "prod/total/client-secret-"
  description = "Managed by Terraform - Total Frontend & OAuth Client Credentials"

  # [K-1 조치] AWS 관리형 키 대신 생성한 CMK ARN 지정
  # (iam 디렉터리와 분리되어 있다면 data aws_kms_alias 또는 remote_state/변수 사용)
  kms_key_id = data.aws_kms_alias.secrets_cmk.target_key_arn

  # [K-4 조치] 0(즉시 삭제) 제거 -> 7일 이상 대기기간 지정
  recovery_window_in_days = 7

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
    Compliance  = "ISMS-P-2.7.2"
  }
}

# KMS Alias 조회 (iam 레이어에서 생성된 키를 참조할 경우)
data "aws_kms_alias" "secrets_cmk" {
  name = "alias/prod-secrets-cmk"
}

# 1-3. Secrets Manager에 JSON 형태의 시크릿 값 주입
# (실제 Keycloak/OAuth ID와 생성된 랜덤 시크릿 매핑)
resource "aws_secretsmanager_secret_version" "total_client_secret_val" {
  secret_id = aws_secretsmanager_secret.total_client_secret.id
  secret_string = jsonencode({
    client-id     = "total-client"
    client-secret = random_password.client_secret.result
  })
}

# RabbitMQ Secret container는 init stack에서 관리합니다.
removed {
  from = aws_secretsmanager_secret.rabbitmq_app_credentials

  lifecycle {
    destroy = false
  }
}

# ==============================================================================
# 2. Kubernetes Namespace & Secret 자동 배포
# ==============================================================================
resource "kubernetes_namespace_v1" "frontend" {
  depends_on = [module.eks]
  metadata {
    name = "frontend"
  }
}

resource "kubernetes_namespace_v1" "backend" {
  depends_on = [module.eks]
  metadata {
    name = "backend"
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  depends_on = [module.eks]
  metadata {
    name = "argocd"
  }
}

locals {
  # Secrets Manager에 저장된 최신 시크릿 값을 JSON 디코딩
  client_creds = jsondecode(aws_secretsmanager_secret_version.total_client_secret_val.secret_string)
}

# Kubernetes Opaque Secret 배포 (total-client-secret)
resource "kubernetes_secret_v1" "frontend_total_client_secret" {
  depends_on = [module.eks, kubernetes_namespace_v1.frontend]

  metadata {
    name      = "total-client-secret"
    namespace = kubernetes_namespace_v1.frontend.metadata[0].name # 직접 참조
  }

  data = {
    "client-id"     = local.client_creds["client-id"]
    "client-secret" = local.client_creds["client-secret"]
  }

  type = "Opaque"
}

# ==============================================================================
# Argo CD 핵심 Secret 배포 (기존 YAML 내용을 Terraform 리소스로 전환)
# ==============================================================================
resource "kubernetes_secret_v1" "argocd_secret" {
  depends_on = [module.eks, kubernetes_namespace_v1.argocd]

  metadata {
    name      = "argocd-secret"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name # 직접 참조
    labels = {
      "app.kubernetes.io/name"       = "argocd-secret"
      "app.kubernetes.io/part-of"    = "argocd"
      "app.kubernetes.io/managed-by" = "Helm"
    }

    # Helm 릴리스 연결을 위한 필수 어노테이션 추가
    annotations = {
      "meta.helm.sh/release-name"      = "argocd"
      "meta.helm.sh/release-namespace" = "argocd"
    }
  }

  data = {
    # 1. GitHub OAuth Client Secret (변수 참조)
    "dex.github.clientSecret" = var.argocd_github_client_secret

    # 2. admin1234 공식 bcrypt 해시값
    "admin.password" = var.argocd_admin_password_hash

    # 3. 패스워드 로드용 타임스탬프
    "admin.passwordMtime" = "2026-09-04T00:00:00Z"

    # 4. Argo CD 세션 암호화 토큰 키 (변수 참조)
    "server.secretkey" = var.argocd_server_secretkey
  }

  type = "Opaque"
}

# ==============================================================================
# Grafana 네임스페이스 및 Secret 배포 (Terraform 100% 코드 관리)
# ==============================================================================

# 1. Prometheus / Grafana 네임스페이스 선언
resource "kubernetes_namespace_v1" "prometheus" {
  depends_on = [module.eks]
  metadata {
    name = "prometheus"
  }
}

# 2. Grafana Secret 배포 (Helm 차트 충돌 방지 메타데이터 포함)
resource "kubernetes_secret_v1" "grafana_github_oauth" {
  depends_on = [module.eks, kubernetes_namespace_v1.prometheus]

  metadata {
    name      = "grafana-github-oauth"
    namespace = kubernetes_namespace_v1.prometheus.metadata[0].name

    # Helm 릴리스가 자기 리소스로 인식할 수 있도록 라벨/어노테이션 추가
    labels = {
      "app.kubernetes.io/name"       = "grafana"
      "app.kubernetes.io/managed-by" = "Helm"
    }

    annotations = {
      # Grafana Helm 릴리스명에 맞게 설정 (보통 grafana 또는 kube-prometheus-stack)
      "meta.helm.sh/release-name"      = "grafana"
      "meta.helm.sh/release-namespace" = "prometheus"
    }
  }

  data = {
    # 1) GitHub OAuth Secret (변수 var.grafana_github_client_secret 참조 권장)
    "GF_AUTH_GITHUB_CLIENT_SECRET" = var.grafana_github_client_secret

    # 2) Grafana Admin 비밀번호
    "GF_SECURITY_ADMIN_PASSWORD" = var.grafana_admin_password
  }

  type = "Opaque"
}
resource "kubernetes_secret_v1" "alertmanager_slack_webhook" {
  depends_on = [
    module.eks,
    kubernetes_namespace_v1.prometheus
  ]

  metadata {
    name      = "alertmanager-slack-webhook"
    namespace = kubernetes_namespace_v1.prometheus.metadata[0].name

    labels = {
      "app.kubernetes.io/name"      = "alertmanager"
      "app.kubernetes.io/component" = "notification"
    }
  }

  data = {
    "webhook-url" = local.alertmanager_slack_webhook["webhook-url"]
  }

  type = "Opaque"
}

# ==============================================================================
# dev (스테이징) 네임스페이스 및 Secret 배포
# ==============================================================================

# 1. dev 네임스페이스 선언
resource "kubernetes_namespace_v1" "dev" {
  depends_on = [module.eks]
  metadata {
    name = "dev"
  }
}
data "aws_secretsmanager_secret" "alertmanager_slack_webhook" {
  name = "prod/total/alertmanager-slack-webhook"
}

data "aws_secretsmanager_secret_version" "alertmanager_slack_webhook" {
  secret_id = data.aws_secretsmanager_secret.alertmanager_slack_webhook.id
}

locals {
  alertmanager_slack_webhook = jsondecode(
    data.aws_secretsmanager_secret_version.alertmanager_slack_webhook.secret_string
  )
}
# 2. dev 네임스페이스용 total-client-secret 배포
resource "kubernetes_secret_v1" "dev_total_client_secret" {
  depends_on = [module.eks, kubernetes_namespace_v1.dev]

  metadata {
    name      = "total-client-secret"
    namespace = kubernetes_namespace_v1.dev.metadata[0].name
  }

  data = {
    "client-id"     = local.client_creds["client-id"]
    "client-secret" = local.client_creds["client-secret"]
  }

  type = "Opaque"
}

locals {
  db_service_accounts = toset([
    "user_user", "auth_user", "order_user",
    "payment_user", "oms_user",
    "product_user", "wms_user", "scm_user",
    "ai_user"
  ])
}

resource "random_password" "db_service_passwords" {
  for_each         = local.db_service_accounts
  length           = 12
  special          = true
  override_special = "!$%&*()-_=+<>"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "aws_secretsmanager_secret" "db_service_accounts" {
  for_each                = local.db_service_accounts
  name_prefix             = "prod/total/db-${each.key}-"
  description             = "Managed by Terraform - DB credential for ${each.key}"
  kms_key_id              = data.aws_kms_alias.secrets_cmk.target_key_arn
  recovery_window_in_days = 7

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
    Service     = each.key
    Compliance  = "ISMS-P-2.7.2"
  }
}

resource "aws_secretsmanager_secret_version" "db_service_accounts_val" {
  for_each  = local.db_service_accounts
  secret_id = aws_secretsmanager_secret.db_service_accounts[each.key].id
  secret_string = jsonencode({
    username = each.key
    password = random_password.db_service_passwords[each.key].result
  })
}

locals {
  db_service_creds = {
    for k, v in aws_secretsmanager_secret_version.db_service_accounts_val :
    k => jsondecode(v.secret_string)
  }
}

locals {
  target_namespaces = ["backend", "dev"]
}

# shared-mysql-accounts (backend, dev 양쪽에 생성)
resource "kubernetes_secret_v1" "shared_mysql_accounts" {
  for_each = toset(local.target_namespaces)

  depends_on = [module.eks, kubernetes_namespace_v1.backend, kubernetes_namespace_v1.dev]

  metadata {
    name      = "shared-mysql-accounts"
    namespace = each.key
  }

  data = {
    "member_service_password"  = local.db_service_creds["user_user"]["password"]
    "auth_service_password"    = local.db_service_creds["auth_user"]["password"]
    "order_service_password"   = local.db_service_creds["order_user"]["password"]
    "payment_service_password" = local.db_service_creds["payment_user"]["password"]
  }

  type = "Opaque"
}

# PostgreSQL 서비스별 시크릿들도 양쪽에 생성
locals {
  pg_secrets = {
    "shared-pg-product-service-credentials" = "product_user"
    "shared-pg-wms-service-credentials"     = "wms_user"
    "shared-pg-scm-service-credentials"     = "scm_user"
    "shared-pg-oms-service-credentials"     = "oms_user"
    "shared-pg-ai-service-credentials"      = "ai_user"
  }
}

# PostgreSQL 서비스별 시크릿 (backend, dev 양쪽에 생성)
resource "kubernetes_secret_v1" "shared_pg_credentials" {
  for_each = {
    for pair in setproduct(local.target_namespaces, keys(local.pg_secrets)) :
    "${pair[0]}-${pair[1]}" => {
      namespace   = pair[0]
      secret_name = pair[1]
      user_key    = local.pg_secrets[pair[1]]
    }
  }

  depends_on = [module.eks, kubernetes_namespace_v1.backend, kubernetes_namespace_v1.dev]

  metadata {
    name      = each.value.secret_name
    namespace = each.value.namespace
  }

  data = {
    "username" = local.db_service_creds[each.value.user_key]["username"]
    "password" = local.db_service_creds[each.value.user_key]["password"]
  }

  type = "Opaque"
}

# AI LLM API Key Secret (OpenRouter)
resource "kubernetes_secret_v1" "ai_llm_secret" {
  for_each = toset(local.target_namespaces)

  depends_on = [
    module.eks,
    kubernetes_namespace_v1.backend,
    kubernetes_namespace_v1.dev
  ]

  metadata {
    name      = "ai-llm-secret"
    namespace = each.key
  }

  data = {
    "LLM_API_KEY" = var.llm_api_key
  }

  type = "Opaque"
}

# ==============================================================================
# OAuth2-Proxy (Swagger UI GitHub OAuth 보호용) 시크릿 배포
# ==============================================================================

# 1. 쿠키 암호화용 32바이트 무작위 문자열 자동 생성
resource "random_password" "oauth2_proxy_cookie_secret" {
  length  = 32
  special = false
}

# 2. AWS Secrets Manager에 영구 보관 (기존 KMS CMK 및 7일 대기기간 적용)
resource "aws_secretsmanager_secret" "oauth2_proxy" {
  name_prefix             = "prod/total/oauth2-proxy-"
  description             = "Managed by Terraform - OAuth2-Proxy GitHub Credentials & Cookie Secret"
  kms_key_id              = data.aws_kms_alias.secrets_cmk.target_key_arn
  recovery_window_in_days = 7

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
    Service     = "oauth2-proxy"
    Compliance  = "ISMS-P-2.7.2"
  }
}

resource "aws_secretsmanager_secret_version" "oauth2_proxy_val" {
  secret_id = aws_secretsmanager_secret.oauth2_proxy.id
  secret_string = jsonencode({
    client-id     = var.oauth2_proxy_github_client_id
    client-secret = var.oauth2_proxy_github_client_secret
    cookie-secret = base64encode(random_password.oauth2_proxy_cookie_secret.result)
  })
}

locals {
  oauth2_proxy_creds = jsondecode(aws_secretsmanager_secret_version.oauth2_proxy_val.secret_string)
}

# 3. k8s dev 네임스페이스에 Secret 자동 배포 (Helm 차트에서 existingSecret으로 참조)
resource "kubernetes_secret_v1" "oauth2_proxy_secrets" {
  depends_on = [module.eks, kubernetes_namespace_v1.dev]

  metadata {
    name      = "oauth2-proxy-secrets"
    namespace = kubernetes_namespace_v1.dev.metadata[0].name
  }

  data = {
    "client-id"     = local.oauth2_proxy_creds["client-id"]
    "client-secret" = local.oauth2_proxy_creds["client-secret"]
    "cookie-secret" = local.oauth2_proxy_creds["cookie-secret"]
  }

  type = "Opaque"
}

# ==============================================================================
# Auth Service 전용 JWT 서명용 KMS 비대칭 키 (ECC_NIST_P256)
# ==============================================================================
resource "aws_kms_key" "jwt_sign_key" {
  description              = "KMS Asymmetric Key for JWT signing in Auth Service"
  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = "ECC_NIST_P256"
  deletion_window_in_days  = 7

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
    Service     = "auth-service"
  }
}

resource "aws_kms_alias" "jwt_sign_key" {
  name          = "alias/auth-jwt-sign-key"
  target_key_id = aws_kms_key.jwt_sign_key.key_id
}

# ==============================================================================
# backend / dev 네임스페이스용 auth-secret 배포
# ==============================================================================
resource "kubernetes_secret_v1" "auth_secret" {
  for_each = toset(local.target_namespaces)

  depends_on = [
    module.eks,
    kubernetes_namespace_v1.backend,
    kubernetes_namespace_v1.dev
  ]

  metadata {
    name      = "auth-secret"
    namespace = each.key
  }

  data = {
    "KAKAO_CLIENT_SECRET" = "dummy-kakao-secret"
    "NAVER_CLIENT_SECRET" = "dummy-naver-secret"
  }

  type = "Opaque"
}

# ==============================================================================
# backend / dev 네임스페이스용 payment-secret 배포
# ==============================================================================
resource "kubernetes_secret_v1" "payment_secret" {
  for_each = toset(local.target_namespaces)

  depends_on = [
    module.eks,
    kubernetes_namespace_v1.backend,
    kubernetes_namespace_v1.dev
  ]

  metadata {
    name      = "payment-secret"
    namespace = each.key
  }

  data = {
    "TOSS_SECRET_KEY" = "test_sk_dummy_toss_secret_key"
  }

  type = "Opaque"
}