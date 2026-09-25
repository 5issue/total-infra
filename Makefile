SHELL := /bin/bash

MAKEFILE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

# Resolve only the internal default. Caller-provided values remain raw so the
# workload-publication target can pass them without GNU Make re-expansion.
ifeq ($(origin TOTAL_K8S_DIR), undefined)
TOTAL_K8S_DIR := $(abspath $(MAKEFILE_DIR)/../total-k8s)
endif

# Command-line variables are otherwise exported and recursively expanded by Make.
unexport ENV COMPONENT PHASE KUBECTL_CONTEXT TOTAL_K8S_DIR

# 두 스택 모두 등록된 IAM 프로파일(596601390909 계정) 사용
AWS_PROFILE  := target-infra
AWS_REGION   := ap-northeast-2
CLUSTER_NAME := test-eks

# AWS CLI 페이저(less) 비활성화 -> CLI 실행 시 멈춤 현상 원천 차단
export AWS_PAGER :=

# AWS 임시 세션을 환경 변수로 주입한 뒤 지정된 디렉토리에서 테라폼 명령어를 실행하는 공통 매크로
define run-tf
	@eval $$(aws configure export-credentials --profile $(AWS_PROFILE) --format env) && \
	cd $(1) && \
	$(2)
endef

.PHONY: \
	iam-setup iam-plan iam iam-destroy \
	base-plan base base-destroy \
	init plan apply destroy \
	workload-publication workload-publication-bootstrap \
	rabbitmq-credential-publish rabbitmq-credential-verify \
	rabbitmq-wms-credential-publish rabbitmq-wms-credential-verify \
	rabbitmq-oms-credential-publish rabbitmq-oms-credential-verify \
	redis-credential-publish redis-credential-verify \
	publish-all-credentials \
	scheduler-plan scheduler scheduler-destroy

# ----------------------------------------------------------------
# 1. IAM 등록 (최초 1회 실행)
# ----------------------------------------------------------------
iam-setup:
	@chmod +x scripts/setup-aws-iam.sh
	@./scripts/setup-aws-iam.sh

# ----------------------------------------------------------------
# 2. IAM 스택 Plan & 배포 (KMS, MFA, Spot SLR 등 전역 IAM 리소스)
# ----------------------------------------------------------------
iam-plan:
	@echo "=========================================================="
	@echo " [IAM] 전역 IAM / KMS Plan 실행 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	$(call run-tf,iam,terraform init && terraform plan)

iam:
	@echo "=========================================================="
	@echo " [IAM] 전역 IAM / KMS 배포 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	$(call run-tf,iam,terraform init && terraform apply -auto-approve)

iam-destroy:
	@echo "=========================================================="
	@echo " [IAM] 전역 IAM 리소스 Destroy (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	$(call run-tf,iam,terraform destroy -auto-approve)

# ----------------------------------------------------------------
# 3. Init 스택 Plan & 배포 (공통 기반 리소스)
# ----------------------------------------------------------------
base-plan:
	@echo "=========================================================="
	@echo " [Init] 공통 기반 리소스 Plan 실행 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	$(call run-tf,init,terraform init && terraform plan)

base:
	@echo "=========================================================="
	@echo " [Init] 공통 기반 리소스 배포 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	$(call run-tf,init,terraform init && terraform apply -auto-approve)

# Init 스택 전용 파기 (공통 기반 리소스 전체)
base-destroy:
	@echo "=========================================================="
	@echo " [Init] 공통 기반 리소스 Destroy (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	$(call run-tf,init,terraform destroy -auto-approve)

# ----------------------------------------------------------------
# 4. Infra 스택 전용 Init
# ----------------------------------------------------------------
init:
	@echo "=========================================================="
	@echo " [Infra] Terraform Init 실행 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	$(call run-tf,infra,terraform init)

# ----------------------------------------------------------------
# 5. Infra 스택 Plan 검증
# ----------------------------------------------------------------
plan:
	@echo "=========================================================="
	@echo " [Infra] 메인 인프라 Plan 실행 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	$(call run-tf,infra,terraform init && terraform plan)

