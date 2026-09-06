# Frontend, Backend, AI 서비스 컨테이너 이미지 저장소

# ==============================================================================
# 서비스별 ECR 레포지토리 (Frontend, Backend, AI)
# ==============================================================================
locals {
  ecr_repositories = [
    # 공통 / 프론트 / AI
    "kurly-frontend",
    "kurly-ai-assistant",

    # 이커머스 도메인 (5개)
    "kurly-auth",
    "kurly-user",
    "kurly-order",
    "kurly-payment",
    "kurly-product",

    # 풀필먼트 도메인 (3개)
    "kurly-oms",
    "kurly-wms",
    "kurly-scm"
  ]
}

resource "aws_ecr_repository" "repos" {
  for_each             = toset(local.ecr_repositories)
  name                 = each.key
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = var.project_name
  }
}

# 최근 이미지 10개만 유지 (스토리지 비용 절감)
resource "aws_ecr_lifecycle_policy" "repos_policy" {
  for_each   = aws_ecr_repository.repos
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "최근 10개 이미지만 보관"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = 10
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}