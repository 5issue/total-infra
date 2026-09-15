module "argocd" {
  source = "../modules/argocd"

  depends_on = [
    module.eks
  ]
}

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = "v1.16.2"
  namespace        = "cert-manager"
  create_namespace = true

  set {
    name  = "crds.enabled"
    value = "true"
  }

  wait    = true
  timeout = 600

  depends_on = [module.eks]
}

resource "null_resource" "apply_root_application" {
  depends_on = [
    module.eks,
    module.argocd,
    null_resource.update_kubeconfig,
    helm_release.cert_manager
  ]

  provisioner "local-exec" {
    command = <<-EOT
      kubectl wait --for=condition=established --timeout=60s crd/applications.argoproj.io
      kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
      kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=300s
      kubectl apply -f https://raw.githubusercontent.com/5issue/total-k8s/main/root-application.yaml
    EOT
  }
}