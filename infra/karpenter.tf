resource "aws_iam_instance_profile" "karpenter_node" {
  name = "KarpenterNodeInstanceProfile-${module.eks.cluster_name}"
  role = module.karpenter.node_iam_role_name
}

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name                    = module.eks.cluster_name
  enable_irsa                     = true
  irsa_oidc_provider_arn          = module.eks.oidc_provider_arn
  irsa_namespace_service_accounts = ["karpenter:karpenter"]

  create_node_iam_role = true
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  enable_spot_termination = true
}

resource "helm_release" "karpenter" {
  depends_on = [module.eks, module.karpenter, aws_iam_instance_profile.karpenter_node]

  name             = "karpenter"
  namespace        = "karpenter"
  create_namespace = true
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.3.0"
  wait             = true

  values = [
    yamlencode({
      replicas = 1

      settings = {
        clusterName       = module.eks.cluster_name
        clusterEndpoint   = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
      }
      serviceAccount = {
        annotations = {
          "eks.amazonaws.com/role-arn" = module.karpenter.iam_role_arn
        }
      }
    })
  ]
}

# ----------------------------------------------------------------
# Karpenter ServiceAccount에 K8s API 조작 권한(ClusterRoleBinding) 부여
# ----------------------------------------------------------------
resource "kubernetes_cluster_role_binding_v1" "karpenter" {
  metadata {
    name = "karpenter-cluster-admin"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }

  subject {
    kind      = "ServiceAccount"
    name      = "karpenter"
    namespace = "karpenter"
  }

  depends_on = [
    helm_release.karpenter
  ]
}

# ----------------------------------------------------------------
# Karpenter CRD 리소스 적용 (중복 없이 1개만 유지)
# ----------------------------------------------------------------
resource "terraform_data" "karpenter_resources" {
  depends_on = [
    helm_release.karpenter,
    kubernetes_cluster_role_binding_v1.karpenter,
    null_resource.update_kubeconfig
  ]

  triggers_replace = [
    module.eks.cluster_endpoint
  ]

  provisioner "local-exec" {
    command = <<-EOT
      cat <<EOF | kubectl apply -f -
      ${templatefile("${path.module}/karpenter-resources.yaml.tftpl", {
        instance_profile_name = aws_iam_instance_profile.karpenter_node.name
        cluster_name          = module.eks.cluster_name
      })}
      EOF
    EOT
  }
}