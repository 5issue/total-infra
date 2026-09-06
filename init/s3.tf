# 상태파일(tfstate) 백엔드 버킷 및 정적/이미지 관리용 S3 버킷

# ==============================================================================
# 1. Terraform 원격 상태 파일(State) 백엔드 버킷 및 잠금 테이블
# ==============================================================================
resource "aws_s3_bucket" "tfstate" {
  bucket        = "issue-tfstate-${var.aws_region}"
  force_destroy = false

  tags = {
    Name        = "issue-tfstate"
    Environment = "Shared"
    ManagedBy   = "Terraform"
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# tfstate 버킷 퍼블릭 액세스 4종 완전 차단
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# tfstate 버킷 ACL 소유자 한정 (BucketOwnerEnforced)
resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_dynamodb_table" "tfstate_lock" {
  name         = "issue-tfstate-locks"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    Name        = "issue-tfstate-locks"
    Environment = "Shared"
  }
}

# ==============================================================================
# 2. 이미지 및 정적 자산 관리용 S3 버킷 (pgvector 연동용 등)
# ==============================================================================
resource "aws_s3_bucket" "static_assets" {
  bucket        = "${var.project_name}-static-assets"
  force_destroy = true

  tags = {
    Name = "${var.project_name}-static-assets"
  }
}

# ------------------------------------------------------------------------------
# [보안 요구사항 4.3] static_assets 버킷 SSE-S3 기본 암호화 추가
# ------------------------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# static_assets 버킷 ACL 소유자 한정 (BucketOwnerEnforced)
resource "aws_s3_bucket_ownership_controls" "static_assets" {
  bucket = aws_s3_bucket.static_assets.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ==============================================================================
# S3 버킷 내 기본 폴더 생성 (선택 사항)
# ==============================================================================
resource "aws_s3_object" "image_folder" {
  bucket  = aws_s3_bucket.static_assets.id
  key     = "image/"
  content = ""
}

resource "aws_s3_object" "docs_folder" {
  bucket  = aws_s3_bucket.static_assets.id
  key     = "docs/"
  content = ""
}