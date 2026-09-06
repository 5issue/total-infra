#!/usr/bin/env bash
set -euo pipefail

TARGET_ACCOUNT_ID="596601390909"
REGION="ap-northeast-2"
PROFILE_NAME="target-infra"

# 등록 대상 IAM 유저 목록
ALLOWED_USERS=("infra-jaehyeok" "infra-jiyoon" "infra-jongwon" "infra-mingyu" "infra-youngheon")

echo "============================================================"
echo " AWS IAM Credential Setup for Infra (${TARGET_ACCOUNT_ID})"
echo "============================================================"
echo "등록 가능한 IAM 유저:"
for idx in "${!ALLOWED_USERS[@]}"; do
  echo "  $((idx+1))) ${ALLOWED_USERS[$idx]}"
done
echo "------------------------------------------------------------"

# 1. IAM 유저 선택
read -rp "사용할 IAM 유저 번호를 선택하세요 (1-${#ALLOWED_USERS[@]}): " USER_CHOICE
if ! [[ "$USER_CHOICE" =~ ^[1-5]$ ]]; then
  echo "[ERROR] 올바른 번호를 입력하세요." >&2
  exit 1
fi
SELECTED_USER="${ALLOWED_USERS[$((USER_CHOICE-1))]}"

# 2. Access Key / Secret Key 입력 (보안상 화면 미출력)
read -rp "AWS Access Key ID ($SELECTED_USER): " ACCESS_KEY
read -rsp "AWS Secret Access Key: " SECRET_KEY
echo ""

if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" ]]; then
  echo "[ERROR] Key 값이 비어 있습니다." >&2
  exit 1
fi

# 3. AWS CLI 프로파일 자동 등록
echo "[INFO] AWS CLI 프로파일 '$PROFILE_NAME' 등록 중..."
aws configure set aws_access_key_id "$ACCESS_KEY" --profile "$PROFILE_NAME"
aws configure set aws_secret_access_key "$SECRET_KEY" --profile "$PROFILE_NAME"
aws configure set region "$REGION" --profile "$PROFILE_NAME"
aws configure set output json --profile "$PROFILE_NAME"

# 4. STS로 인증 및 대상 계정/유저 검증
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
echo " 설정이 완료되었습니다."
echo " 이제 init/ 및 infra/ 폴더에서 실행되는 terraform 명령어는"
echo " 해당 IAM ($SELECTED_USER) 권한으로 자동 실행됩니다."
echo "============================================================"