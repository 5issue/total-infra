#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="test-eks"
REGION="ap-northeast-2"
PROFILE_NAME="eks-dev"

echo "============================================================"
echo " 백엔드팀 EKS 접속 환경 자동 설정 (${CLUSTER_NAME})"
echo "============================================================"

# 1. 자격증명 입력 받기
read -rp "AWS Access Key ID: " RAW_ACCESS_KEY
ACCESS_KEY=$(echo "$RAW_ACCESS_KEY" | xargs)

read -rsp "AWS Secret Access Key: " RAW_SECRET_KEY
SECRET_KEY=$(echo "$RAW_SECRET_KEY" | xargs)
echo ""

if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" ]]; then
  echo "[ERROR] Access Key와 Secret Key를 모두 입력해야 합니다." >&2
  exit 1
fi

# 2. AWS CLI 프로필 설정
echo "[INFO] ~/.aws 프로필 등록 중 ($PROFILE_NAME)..."
aws configure set aws_access_key_id "$ACCESS_KEY" --profile "$PROFILE_NAME"
aws configure set aws_secret_access_key "$SECRET_KEY" --profile "$PROFILE_NAME"
aws configure set region "$REGION" --profile "$PROFILE_NAME"
aws configure set output json --profile "$PROFILE_NAME"

# 3. Kubeconfig 자동 갱신
echo "[INFO] EKS 클러스터 접속 정보(kubeconfig) 갱신 중..."
aws eks update-kubeconfig \
  --region "$REGION" \
  --name "$CLUSTER_NAME" \
  --profile "$PROFILE_NAME"

echo ""
echo "============================================================"
echo " [SUCCESS] 설정이 완료되었습니다!"
echo " 아래 명령어로 Pod 로그 확인 및 접속이 가능합니다:"
echo ""
echo " 1) Pod 목록 확인:    kubectl get pods -n dev"
echo " 2) 로그 실시간 확인:  kubectl logs -f <pod-name> -n dev"
echo " 3) 컨테이너 접속:    kubectl exec -it <pod-name> -n dev -- /bin/sh"
echo "============================================================"