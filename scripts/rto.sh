#!/bin/bash
export AWS_PROFILE=target-infra

# 1. 현재 존재하는 MNG 노드 자동 탐색
EXISTING_NODES=$(kubectl get nodes -l eks.amazonaws.com/nodegroup -o jsonpath='{.items[*].metadata.name}')
TARGET_NODE=$(kubectl get nodes -l eks.amazonaws.com/nodegroup -o jsonpath='{.items[0].metadata.name}')

if [ -z "$TARGET_NODE" ]; then
  echo ">>> [에러] 살아있는 MNG 노드를 찾을 수 없습니다."
  exit 1
fi

INSTANCE_ID=$(kubectl get node $TARGET_NODE -o jsonpath='{.spec.providerID}' | cut -d'/' -f5)

echo "============================================="
echo "종료 대상 MNG 노드: $TARGET_NODE ($INSTANCE_ID)"
echo "기존 MNG 노드 목록: $EXISTING_NODES"

# 2. 강제 종료 실행 및 T0 기록
T0_STR=$(date +"%H:%M:%S")
T0_SEC=$(date +%s)
echo ">>> [T0] 인스턴스 강제 종료 시각: $T0_STR"
aws ec2 terminate-instances --instance-ids $INSTANCE_ID > /dev/null

echo ">>> ASG 신규 노드 프로비저닝 및 Ready 대기 중..."

# 3. 새 노드 탐색 및 Ready 대기 루프
NEW_NODE=""
while true; do
  CURRENT_NODES=$(kubectl get nodes -l eks.amazonaws.com/nodegroup -o jsonpath='{.items[*].metadata.name}')
  
  for n in $CURRENT_NODES; do
    if [[ ! " $EXISTING_NODES " =~ " $n " ]]; then
      NEW_NODE=$n
      break
    fi
  done

  if [ -n "$NEW_NODE" ]; then
    READY_STATUS=$(kubectl get node "$NEW_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [ "$READY_STATUS" == "True" ]; then
      T1_STR=$(date +"%H:%M:%S")
      T1_SEC=$(date +%s)
      RTO=$((T1_SEC - T0_SEC))
      break
    fi
  fi
  sleep 2
done

# 4. 최종 결과 출력
echo "============================================="
echo ">>> [MNG Node RTO 측정 완료]"
echo "신규 생성 노드: $NEW_NODE"
echo "인스턴스 강제 종료 시각 (T0): $T0_STR"
echo "새 노드 Ready 완료 시각 (T1): $T1_STR"
echo "총 소요 시간 (Node RTO): ${RTO}초 ($((RTO / 60))분 $((RTO % 60))초)"
echo "============================================="
