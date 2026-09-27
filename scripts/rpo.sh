# 타깃 엔드포인트 (보내주신 Ingress의 실제 도메인과 서비스 경로)
ENDPOINT="https://dev.cloudyim.store"
TOTAL_FAIL=0
TOTAL_REQ=180 # MNG 180초, Karpenter 120초

echo ">>> [RPO 측정 시작] 1초 간격으로 트래픽 요청 전송 중..."

for i in $(seq 1 $TOTAL_REQ); do
  # HTTP 상태 코드만 추출 (2초 타임아웃)
  STATUS=$(curl -o /dev/null -s -w "%{http_code}" --connect-timeout 2 "$ENDPOINT")
  
  # 200~399 범위가 아니면(502 Bad Gateway 등 에러 발생 시) 실패 카운트 증가
  if [[ "$STATUS" -lt 200 || "$STATUS" -ge 400 ]]; then
    echo "[$(date +%H:%M:%S)] 요청 실패 감지! HTTP 상태 코드: $STATUS"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
  sleep 1
done

echo "======================================"
echo ">>> [RPO 측정 결과]"
echo "총 요청 수: $TOTAL_REQ 건"
echo "유실/실패 요청 수: $TOTAL_FAIL 건"
echo "======================================"