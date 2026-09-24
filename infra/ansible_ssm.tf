# ==============================================================================
# Ansible SSM 임시 페이로드 S3 통신용 IAM 정책
# ==============================================================================

# 1. 워커 노드(EKS MNG / Karpenter Spot) 공통 S3 접근 정책
resource "aws_iam_policy" "node_ansible_s3" {
  name        = "${var.cluster_name}-node-ansible-s3"
  description = "Allow EKS worker nodes and Karpenter spot nodes to access Ansible temp files in S3"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowNodeAnsibleS3Payload"
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:GetEncryptionConfiguration", # SSM Session Manager 암호화 검증 권한
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:PutObjectAcl",              # SSM 로그 업로드 시 ACL 적용 권한
          "s3:DeleteObject"
        ]
        Resource = [
          "arn:aws:s3:::kurly-security-logs-${var.aws_region}",
          "arn:aws:s3:::kurly-security-logs-${var.aws_region}/*"
        ]
      }
    ]
  })
}

# 2. Karpenter 노드 역할에 정책 자동 연결 
resource "aws_iam_role_policy_attachment" "karpenter_node_ansible_s3" {
  role       = module.karpenter.node_iam_role_name
  policy_arn = aws_iam_policy.node_ansible_s3.arn
}

# 3. NAT 인스턴스 정책 연결
resource "aws_iam_role_policy_attachment" "nat_ansible_s3" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = aws_iam_policy.node_ansible_s3.arn
}