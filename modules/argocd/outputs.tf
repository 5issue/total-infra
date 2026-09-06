output "release_name" {
  description = "ArgoCD Helm 릴리스 이름"
  value       = helm_release.argocd.name
}

output "namespace" {
  description = "ArgoCD 설치 네임스페이스"
  value       = helm_release.argocd.namespace
}