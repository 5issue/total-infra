# # ==============================================================================
# # EKS 클러스터 및 Karpenter 배포 완료 후 보안 점검 자동 트리거 & Crontab 등록
# # ==============================================================================

# resource "null_resource" "security_audit_automation" {
#   # 클러스터 엔드포인트 및 카펜터 CRD 배포가 완료된 시점을 트리거로 설정
#   triggers = {
#     cluster_endpoint    = module.eks.cluster_endpoint
#     karpenter_resources = terraform_data.karpenter_resources.id
#   }

#   depends_on = [
#     module.eks,
#     terraform_data.karpenter_resources,
#     null_resource.update_kubeconfig
#   ]

#   provisioner "local-exec" {
#     command = <<-EOT
#       set -e
#       echo "=== [DevSecOps] 보안 감사 파이프라인 자동 연동 시작 ==="

#       AUDIT_DIR="/home/user1/security-audit"
#       RUN_SCRIPT="$AUDIT_DIR/run-audit.sh"

#       # 1. security-audit 디렉터리 및 실행 스크립트 존재 여부 확인
#       if [ ! -f "$RUN_SCRIPT" ]; then
#         echo "경고: $RUN_SCRIPT 파일을 찾을 수 없습니다. 보안점검 자동 실행을 건너뜁니다."
#         exit 0
#       fi

#       chmod +x "$RUN_SCRIPT"

#       # 2. [정기 점검 등록] 주간 Crontab 등록 (매주 월요일 15:00)
#       CRON_SCHEDULE="0 15 * * 1"
#       CRON_ENTRY="$CRON_SCHEDULE $RUN_SCRIPT"

#       # 기존 crontab에서 동일한 스크립트 라인 제거 후 새 스케줄로 등록/갱신
#       CURRENT_CRON=$(crontab -l 2>/dev/null | grep -Fv "$RUN_SCRIPT" || true)

#       if [ -z "$CURRENT_CRON" ]; then
#         echo "$CRON_ENTRY" | crontab -
#       else
#         printf "%s\n%s\n" "$CURRENT_CRON" "$CRON_ENTRY" | crontab -
#       fi
#       echo ">> 정기 보안점검 CronJob 등록/갱신 완료: $CRON_SCHEDULE"

#       # 3. [즉시 최초 점검] 노드 부팅 및 SSM Agent 등록 대기
#       echo ">> 신규 노드의 SSM 에이전트 등록 대기 (60초)..."
#       sleep 60

#       echo ">> 초기 배포 보안 점검 1회 즉시 실행..."
#       "$RUN_SCRIPT" || echo ">> 경고: 초기 점검 실행 중 일부 항목 주의 발생 (로그 확인 필요)"

#       echo "=== [DevSecOps] 보안 감사 연동 완료 ==="
#     EOT
#   }
# }