# 클라우드 인프라 운영 매뉴얼 및 위기 대응 가이드

## 1. 운영 환경 개요

### 1.1 기본 아키텍처 스펙

* **관리 리전:** AWS Seoul (`ap-northeast-2`) / CloudFront & WAF (`us-east-1`)

* **컨트롤 플레인:** Amazon EKS v1.36 (`test-eks`)

* **컴퓨팅 풀:**

  * **Static Core:** EKS MNG `t4g.large` (ARM64 AL2023) On-Demand 2대 고정

  * **Dynamic Spot:** Karpenter v1 기반 Spot 인스턴스 (최대 2대, 65% 비용 절감 풀)

* **네트워크 관문:** `t4g.micro` Multi-AZ NAT 인스턴스 2대 (Managed NAT 대체)

* **인그레스:** `main-alb-group` 단일 통합 ALB (6개 네임스페이스 Ingress 통합)

* **스토리지:** In-Cluster Stateful PVC 총 70GiB (RabbitMQ 15G, Redis 5G, MySQL 30G, PG 20G)

### 1.2 IaC 레이어 구조 (Make 오케스트레이션)

상태 충돌 방지 및 최소 권한 원칙(Least Privilege)에 따라 4단계 격리 스택으로 관리됩니다.

| 계층 (디렉터리) | 관리 리소스 | 진입 명령어 |
| :--- | :--- | :--- |
| **Setup** | 로컬 IAM 프로파일 인증 및 CLI 세션 구성 | `make iam-setup` |
| **IAM (`iam/`)** | KMS 마스터 키, Config 보안 규칙, MFA, Spot SLR | `make iam-plan` / `make iam` |
| **Init (`init/`)** | S3 State 백엔드, DynamoDB Lock, ECR, ACM 인증서 | `make base-plan` / `make base` |
| **Infra (`infra/`)** | VPC, NAT 인스턴스, EKS, Karpenter, ALB, WAF | `make plan` / `make apply` |
| **Scheduler (`scheduler/`)** | FinOps용 야간/주말 리소스 절감 Lambda | `make scheduler-plan` / `make scheduler` |

## 2. 정기 점검 체크리스트

### 2.1 EKS 클러스터 및 컴퓨팅 노드 점검 (Daily)

```
# 1. 클러스터 인증 토큰 및 kubeconfig 동기화
aws eks update-kubeconfig --region ap-northeast-2 --name test-eks --profile target-infra

# 2. 노드 풀 이원화(MNG 온디맨드 2대 + Karpenter 스팟) 가용성 확인
kubectl get nodes -L karpenter.sh/capacity-type,node.kubernetes.io/instance-type,kubernetes.io/arch

# 3. Karpenter 컨트롤러 상태 및 NodePool 리소스 확인
kubectl get nodepool,ec2nodeclass
kubectl top nodes

```

### 2.2 네트워크 관문 및 스토리지 점검 (Weekly)

```
# 1. Multi-AZ NAT 인스턴스(t4g.micro 2대) 구동 상태 확인
aws ec2 describe-instances --profile target-infra --region ap-northeast-2 \
  --filters "Name=tag:Name,Values=*nat*" "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].[InstanceId,State.Name,Placement.AvailabilityZone]" --output table

# 2. 단일 통합 ALB 타깃 그룹 바인딩 헬스 체크
kubectl get targetgroupbindings -A

# 3. Stateful PVC 스토리지(70GiB) 바운드 확인
kubectl get pvc -A | grep -v "Bound"
```

### 2.3 보안 및 워크로드 시크릿 정합성 점검 (On-Demand)

```
# 1. AWS Config IAM Access Key 60일 회전 규정 준수 확인
aws configservice get-compliance-details-by-config-rule \
  --config-rule-name access-keys-rotated \
  --compliance-types NON_COMPLIANT --profile target-infra --region ap-northeast-2

# 2. Makefile 기반 워크로드 시크릿 일괄 무결성 검증
make rabbitmq-credential-verify
make rabbitmq-wms-credential-verify
make rabbitmq-oms-credential-verify
make redis-credential-verify
```

## 3. 배포 및 변경 관리 절차

### 3.1 신규 인프라 3-Step 배포 파이프라인

```
# 1. 전역 IAM 및 Init 공통 기반 선제 배포
make iam
make base

# 2. 메인 인프라 3-Step 연속 프로비저닝 (VPC/EKS -> ALB 대기 -> CloudFront/Route53 연동)
make plan
make apply

# 3. 애플리케이션 부트스트랩
make workload-publication-bootstrap \
  ENV=production \
  KUBECTL_CONTEXT=arn:aws:eks:ap-northeast-2:596601390909:cluster/test-eks

# 4. FinOps 스케줄러 배포
make scheduler
```

### 3.2 애플리케이션 시크릿 개별 게시 절차

```
# RabbitMQ Core / WMS / OMS
make rabbitmq-credential-publish
make rabbitmq-wms-credential-publish
make rabbitmq-oms-credential-publish

# Redis
make redis-credential-publish
```

