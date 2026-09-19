#!/usr/bin/env bash
set -euo pipefail

TARGET_ACCOUNT_ID="596601390909"
REGION="ap-northeast-2"
PROFILE_NAME="target-infra"

echo "============================================================"
echo " AWS Personal AssumeRole & MFA Setup (${TARGET_ACCOUNT_ID})"
echo "============================================================"

while true; do
    # 1. 개인 IAM 정보 및 Role ARN 입력 받기 (앞뒤 띄어쓰기 자동 제거 적용)
    read -rp "AWS Access Key ID (Personal): " RAW_ACCESS_KEY
    ACCESS_KEY=$(echo "$RAW_ACCESS_KEY" | xargs)

    read -rsp "AWS Secret Access Key (Personal): " RAW_SECRET_KEY
    SECRET_KEY=$(echo "$RAW_SECRET_KEY" | xargs)
    echo ""

    read -rp "MFA Device ARN (예: arn:aws:iam::596601390909:mfa/Jongwon_OTP): " RAW_MFA_ARN
    MFA_ARN=$(echo "$RAW_MFA_ARN" | xargs)

    read -rp "접속할 Role ARN (예: arn:aws:iam::596601390909:role/target-infra): " RAW_ROLE_ARN
    ROLE_ARN=$(echo "$RAW_ROLE_ARN" | xargs)

    # 시크릿 키 마스킹 처리
    MASKED_SECRET="${SECRET_KEY:0:4}********"

    echo ""
    echo "------------------------------------------------------------"
    echo " [입력하신 정보 확인]"
    echo " - Access Key ID     : ${ACCESS_KEY}"
    echo " - Secret Access Key : ${MASKED_SECRET}"
    echo " - MFA Device ARN    : ${MFA_ARN}"
    echo " - Role ARN          : ${ROLE_ARN}"
    echo "------------------------------------------------------------"

    read -rp "입력한 정보가 모두 정확합니까? (y/n): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        break
    else
        echo "[INFO] 정보를 다시 입력합니다. 차근차근 다시 적어주세요."
        echo ""
    fi
done

if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" || -z "$MFA_ARN" || -z "$ROLE_ARN" ]]; then
  echo "[ERROR] 필수 입력값이 비어 있습니다." >&2
  exit 1
fi

# 2. 본인 개인 액세스 키를 [personal] 프로필로 credentials에 저장
echo "[INFO] 개인 자격증명 저장 중..."
aws configure set aws_access_key_id "$ACCESS_KEY" --profile "personal"
aws configure set aws_secret_access_key "$SECRET_KEY" --profile "personal"
aws configure set region "$REGION" --profile "personal"
aws configure set output json --profile "personal"

# 3. target-infra 프로필에 AssumeRole 설정 등록 (config)
echo "[INFO] ~/.aws/config 에 '$PROFILE_NAME' AssumeRole 프로필 설정 중..."
aws configure set source_profile "personal" --profile "$PROFILE_NAME"
aws configure set role_arn "$ROLE_ARN" --profile "$PROFILE_NAME"
aws configure set mfa_serial "$MFA_ARN" --profile "$PROFILE_NAME"
aws configure set region "$REGION" --profile "$PROFILE_NAME"
aws configure set output json --profile "$PROFILE_NAME"

python3 -c '
import os
path = os.path.expanduser("~/.aws/config")
if os.path.exists(path):
    with open(path, "r") as f:
        content = f.read()
    
    # [profile personal] 바로 앞에 있는 빈 줄이나 공백을 찾아 제거
    import re
    cleaned = re.sub(r"\n\s*\n(?=\[profile personal\])", "\n", content)
    
    with open(path, "w") as f:
        f.write(cleaned)
' 2>/dev/null || true

# 4. 최초 1회 MFA 세션 토큰 발급 및 캐시 생성
echo ""
echo "============================================================"
echo " [INFO] 최초 1회 MFA 세션 인증을 진행합니다."
echo " 휴대폰의 OTP 인증 번호 6자리를 입력해주세요."
echo "============================================================"

if aws sts get-caller-identity --profile "$PROFILE_NAME"; then
    echo ""
    echo "============================================================"
    echo " [SUCCESS] 최초 MFA 인증 및 설정 완료!"
    echo " 이제부터 배포(apply) 시 세션이 만료되면 AWS CLI가 자동으로"
    echo " 'Enter MFA code for...' 문구를 띄워줍니다."
    echo "============================================================"

    # target-infra 프로필로 발급된 임시 세션을 현재 쉘 환경 변수로 내보내기
    eval $(aws configure export-credentials --profile "$PROFILE_NAME" --format env)
    echo " [INFO] 현재 터미널 세션에 AWS 임시 자격 증명이 적용되었습니다."
else
    echo "[ERROR] MFA 인증에 실패했습니다. 입력하신 정보를 다시 확인하고 스크립트를 재실행해주세요." >&2
    exit 1
fi