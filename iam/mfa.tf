# ==============================================================================
#  사람(엔지니어 5명) 전용: 엄격한 MFA 강제 정책
# - MFA 미인증 시 본인 MFA 등록 외 모든 콘솔/CLI API 작업 전면 차단
# - (보안팀 요구사항)
# ==============================================================================
resource "aws_iam_policy" "enforce_mfa" {
  name        = "EnforceMFAPolicy"
  description = "사람 계정 전용: MFA 미인증 시 본인 MFA 기기 등록 외 모든 작업 전면 차단"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 1) 자신의 MFA 기기 등록 및 암호 변경만 허용
      {
        Sid    = "AllowViewAccountInfoAndManageOwnMFA"
        Effect = "Allow"
        Action = [
          "iam:CreateVirtualMFADevice",
          "iam:DeleteVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ResyncMFADevice",
          "iam:ChangePassword",
          "iam:GetUser",
          "iam:ListVirtualMFADevices",
          "iam:ListMFADevices"
        ]
        Resource = [
          "arn:aws:iam::*:user/$${aws:username}",
          "arn:aws:iam::*:mfa/$${aws:username}"
        ]
      },
      # 2) 콘솔 화면 조회를 위한 기본 정보 조회 허용
      {
        Sid    = "AllowListMFADevices"
        Effect = "Allow"
        Action = [
          "iam:ListVirtualMFADevices",
          "iam:ListUsers"
        ]
        Resource = "*"
      },
      # 3) MFA 미인증 시 모든 AWS 작업 차단 (Deny)
      {
        Sid       = "BlockAllActionsUnlessSignedInWithMFA"
        Effect    = "Deny"
        NotAction = [
          "iam:CreateVirtualMFADevice",
          "iam:DeleteVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ResyncMFADevice",
          "iam:ChangePassword",
          "iam:GetUser",
          "iam:ListVirtualMFADevices",
          "iam:ListMFADevices",
          "iam:ListUsers"
        ]
        Resource = "*"
        Condition = {
          BoolIfExists = {
            "aws:MultiFactorAuthPresent" = "false"
          }
        }
      }
    ]
  })
}

# 대상 사람 계정 목록
locals {
  target_users = [
    "infra-jaehyeok",
    "infra-jiyoon",
    "infra-jongwon",
    "infra-mingyu",
    "infra-youngheon"
  ]
}

# 사람 계정 5명에게만 엄격한 MFA 정책 연결
resource "aws_iam_user_policy_attachment" "user_mfa_attach" {
  for_each   = toset(local.target_users)
  user       = each.value
  policy_arn = aws_iam_policy.enforce_mfa.arn
}





