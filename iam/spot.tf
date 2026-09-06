# ----------------------------------------------------------------
# EC2 Spot 인스턴스 라이프사이클 관리를 위한 AWS Service-Linked Role
# 계정당 1회 생성되며, Karpenter가 스팟 인스턴스를 프로비저닝할 때 필수입니다.
# ----------------------------------------------------------------
resource "aws_iam_service_linked_role" "spot" {
  aws_service_name = "spot.amazonaws.com"
  description      = "Service-linked role for EC2 Spot Instances used by Karpenter"

  # 이미 계정에 존재할 경우(콘솔/CLI 등으로 생성된 이력) 에러로 중단되지 않도록 보호
  lifecycle {
    ignore_changes = all
  }
}