# ----------------------------------------------------------------
# 6. Infra 메인 스택 배포 (VPC/EKS -> Ingress 대기 -> CloudFront 연동)
# ----------------------------------------------------------------
apply:
	@echo "=========================================================="
	@echo " [1/3] 기본 인프라(VPC, EKS 등) 1차 프로비저닝"
	@echo "=========================================================="
	$(call run-tf,infra,terraform init && terraform apply -auto-approve)

	@echo "=========================================================="
	@echo " 최신 EKS 클러스터 접속 정보(kubeconfig) 동기화"
	@echo "=========================================================="
	@export AWS_PROFILE=$(AWS_PROFILE) && aws eks update-kubeconfig --region $(AWS_REGION) --name $(CLUSTER_NAME)

	@echo "=========================================================="
	@echo " [2/3] K8s Ingress 생성 및 ALB DNS 할당 대기 중..."
	@echo "=========================================================="
	@echo "🔔 Ingress 매니페스트 배포 후 ALB DNS가 할당될 때까지 대기합니다..."
	@while [ -z "$$(kubectl get ingress -A -o jsonpath='{.items[*].status.loadBalancer.ingress[0].hostname}' | tr ' ' '\n' | grep -v '^$$' | head -n 1)" ]; do \
	    echo -n "."; \
	    sleep 5; \
	done
	@echo ""
	@ALB_HOSTNAME=$$(kubectl get ingress -n frontend -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'); \
	echo "🎉 ALB DNS 감지 완료: $$ALB_HOSTNAME"; \
	\
	echo "=========================================================="; \
	echo " [3/3] CloudFront & Route 53 생성 (ALB DNS 연동)"; \
	echo "=========================================================="; \
	eval $$(aws configure export-credentials --profile $(AWS_PROFILE) --format env) && \
	cd infra && terraform apply -auto-approve -var="alb_dns_name=$$ALB_HOSTNAME"

# ----------------------------------------------------------------
# Workload publication dispatcher
# ----------------------------------------------------------------
workload-publication: export WORKLOAD_PUBLICATION_ENV := $(value ENV)
workload-publication: export WORKLOAD_PUBLICATION_COMPONENT := $(value COMPONENT)
workload-publication: export WORKLOAD_PUBLICATION_PHASE := $(value PHASE)
workload-publication: export WORKLOAD_PUBLICATION_TOTAL_K8S_DIR := $(value TOTAL_K8S_DIR)
workload-publication: export WORKLOAD_PUBLICATION_KUBECTL_CONTEXT := $(value KUBECTL_CONTEXT)
workload-publication:
	@if [[ -z "$${WORKLOAD_PUBLICATION_ENV:-}" || -z "$${WORKLOAD_PUBLICATION_COMPONENT:-}" || -z "$${WORKLOAD_PUBLICATION_PHASE:-}" ]]; then \
	echo "Usage: make workload-publication ENV=production COMPONENT=<component> PHASE=<phase>"		exit 2; \
	fi
	@TOTAL_K8S_DIR="$${WORKLOAD_PUBLICATION_TOTAL_K8S_DIR}" \
		KUBECTL_CONTEXT="$${WORKLOAD_PUBLICATION_KUBECTL_CONTEXT}" \
		"$(MAKEFILE_DIR)/scripts/publish-workload-secrets.sh" \
		"$${WORKLOAD_PUBLICATION_ENV}" "$${WORKLOAD_PUBLICATION_COMPONENT}" "$${WORKLOAD_PUBLICATION_PHASE}"

workload-publication-bootstrap: export WORKLOAD_BOOTSTRAP_ENV := $(value ENV)
workload-publication-bootstrap: export WORKLOAD_BOOTSTRAP_TOTAL_K8S_DIR := $(value TOTAL_K8S_DIR)
workload-publication-bootstrap: export WORKLOAD_BOOTSTRAP_KUBECTL_CONTEXT := $(value KUBECTL_CONTEXT)
workload-publication-bootstrap:
	@if [[ -z "$${WORKLOAD_BOOTSTRAP_ENV:-}" ]]; then \
		echo "Usage: make workload-publication-bootstrap ENV=production KUBECTL_CONTEXT=<context>" >&2; \
		exit 2; \
	fi
	@TOTAL_K8S_DIR="$${WORKLOAD_BOOTSTRAP_TOTAL_K8S_DIR}" \
		KUBECTL_CONTEXT="$${WORKLOAD_BOOTSTRAP_KUBECTL_CONTEXT}" \
		"$(MAKEFILE_DIR)/scripts/bootstrap-workload-publication.sh" \
		"$${WORKLOAD_BOOTSTRAP_ENV}"

# ----------------------------------------------------------------
# 7. Workload credential publication (개별 운영 작업)
# ----------------------------------------------------------------
rabbitmq-credential-publish:
	@AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) EKS_CLUSTER_NAME=$(CLUSTER_NAME) \
		./scripts/publish-rabbitmq-credentials.sh publish

