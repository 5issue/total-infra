resource "aws_iam_role" "eks_cluster_access" {
  name                 = "eks-cluster-access"
  description          = "Role for team operators to access EKS with MFA condition (basic ops only)"
  max_session_duration = 43200

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

resource "aws_iam_policy" "eks_describe_cluster" {
  name        = "EKSDescribeClusterPolicy"
  description = "kubeconfig 갱신/클러스터 메타데이터 조회용 공용 정책 (팀원 3개 Role 공용)"

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

resource "aws_iam_role_policy_attachment" "eks_cluster_access_describe" {
  role       = aws_iam_role.eks_cluster_access.name
  policy_arn = aws_iam_policy.eks_describe_cluster.arn
}

resource "aws_iam_role" "db_admin_secret_reader" {
  name                 = "db-admin-secret-reader"
  description          = "jaehyeok, jongwon 전용 - DB 관리자 계정 Secret 조회 (MFA 필수)"
  max_session_duration = 43200 # 12시간

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeWithMFA"
        Effect = "Allow"
        Principal = {
          AWS = [
            "arn:aws:iam::596601390909:user/infra-jaehyeok",
            "arn:aws:iam::596601390909:user/infra-jongwon"
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

resource "aws_iam_role_policy_attachment" "db_admin_secret_reader_describe" {
  role       = aws_iam_role.db_admin_secret_reader.name
  policy_arn = aws_iam_policy.eks_describe_cluster.arn
}

resource "aws_iam_role" "rabbitmq_redis_secret_reader" {
  name                 = "rabbitmq-redis-secret-reader"
  description          = "jiyoon, jongwon 전용 - RabbitMQ/Redis Secret 조회 (MFA 필수)"
  max_session_duration = 43200 # 12시간

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAssumeWithMFA"
        Effect = "Allow"
        Principal = {
          AWS = [
            "arn:aws:iam::596601390909:user/infra-jiyoon",
            "arn:aws:iam::596601390909:user/infra-jongwon"
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

resource "aws_iam_role_policy_attachment" "rabbitmq_redis_secret_reader_describe" {
  role       = aws_iam_role.rabbitmq_redis_secret_reader.name
  policy_arn = aws_iam_policy.eks_describe_cluster.arn
}