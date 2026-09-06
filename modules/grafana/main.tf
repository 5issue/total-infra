# modules/monitoring/main.tf
resource "helm_release" "kube_prometheus_stack" {
  name             = "prometheus"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.chart_version # 69.3.2
  namespace        = "prometheus"
  create_namespace = true

  values = [
    yamlencode({
      grafana = {
        enabled       = true
        adminPassword = "admin1234"
        envFromSecret = "grafana-github-oauth" # 방금 만든 Secret 참조
        "grafana.ini" = {
          server = {
            root_url = "https://grafana.cloudyim.store"
          }
          "auth.github" = {
            enabled      = true
            allow_sign_up = true
            auto_login   = false
            client_id    = "Ov23litHemenldpm9HcO" # Grafana용 Client ID
            scopes       = "user:email,read:org"
            auth_url     = "https://github.com/login/oauth/authorize"
            token_url    = "https://github.com/login/oauth/access_token"
            api_url      = "https://api.github.com/user"

            # 해당 조직 멤버가 아니면 403 Access Denied로 원천 차단됨
            allowed_organizations = "5issue"
            # 조직 멤버 중에서도 지정된 5명은 Admin, 그 외 조직원은 Viewer
            role_attribute_path = "contains(['yimjongwon', 'evertonian19', 'KTCLIF', 'parkyhun', 'kmkben0615'], login) && 'Admin' || 'Viewer'"
          }
        }
      }
    })
  ]

  timeout = 600
  wait    = false
}