output "eks_cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS 클러스터 API 서버 엔드포인트 URL"
  value       = module.eks.cluster_endpoint
}

output "workload_publication_role_arn" {
  description = "IAM role assumed from target-infra for workload material publication"
  value       = aws_iam_role.workload_publication.arn
}

output "nat_instance_2a_id" {
  description = "AZ-2a NAT Instance ID"
  value       = aws_instance.nat_instance_2a.id
}

output "nat_instance_2c_id" {
  description = "AZ-2c NAT Instance ID"
  value       = aws_instance.nat_instance_2c.id
}

output "service_url" {
  description = "서비스 접속 도메인 URL"
  value       = "https://${var.domain_name}"
}

output "grafana_url" {
  description = "Grafana 접속 URL"
  value       = "https://grafana.${var.domain_name}"
}

output "argocd_url" {
  description = "ArgoCD 접속 URL"
  value       = "https://argocd.${var.domain_name}"
}

# Output (Ingress 어노테이션에 전달할 ARN)
output "waf_web_acl_arn" {
  description = "생성된 WAF Web ACL ARN (Ingress 어노테이션에 사용)"
  value       = var.enable_waf ? aws_wafv2_web_acl.alb_waf[0].arn : null
}

output "auth_jwt_kms_key_id" {
  value       = aws_kms_alias.auth_jwt_signing.name
  description = "auth-service의 JWT_KMS_KEY_ID 환경변수에 넣을 값"
}

output "auth_kms_irsa_role_arn" {
  value       = module.workload_irsa["auth"].iam_role_arn
  description = "auth-service-sa ServiceAccount의 eks.amazonaws.com/role-arn 어노테이션에 넣을 값"
}