# Gateway API CRD 설치
resource "terraform_data" "gateway_api_crds" {
  triggers_replace = [
    var.cluster_endpoint
  ]

  provisioner "local-exec" {
    command = <<-EOT
      echo "[1/2] EKS API 서버 연결 대기 중..."
      for i in {1..30}; do
        if kubectl get nodes >/dev/null 2>&1; then
          echo "EKS API 서버 연결 성공!"
          break
        fi
        echo "DNS 전파 대기 중..."
        sleep 5
      done
      
      echo "[2/2] Gateway API CRD 설치 진행..."
      kubectl apply -k "github.com/kubernetes-sigs/gateway-api/config/crd?ref=v1.2.0" --validate=false
    EOT
  }
}

# ALB Controller용 RBAC 권한 사전 부여
resource "kubernetes_cluster_role_binding_v1" "aws_load_balancer_controller" {
  depends_on = [
    terraform_data.gateway_api_crds
  ]

  metadata {
    name = "aws-load-balancer-controller-admin-binding"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "aws-load-balancer-controller"
    namespace = "kube-system"
  }
}

# AWS Load Balancer Controller 배포
resource "helm_release" "aws_load_balancer_controller" {
  depends_on = [
    terraform_data.gateway_api_crds,
    kubernetes_cluster_role_binding_v1.aws_load_balancer_controller # 권한 바인딩 후 배포 시작
  ]

  name          = "aws-load-balancer-controller"
  repository    = "https://aws.github.io/eks-charts"
  chart         = "aws-load-balancer-controller"
  namespace     = "kube-system"
  version       = "1.11.0"
  wait          = true
  force_update  = true
  recreate_pods = true

  values = [
    yamlencode({
      clusterName = var.cluster_name
      replicaCount = 1

      # Kubernetes ClusterRole/Binding 생성 허용
      rbac = {
        create = true
      }

      serviceAccount = {
        create      = true
        name        = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = var.load_balancer_controller_role_arn
        }
      }
      enableServiceMutatorWebhook = false
    })
  ]
}

