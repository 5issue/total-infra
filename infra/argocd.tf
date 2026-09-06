# total-infra/infra/argocd.tf

module "argocd" {
  source = "../modules/argocd"
  
  # EKS 클러스터 및 Karpenter/노드 생성이 완료된 후 실행되도록 보장
  depends_on = [
    module.eks 
  ]
}

resource "null_resource" "apply_root_application" {
  depends_on = [
    module.eks,
    module.argocd,
    null_resource.update_kubeconfig
  ]

  provisioner "local-exec" {
    command = <<-EOT
      kubectl wait --for=condition=established --timeout=60s crd/applications.argoproj.io
      kubectl apply -f https://raw.githubusercontent.com/5issue/total-k8s/main/root-application.yaml
    EOT
  }
}