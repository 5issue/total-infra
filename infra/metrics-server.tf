resource "helm_release" "metrics_server" {
  depends_on = [
    module.eks,
    module.grafana
  ]

  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.14.0"
  namespace  = "kube-system"

  wait            = true
  timeout         = 300
  atomic          = true
  cleanup_on_fail = true

  values = [
    yamlencode({
      replicas = 1

      # -----------------------------------------------------------------------
      # [EKS 필수] Kubelet 자체 서명 인증서 검증 건너뛰기
      # -----------------------------------------------------------------------
      defaultArgs = [
        "--cert-dir=/tmp",
        "--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname",
        "--kubelet-use-node-status-port",
        "--metric-resolution=15s",
        "--kubelet-insecure-tls",
        "--authorization-always-allow-paths=/livez,/readyz,/metrics"
      ]

      # HPA가 사용하는 클러스터 핵심 구성요소이므로
      # Karpenter Spot 노드가 아닌 Managed Node Group에 배치합니다.
      nodeSelector = {
        "eks.amazonaws.com/capacityType" = "ON_DEMAND"
      }

      resources = {
        requests = {
          cpu    = "100m"
          memory = "200Mi"
        }
        limits = {
          cpu    = "500m"
          memory = "512Mi"
        }
      }

      metrics = {
        enabled = true
      }

      defaultArgs = [
        "--cert-dir=/tmp",
        "--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname",
        "--kubelet-use-node-status-port",
        "--metric-resolution=15s",
        "--kubelet-insecure-tls"
      ]

      args = [
        "--authorization-always-allow-paths=/livez,/readyz,/metrics"
      ]

      serviceMonitor = {
        enabled       = true
        interval      = "30s"
        scrapeTimeout = "10s"

        additionalLabels = {
          release = "prometheus"
        }
      }
    })
  ]
}