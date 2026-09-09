# ==============================================================================
# 1. 콘솔(웹) 로그인 시에만 MFA를 강제하고 CLI 배포는 허용하는 정책
# ==============================================================================
resource "aws_iam_policy" "enforce_mfa" {
  name        = "EnforceMFAPolicy"
  description = "웹 콘솔 로그인 시 MFA를 강제하고, CLI/Terraform 작업은 허용하는 정책"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 1) 자신의 암호 변경 및 MFA 기기 등록/관리는 MFA 없이도 허용
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
      # 3) [수정된 부분] 콘솔 웹 세션인데 MFA를 거치지 않은 경우에만 차단 (Deny)
      {
        Sid       = "BlockConsoleActionsUnlessSignedInWithMFA"
        Effect    = "Deny"
        # =========================================================================
        # [핵심] 테라폼 배포 및 KMS 호출이 Deny에 걸리지 않도록 NotAction에 추가
        # =========================================================================
        NotAction = [
          "iam:CreateVirtualMFADevice",
          "iam:DeleteVirtualMFADevice",
          "iam:EnableMFADevice",
          "iam:ResyncMFADevice",
          "iam:ChangePassword",
          "iam:GetUser",
          "iam:ListVirtualMFADevices",
          "iam:ListMFADevices",
          "iam:ListUsers",
          "iam:PassRole",
          "iam:GetRole",
          "iam:ListAttachedRolePolicies",
          "iam:ListRolePolicies",
          "iam:ListInstanceProfiles",
          "kms:*",
          "eks:*",
          "ec2:*",
          "s3:*",
          "ssm:*"
        ]
        Resource = "*"
        Condition = {
          # MFA가 인증되지 않은 상태이면서
          BoolIfExists = {
            "aws:MultiFactorAuthPresent" = "false"
          }
          # 임시 세션 토큰이 발급된 상태(즉, 콘솔/STS 로그인 세션)일 때만 Deny 발동
          # -> 장기 Access Key를 사용하는 터미널/테라폼은 이 조건에 걸리지 않고 통과됨!
          Null = {
            "aws:TokenIssueTime" = "false"
          }
        }
      }
    ]
  })
}

# 유저 목록 정의
locals {
  target_users = [
    "infra-jaehyeok",
    "infra-jiyoon",
    "infra-jongwon",
    "infra-mingyu",
    "infra-youngheon"
  ]
}

# 정책 연결
resource "aws_iam_user_policy_attachment" "user_mfa_attach" {
  for_each   = toset(local.target_users)
  user       = each.value
  policy_arn = aws_iam_policy.enforce_mfa.arn
}