## 4. 위기 대응 (Incident Response Runbook)

### 시나리오 1: MNG 노드 하드웨어 장애 및 노드 교체

특정 노드에 OS 장애, 메모리 누수, 패치 필요 시 워크로드를 안전하게 퇴거시킵니다.

```
# 1. 장애 노드로의 신규 파드 스케줄링 차단
kubectl cordon <노드이름>

# 2. 노드 내 파드 안전 퇴거 (DaemonSet 무시 및 로컬 임시 데이터 삭제 허용)
kubectl drain <노드이름> --ignore-daemonsets --delete-emptydir-data --force

# 3. 노드 정상화 확인 후 스케줄링 차단 해제
kubectl uncordon <노드이름>
```

### 시나리오 2: Karpenter Spot 강제 인터럽트 발생

* **자동화 확인:** EventBridge 및 SQS(`interruptionQueue`)를 통해 수신된 2분 전 중단 알림을 바탕으로 파드가 다른 노드로 자동 드레인되는지 확인합니다.

* **수동 긴급 퇴거:** 특정 스팟 노드가 응답하지 않을 경우 즉시 노드 리소스를 삭제하여 강제 축출합니다.

```
kubectl delete node <스팟-노드이름>
```

### 시나리오 3: In-Cluster DB 볼륨 장애 복구

* **PostgreSQL (CNPG):**

  `cnpg-backup-role`을 통해 S3(`cnpg-backup-*`)에 WAL 및 일일 백업이 저장되어 있습니다. 복원 시 클러스터 매니페스트의 `bootstrap.recovery` 설정을 통해 최신 타임스탬프로 PITR(시점 복구)을 진행합니다.

* **MySQL (MOCO):**

  `moco-backup-role`을 통해 S3(`moco-backup-*`)에 저장된 스냅샷 덤프를 기반으로 복원 Job을 실행합니다.

### 시나리오 4: Terraform State 충돌 및 잠금(Lock) 발생

네트워크 순단이나 프로세스 비정상 종료로 DynamoDB(`issue-tfstate-locks`)에 락이 남은 경우:

```
# 에러 메시지에 출력된 Lock ID 확인 후 강제 해제
cd infra && terraform force-unlock <LockID>
```

### 시나리오 5: 전체 인프라 긴급 롤백 및 안전 파기 (`make destroy`)

리소스 종속성 데드락(ENI, K8s Finalizer, 보안 그룹 락)을 방지하기 위해 반드시 표준화된 5단계 파이프라인을 실행합니다.

```
make destroy
```

* **Step 1:** Ingress, TargetGroupBinding, ArgoCD, PVC Finalizer 선제 제거

* **Step 2:** 구동 중인 Karpenter EC2 스팟 인스턴스 일괄 종료 대기

* **Step 3:** ALB 삭제 보호 해제 및 로드밸런서/타깃그룹 강제 삭제

* **Step 4:** `k8s-traffic-*`, `k8s-elb-*` 보안 그룹 규칙 초기화 및 미반납 ENI 강제 삭제

* **Step 5:** `terraform destroy -auto-approve` 최종 수행

## 5. 복구 확인 및 정상화 판단 기준 (Exit Criteria)

장애 복구 또는 재배포 완료 후 아래 4가지 지표가 모두 충족되어야 장애 종결(Resolved)로 판단합니다.

1. **클러스터 노드 가용성:**

   * MNG 온디맨드 노드 2대가 모두 `Ready` 상태여야 함.

   * `kubectl get nodes`에서 `NotReady` 또는 `SchedulingDisabled` 노드가 없어야 함.

2. **인그레스 및 ALB 라우팅:**

   * `kubectl get targetgroupbindings -A`의 대상 엔드포인트들이 모두 `Healthy` 상태여야 함.

   * 서비스 대표 도메인 호출 시 HTTP `200 OK` 응답 확인.

3. **스토리지 정합성:**

   * In-Cluster 4대 워크로드(MySQL, PostgreSQL, RabbitMQ, Redis)의 PVC가 모두 `Bound` 상태여야 함.

4. **시크릿 동기화 검증:**

   * `make rabbitmq-credential-verify` 및 `make redis-credential-verify` 검증 통과.

## 6. 참고 자료 및 스크립트 색인

### 6.1 자동화 스크립트 모음 (`scripts/`)

* `setup-aws-iam.sh`: 최초 운영자 IAM 환경 설정

* `bootstrap-workload-publication.sh`: 워크로드 시크릿 부트스트랩

* `publish-workload-secrets.sh`: Secret 배포 디스패처

* `publish-rabbitmq-credentials.sh`: RabbitMQ 계정 생성 및 K8s 시크릿 배포

* `publish-redis-credentials.sh`: Redis 인증 토큰 배포

### 6.2 상세 런북

* `WORKLOAD-SECRET-PUBLICATION-RUNBOOK.md`: 마이크로서비스 시크릿 발급 상세 가이드