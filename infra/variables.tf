variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "cluster_name" {
  description = "EKS 클러스터 이름"
  type        = string
  default     = "test-eks"
}

variable "domain_name" {
  description = "Route 53 메인 도메인"
  type        = string
  default     = "cloudyim.store"
}

variable "project_name" {
  description = "프로젝트 이름"
  type        = string
  default     = "kurly-food"
}

# ALB DNS 주소용 변수 (기본값은 빈 문자열)
variable "alb_dns_name" {
  description = "K8s Ingress가 프로비저닝한 AWS ALB의 DNS 이름"
  type        = string
  default     = ""
}

variable "enable_waf" {
  description = "AWS WAF 활성화 여부 (초기 구축 완료 후 true로 전환)"
  type        = bool
  default     = false
}

variable "argocd_github_client_secret" {
  type        = string
  description = "GitHub OAuth Client Secret for Argo CD"
  sensitive   = true
}

variable "argocd_server_secretkey" {
  type        = string
  description = "Argo CD session encryption secret key (32+ chars)"
  sensitive   = true
}