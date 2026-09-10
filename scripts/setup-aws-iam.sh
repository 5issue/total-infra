#!/usr/bin/env bash
set -euo pipefail

TARGET_ACCOUNT_ID="596601390909"
REGION="ap-northeast-2"
PROFILE_NAME="target-infra"
AUTOMATION_USER="mgmt-automation-user"

echo "============================================================"
echo " AWS Automation Credential Setup (${TARGET_ACCOUNT_ID})"
echo " Target IAM User: ${AUTOMATION_USER}"
echo "============================================================"

# 1. mgmt 전용 Access Key / Secret Key 입력
read -rp "AWS Access Key ID (${AUTOMATION_USER}): " ACCESS_KEY
read -rsp "AWS Secret Access Key: " SECRET_KEY
echo ""

if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" ]]; then
  echo "[ERROR] Key 값이 비어 있습니다." >&2
  exit 1
fi

# 2. AWS CLI 프로파일 등록
echo "[INFO] AWS CLI 프로파일 '$PROFILE_NAME' 등록 중..."
aws configure set aws_access_key_id "$ACCESS_KEY" --profile "$PROFILE_NAME"
aws configure set aws_secret_access_key "$SECRET_KEY" --profile "$PROFILE_NAME"
aws configure set region "$REGION" --profile "$PROFILE_NAME"
aws configure set output json --profile "$PROFILE_NAME"

# 3. STS 인증 및 계정/유저 검증
echo "[INFO] STS Caller Identity 검증 중..."
CALLER_JSON=$(aws sts get-caller-identity --profile "$PROFILE_NAME" 2>/dev/null || true)

if [[ -z "$CALLER_JSON" ]]; then
  echo "[ERROR] 자격 증명 검증 실패: Access Key 또는 Secret Key를 확인하세요." >&2
  exit 1
fi

CHECK_ACCOUNT=$(echo "$CALLER_JSON" | grep -o '"Account": "[^"]*' | cut -d'"' -f4)
CHECK_ARN=$(echo "$CALLER_JSON" | grep -o '"Arn": "[^"]*' | cut -d'"' -f4)

if [[ "$CHECK_ACCOUNT" != "$TARGET_ACCOUNT_ID" ]]; then
  echo "[ERROR] 계정 불일치: 현재 계정($CHECK_ACCOUNT) != 대상 계정($TARGET_ACCOUNT_ID)" >&2
  exit 1
fi

echo "[SUCCESS] 자격 증명 확인 완료: $CHECK_ARN"
echo "============================================================"
echo " 설정 완료: 이제 Makefile의 배포 명령어가 ${AUTOMATION_USER} 권한으로 실행됩니다."
echo "============================================================"