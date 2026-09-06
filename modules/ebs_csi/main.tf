# 1. EBS CSI Driver 전용 IRSA (IAM Role) 생성
module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name             = "${var.cluster_name}-ebs-csi-role"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
}

# 2. EKS EBS CSI Driver 애드온 설치
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = var.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  addon_version            = null # null 지정 시 AWS 권장 최신 안정 버전 자동 적용
  service_account_role_arn = module.ebs_csi_irsa.iam_role_arn

  # CNPG 등 Stateful 워크로드가 볼륨 조작 시 충돌 방지
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

# 3. K8s 기본 gp3 StorageClass 설정 (WaitForFirstConsumer 옵션으로 다중 AZ 볼륨 스케줄링 보장)
resource "kubernetes_annotations" "disable_gp2_default" {
  depends_on  = [aws_eks_addon.ebs_csi]
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"

  metadata {
    name = "gp2"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  force = true
}

resource "kubernetes_storage_class_v1" "gp3_default" {
  depends_on = [kubernetes_annotations.disable_gp2_default]

  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }
}