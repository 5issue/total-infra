# ==============================================================================
# [보안 요구사항 2.2] VPC CNI 전용 IRSA Role (aws-node 파드 전용 권한)
# ==============================================================================
module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name_prefix      = "vpc-cni-irsa-"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}