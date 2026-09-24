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

# ==============================================================================
# [서비스별 IRSA] Backend & AI Services 전용 IAM Roles
# ==============================================================================

locals {
  # 서비스 목록 및 네임스페이스 매핑
  app_services = {
    # Backend Services
    auth    = { namespace = "backend", sa_name = "auth-sa" }
    order   = { namespace = "backend", sa_name = "order-sa" }
    payment = { namespace = "backend", sa_name = "payment-sa" }
    product = { namespace = "backend", sa_name = "product-sa" }
    user    = { namespace = "backend", sa_name = "user-sa" }
    oms     = { namespace = "backend", sa_name = "oms-sa" }
    scm     = { namespace = "backend", sa_name = "scm-sa" }
    wms     = { namespace = "backend", sa_name = "wms-sa" }

    # AI Service
    ai      = { namespace = "backend", sa_name = "ai-sa" }
  }
}

# 1. 공통 IRSA IAM Roles 일괄 생성
module "workload_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  for_each = local.app_services

  role_name = "${each.key}-service-irsa"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["${each.value.namespace}:${each.value.sa_name}"]
    }
  }

  tags = {
    Service     = each.key
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}

# ==============================================================================
# auth-service-irsa 전용 KMS 서명 및 공개키 조회 정책 연결
# ==============================================================================
resource "aws_iam_role_policy" "auth_kms_jwt_policy" {
  name = "AuthKmsJwtSignPolicy"
  role = module.workload_irsa["auth"].iam_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:GetPublicKey",
          "kms:Sign",
          "kms:DescribeKey",
          "kms:Verify"
        ]
        Resource = "*"
      }
    ]
  })
}