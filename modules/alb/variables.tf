variable "cluster_name" {
  description = "EKS 클러스터 이름"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS 클러스터 엔드포인트"
  type        = string
}

variable "domain_name" {
  description = "Route 53 메인 도메인 이름"
  type        = string
}

variable "certificate_arn" {
  description = "ALB용 서울 리전(ap-northeast-2) ACM 인증서 ARN"
  type        = string
}

variable "load_balancer_controller_role_arn" {
  description = "AWS Load Balancer Controller의 IAM Role ARN"
  type        = string
}