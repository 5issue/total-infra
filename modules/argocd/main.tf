resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true

  values = [
    yamlencode({
      dex = {
        enabled = true
      }
      configs = {
        cm = {
          "kustomize.buildOptions" = "--enable-helm"
        }
      }
    })
  ]

  timeout = 600
  wait    = false
}

resource "helm_release" "argo_rollouts" {
  name             = "argo-rollouts"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-rollouts"
  version          = var.argo_rollouts_chart_version
  namespace        = "argo-rollouts"
  create_namespace = true

  timeout = 600
  wait    = false

  values = [<<-YAML
    controller:
      initContainers:
        - name: copy-gateway-api-plugin
          image: ghcr.io/argoproj-labs/rollouts-plugin-trafficrouter-gatewayapi:v0.5.0@sha256:cdaf973e2f390034e293af0d4ee08611b6b6c089f1627167b4014c3bcac12a7c
          command: ["/bin/sh", "-c"]
          args:
            - cp /bin/rollouts-plugin-trafficrouter-gatewayapi /plugins/
          volumeMounts:
            - name: gateway-api-plugin
              mountPath: /plugins
      trafficRouterPlugins:
        - name: argoproj-labs/gatewayAPI
          location: file:///plugins/rollouts-plugin-trafficrouter-gatewayapi
      volumes:
        - name: gateway-api-plugin
          emptyDir: {}
      volumeMounts:
        - name: gateway-api-plugin
          mountPath: /plugins
    providerRBAC:
      providers:
        gatewayAPI: true
      additionalRules:
        - apiGroups: ["gateway.networking.k8s.io"]
          resources: ["httproutes"]
          verbs: ["get", "list", "update", "patch"]
    YAML
  ]

  depends_on = [
    helm_release.argocd
  ]
}