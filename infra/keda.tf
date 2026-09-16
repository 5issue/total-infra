resource "helm_release" "keda" {
  depends_on = [
    module.eks,
    module.grafana
  ]

  name             = "keda"
  repository       = "https://kedacore.github.io/charts"
  chart            = "keda"
  version          = "2.20.2"
  namespace        = "keda"
  create_namespace = true

  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true

  values = [
    yamlencode({
      operator = {
        replicaCount = 1
      }

      metricsServer = {
        replicaCount = 1
      }

      webhooks = {
        replicaCount = 1
      }

      # KEDA는 클러스터 운영 구성요소이므로
      # Karpenter Spot 노드가 아닌 Managed Node Group에 배치합니다.
      nodeSelector = {
        "eks.amazonaws.com/capacityType" = "ON_DEMAND"
      }

      prometheus = {
        metricServer = {
          enabled = true

          serviceMonitor = {
            enabled       = true
            interval      = "30s"
            scrapeTimeout = "10s"

            additionalLabels = {
              release = "prometheus"
            }
          }
        }

        operator = {
          enabled = true

          serviceMonitor = {
            enabled       = true
            interval      = "30s"
            scrapeTimeout = "10s"

            additionalLabels = {
              release = "prometheus"
            }
          }
        }

        webhooks = {
          enabled = true

          serviceMonitor = {
            enabled       = true
            interval      = "30s"
            scrapeTimeout = "10s"

            additionalLabels = {
              release = "prometheus"
            }
          }
        }
      }
    })
  ]
}