output "ebs_csi_role_arn" {
  description = "EBS CSI Driver IAM Role ARN"
  value       = module.ebs_csi_irsa.iam_role_arn
}

output "addon_arn" {
  description = "EBS CSI Add-on ARN"
  value       = aws_eks_addon.ebs_csi.arn
}