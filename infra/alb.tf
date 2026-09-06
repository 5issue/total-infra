# 1. AWS Load Balancer Controller용 IRSA Role 생성
module "load_balancer_controller_irsa_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.30"

  role_name                              = "load-balancer-controller-${module.eks.cluster_name}"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    ex = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

data "aws_acm_certificate" "alb" {
  domain      = var.domain_name
  statuses    = ["ISSUED"]
  most_recent = true
}

# 2. ALB 서브모듈 호출 (IAM Role ARN을 인자로 전달)
module "alb" {
  source                            = "../modules/alb"

  cluster_name                      = module.eks.cluster_name
  cluster_endpoint                  = module.eks.cluster_endpoint
  domain_name                       = var.domain_name
  certificate_arn                   = data.aws_acm_certificate.alb.arn
  load_balancer_controller_role_arn = module.load_balancer_controller_irsa_role.iam_role_arn

  depends_on = [
    module.eks,
    null_resource.update_kubeconfig,
    aws_subnet.public_2a,
    aws_subnet.public_2c,
    aws_internet_gateway.igw
  ]
}