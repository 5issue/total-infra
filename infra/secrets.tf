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
  name                    = "prod/total/client-secret"
  description             = "Managed by Terraform - Total Frontend & OAuth Client Credentials"
  recovery_window_in_days = 0 # 삭제 시 대기 없이 즉시 영구 삭제

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
  }
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

# ==============================================================================
# 2. Kubernetes Namespace & Secret 자동 배포
# ==============================================================================

locals {
  # Secrets Manager에 저장된 최신 시크릿 값을 JSON 디코딩
  client_creds = jsondecode(aws_secretsmanager_secret_version.total_client_secret_val.secret_string)
}

# Kubernetes Opaque Secret 배포 (total-client-secret)
resource "kubernetes_secret_v1" "frontend_total_client_secret" {
  depends_on = [module.eks]

  metadata {
    name      = "total-client-secret"
    namespace = "frontend"
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
  depends_on = [module.eks]

  metadata {
    name      = "argocd-secret"
    namespace = "argocd"
    labels = {
      "app.kubernetes.io/name"    = "argocd-secret"
      "app.kubernetes.io/part-of" = "argocd"
    }
  }

  data = {
    # 1. GitHub OAuth Client Secret (변수 참조)
    "dex.github.clientSecret" = var.argocd_github_client_secret

    # 2. admin1234 공식 bcrypt 해시값
    "admin.password"          = "$2a$10$PyRz1KF6diVqi.yZM.m0x.EbsgSOW7Sn0U197Y3pF4W69Y9cBRgz."

    # 3. 패스워드 로드용 타임스탬프
    "admin.passwordMtime"     = "2026-09-04T00:00:00Z"

    # 4. Argo CD 세션 암호화 토큰 키 (변수 참조)
    "server.secretkey"        = var.argocd_server_secretkey
  }

  type = "Opaque"
}