rabbitmq-credential-verify:
	@AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) EKS_CLUSTER_NAME=$(CLUSTER_NAME) \
		./scripts/publish-rabbitmq-credentials.sh verify

rabbitmq-wms-credential-publish:
	@AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) EKS_CLUSTER_NAME=$(CLUSTER_NAME) \
		./scripts/publish-rabbitmq-credentials.sh publish wms

rabbitmq-wms-credential-verify:
	@AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) EKS_CLUSTER_NAME=$(CLUSTER_NAME) \
		./scripts/publish-rabbitmq-credentials.sh verify wms

rabbitmq-oms-credential-publish:
	@AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) EKS_CLUSTER_NAME=$(CLUSTER_NAME) \
		./scripts/publish-rabbitmq-credentials.sh publish oms

rabbitmq-oms-credential-verify:
	@AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) EKS_CLUSTER_NAME=$(CLUSTER_NAME) \
		./scripts/publish-rabbitmq-credentials.sh verify oms

redis-credential-publish:
	@AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) EKS_CLUSTER_NAME=$(CLUSTER_NAME) \
		./scripts/publish-redis-credentials.sh publish

redis-credential-verify:
	@AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) EKS_CLUSTER_NAME=$(CLUSTER_NAME) \
		./scripts/publish-redis-credentials.sh verify

# publish-all-credentials:
# 	@echo "==> [1/4] Bootstrapping workload publication environment..."
# 	@$(MAKE) workload-publication-bootstrap ENV="$(or $(ENV),production)" KUBECTL_CONTEXT="$(KUBECTL_CONTEXT)" TOTAL_K8S_DIR="$(TOTAL_K8S_DIR)"

# 	@echo "==> [2/4] Publishing and verifying RabbitMQ credentials..."
# 	@$(MAKE) rabbitmq-credential-publish
# 	@$(MAKE) rabbitmq-credential-verify
# 	@$(MAKE) rabbitmq-wms-credential-publish
# 	@$(MAKE) rabbitmq-wms-credential-verify
# 	@$(MAKE) rabbitmq-oms-credential-publish
# 	@$(MAKE) rabbitmq-oms-credential-verify

# 	@echo "==> [3/4] Publishing and verifying Redis credentials..."
# 	@$(MAKE) redis-credential-publish
# 	@$(MAKE) redis-credential-verify

# 	@echo "==> [4/4] All workload credentials successfully published and verified!"

