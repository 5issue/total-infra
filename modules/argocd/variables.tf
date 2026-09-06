variable "argocd_chart_version" {
  description = "ArgoCD Helm Chart Version"
  type        = string
  default     = "10.1.2"
}

variable "argo_rollouts_chart_version" {
  description = "Argo Rollouts Helm Chart Version"
  type        = string
  default     = "2.38.0"
}
