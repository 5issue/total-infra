# -----------------------------------------------------------------------------
# 팀원 5인 전용 EKS 운영/DB 작업 IAM Role (MFA 필수)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "eks_cluster_access" {
  name        = "eks-cluster-access"
  description = "Role for team operators to access EKS with MFA condition"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeWithMFA"
        Effect = "Allow"
        Principal = {
          AWS = [
            "arn:aws:iam::596601390909:user/infra-jongwon",
            "arn:aws:iam::596601390909:user/infra-youngheon",
            "arn:aws:iam::596601390909:user/infra-mingyu",
            "arn:aws:iam::596601390909:user/infra-jaehyeok",
            "arn:aws:iam::596601390909:user/infra-jiyoon"
          ]
        }
        Action = "sts:AssumeRole"
        Condition = {
          Bool = {
            "aws:MultiFactorAuthPresent" = "true"
          }
        }
      }
    ]
  })
}

# kubeconfig 갱신 및 클러스터 메타데이터 조회를 위한 기본 정책 연결
resource "aws_iam_role_policy" "eks_cluster_access_describe" {
  name = "EKSDescribeClusterPolicy"
  role = aws_iam_role.eks_cluster_access.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]
        Resource = "*"
      }
    ]
  })
}