# ----------------------------------------------------------------
# 8. 전체 인프라 안전 파기
# ----------------------------------------------------------------
destroy:
	@echo "=========================================================="
	@echo " [1/5] K8s 리소스 선제 정리 및 Finalizer 해제"
	@echo "=========================================================="
	@export KUBECONFIG=~/.kube/config 2>/dev/null || true; \
	\
	echo "1. Ingress 및 로드밸런서 연동 리소스 선제 정리..."; \
	kubectl delete ingress --all -A --timeout=30s 2>/dev/null || true; \
	kubectl delete targetgroupbindings --all -A --timeout=30s 2>/dev/null || true; \
	kubectl delete nodepools --all --timeout=30s 2>/dev/null || true; \
	kubectl delete nodeclaims --all --timeout=30s 2>/dev/null || true; \
	\
	echo "2. ArgoCD ApplicationSet & Application 재생성 차단 및 삭제..."; \
	kubectl delete applicationsets.argoproj.io --all -A --timeout=20s 2>/dev/null || true; \
	kubectl get applicationsets.argoproj.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
	while read -r NS NAME; do \
		[ -n "$$NAME" ] && kubectl patch applicationset.argoproj.io "$$NAME" -n "$$NS" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
	done; \
	kubectl delete applications.argoproj.io --all -A --timeout=20s 2>/dev/null || true; \
	kubectl get applications.argoproj.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
	while read -r NS NAME; do \
		[ -n "$$NAME" ] && kubectl patch application.argoproj.io "$$NAME" -n "$$NS" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
	done; \
	\
	echo "3. 워크로드 및 영구 볼륨(PVC) Finalizer 해제 (EBS 볼륨 락 방지)..."; \
	kubectl delete statefulset --all -A --timeout=20s 2>/dev/null || true; \
	kubectl delete pvc --all -A --timeout=20s 2>/dev/null || true; \
	kubectl get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
	while read -r NS NAME; do \
		[ -n "$$NAME" ] && kubectl patch pvc "$$NAME" -n "$$NS" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
	done; \
	\
	echo "4. 기타 CRD 리소스 finalizer 강제 제거..."; \
	for TYPE in rollouts.argoproj.io certificates.cert-manager.io clusterissuers.cert-manager.io issuers.cert-manager.io; do \
		kubectl get $$TYPE -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
		while read -r NS NAME; do \
			[ -n "$$NAME" ] && kubectl patch $$TYPE "$$NAME" -n "$$NS" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
		done; \
	done; \
	\
	echo "5. 커스텀 네임스페이스 finalizer 선제 해제..."; \
	for NS in $$(kubectl get ns --no-headers 2>/dev/null | awk '{print $$1}' | grep -E "^(frontend|backend|dev|argocd|prometheus|argo-rollouts|cert-manager)$$"); do \
		echo "네임스페이스 finalizer 해제: $$NS"; \
		kubectl get ns "$$NS" -o json 2>/dev/null | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/$$NS/finalize" -f - 2>/dev/null || true; \
	done

	@echo "=========================================================="
	@echo " [2/5] Karpenter 스팟 노드 정리 및 인스턴스 종료 대기"
	@echo "=========================================================="
	@SPOT_IDS=$$(export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 describe-instances \
		--region $(AWS_REGION) \
		--filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
		--query "Reservations[*].Instances[*].InstanceId" \
		--output text 2>/dev/null); \
	if [ -n "$$SPOT_IDS" ]; then \
		echo "스팟 인스턴스 종료 중: $$SPOT_IDS"; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 terminate-instances --instance-ids $$SPOT_IDS --region $(AWS_REGION) 2>/dev/null || true; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 wait instance-terminated --instance-ids $$SPOT_IDS --region $(AWS_REGION); \
	fi
	@sleep 5

	@echo "=========================================================="
	@echo " [3/5] AWS ALB 및 Target Group 선제 소멸"
	@echo "=========================================================="
	@for alb in $$(export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?contains(LoadBalancerName, 'mainalbgroup') || contains(LoadBalancerName, 'k8s')].LoadBalancerArn" --output text 2>/dev/null); do \
		echo "ALB 삭제 보호 강제 해제: $$alb"; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 modify-load-balancer-attributes --load-balancer-arn "$$alb" --attributes Key=deletion_protection.enabled,Value=false --region $(AWS_REGION) 2>/dev/null || true; \
		echo "ALB 삭제: $$alb"; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 delete-load-balancer --load-balancer-arn "$$alb" --region $(AWS_REGION) 2>/dev/null || true; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 wait load-balancers-deleted --load-balancer-arns "$$alb" --region $(AWS_REGION); \
	done

	@for tg in $$(export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-')].TargetGroupArn" --output text 2>/dev/null); do \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 delete-target-group --target-group-arn "$$tg" --region $(AWS_REGION) 2>/dev/null || true; \
	done

	@echo "=========================================================="
	@echo " [4/5] K8s 잔여 보안 그룹(k8s-traffic-*, k8s-elb-* 포함) 및 ENI 강제 정리"
	@echo "=========================================================="
	@eval $$(aws configure export-credentials --profile $(AWS_PROFILE) --format env); \
	VPC_ID=$$(terraform -chdir=infra state pull 2>/dev/null | jq -r \
		'[.resources[] | select(.type == "aws_vpc") | .instances[].attributes.id] | .[0] // empty'); \
	if [ -n "$$VPC_ID" ]; then \
		echo "대상 VPC: $$VPC_ID"; \
		SGS=$$(aws ec2 describe-security-groups --region $(AWS_REGION) \
			--filters "Name=vpc-id,Values=$$VPC_ID" \
			--query "SecurityGroups[?starts_with(GroupName, 'k8s-') || contains(GroupName, 'k8s-traffic')].GroupId" --output text); \
		echo "정리 대상 k8s 보안 그룹 목록: $$SGS"; \
		for SG in $$SGS; do \
			echo "보안 그룹 규칙 초기화: $$SG"; \
			IN_RULES=$$(aws ec2 describe-security-groups --region $(AWS_REGION) --group-ids "$$SG" --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null); \
			if [ "$$IN_RULES" != "[]" ] && [ "$$IN_RULES" != "null" ]; then \
				aws ec2 revoke-security-group-ingress --region $(AWS_REGION) --group-id "$$SG" --ip-permissions "$$IN_RULES" 2>/dev/null || true; \
			fi; \
			OUT_RULES=$$(aws ec2 describe-security-groups --region $(AWS_REGION) --group-ids "$$SG" --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null); \
			if [ "$$OUT_RULES" != "[]" ] && [ "$$OUT_RULES" != "null" ]; then \
				aws ec2 revoke-security-group-egress --region $(AWS_REGION) --group-id "$$SG" --ip-permissions "$$OUT_RULES" 2>/dev/null || true; \
			fi; \
		done; \
		for SG in $$SGS; do \
			ENIS=$$(aws ec2 describe-network-interfaces --region $(AWS_REGION) \
				--filters "Name=group-id,Values=$$SG" \
				--query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null); \
			for ENI in $$ENIS; do \
				ATTACH_ID=$$(aws ec2 describe-network-interfaces --region $(AWS_REGION) --network-interface-ids "$$ENI" --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null); \
				if [ -n "$$ATTACH_ID" ] && [ "$$ATTACH_ID" != "None" ]; then \
					aws ec2 detach-network-interface --attachment-id "$$ATTACH_ID" --region $(AWS_REGION) --force 2>/dev/null || true; \
					sleep 2; \
				fi; \
				aws ec2 delete-network-interface --network-interface-id "$$ENI" --region $(AWS_REGION) 2>/dev/null || true; \
			done; \
		done; \
		for SG in $$SGS; do \
			echo "보안 그룹 삭제 시도: $$SG"; \
			for i in {1..15}; do \
				if aws ec2 delete-security-group --region $(AWS_REGION) --group-id "$$SG" 2>/dev/null; then \
					echo "보안 그룹 삭제 완료: $$SG"; break; \
				fi; \
				sleep 3; \
			done; \
		done; \
	fi

	@echo "=========================================================="
	@echo " [5/5] Infra 메인 스택 Terraform Destroy 실행"
	@echo "=========================================================="
	$(call run-tf,infra,terraform destroy -auto-approve)
	
# ----------------------------------------------------------------
# Scheduler 스택 Plan & 배포 (EventBridge + Lambda)
# ----------------------------------------------------------------
scheduler-plan:
	$(call run-tf,scheduler,terraform init && terraform plan)

scheduler:
	$(call run-tf,scheduler,terraform init && terraform apply -auto-approve)

scheduler-destroy:
	$(call run-tf,scheduler,terraform destroy -auto-approve)
