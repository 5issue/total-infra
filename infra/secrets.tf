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
  name_prefix             = "prod/total/client-secret-"
  description             = "Managed by Terraform - Total Frontend & OAuth Client Credentials"
  
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

# ==============================================================================
# 2. Kubernetes Namespace & Secret 자동 배포
# ==============================================================================
resource "kubernetes_namespace_v1" "frontend" {
  depends_on = [module.eks]
  metadata {
    name = "frontend"
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
      "app.kubernetes.io/name"        = "argocd-secret"
      "app.kubernetes.io/part-of"     = "argocd"
      "app.kubernetes.io/managed-by"  = "Helm"
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
    "admin.password"          = var.argocd_admin_password_hash

    # 3. 패스워드 로드용 타임스탬프
    "admin.passwordMtime"     = "2026-09-04T00:00:00Z"

    # 4. Argo CD 세션 암호화 토큰 키 (변수 참조)
    "server.secretkey"        = var.argocd_server_secretkey
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
    "GF_AUTH_GITHUB_CLIENT_SECRET"     = var.grafana_github_client_secret

    # 2) Grafana Admin 비밀번호
    "GF_SECURITY_ADMIN_PASSWORD"       = var.grafana_admin_password
  }

  type = "Opaque"
}