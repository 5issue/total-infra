# total-infra/infra/grafana.tf

module "grafana" {
  source = "../modules/grafana"

  # EKS 클러스터가 완전히 생성된 후 프로비저닝되도록 의존성 설정
  depends_on = [
    module.eks
  ]
}