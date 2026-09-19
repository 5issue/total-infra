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

.PHONY: iam-setup iam-plan iam iam-destroy base-plan base base-destroy init plan apply workload-publication workload-publication-bootstrap rabbitmq-credential-publish rabbitmq-credential-verify redis-credential-publish redis-credential-verify destroy scheduler-plan scheduler scheduler-destroy

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

redis-credential-publish:
	@AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) EKS_CLUSTER_NAME=$(CLUSTER_NAME) \
		./scripts/publish-redis-credentials.sh publish

redis-credential-verify:
	@AWS_PROFILE=$(AWS_PROFILE) AWS_REGION=$(AWS_REGION) EKS_CLUSTER_NAME=$(CLUSTER_NAME) \
		./scripts/publish-redis-credentials.sh verify

# ----------------------------------------------------------------
# 8. 전체 인프라 안전 파기
# ----------------------------------------------------------------
destroy:
	@echo "=========================================================="
	@echo " [1/4] K8s Ingress 및 LBC 연동 리소스 선제 정리"
	@echo "=========================================================="
	@export KUBECONFIG=~/.kube/config 2>/dev/null || true
	-kubectl delete ingress --all -A --timeout=60s 2>/dev/null || true
	-kubectl delete targetgroupbindings --all -A --timeout=60s 2>/dev/null || true

	@echo "=========================================================="
	@echo " [2/4] Karpenter 스팟 노드 정리 및 인스턴스 완전 종료 대기"
	@echo "=========================================================="
	-kubectl delete nodepools --all --timeout=60s 2>/dev/null || true
	-kubectl delete nodeclaims --all --timeout=60s 2>/dev/null || true

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
	@echo " [3/4] AWS ALB, Target Group, ENI 선제 소멸"
	@echo "=========================================================="
	@for alb in $$(export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?contains(LoadBalancerName, 'mainalbgroup') || contains(LoadBalancerName, 'k8s')].LoadBalancerArn" --output text 2>/dev/null); do \
		echo "ALB 삭제: $$alb"; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 delete-load-balancer --load-balancer-arn "$$alb" --region $(AWS_REGION) 2>/dev/null || true; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 wait load-balancers-deleted --load-balancer-arns "$$alb" --region $(AWS_REGION); \
	done

	@for tg in $$(export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-')].TargetGroupArn" --output text 2>/dev/null); do \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 delete-target-group --target-group-arn "$$tg" --region $(AWS_REGION) 2>/dev/null || true; \
	done

	@echo "=========================================================="
	@echo " K8s Load Balancer 보안 그룹 정리"
	@echo "=========================================================="
	@set -euo pipefail; \
	command -v jq >/dev/null || { echo "jq가 필요합니다."; exit 1; }; \
	CREDS=$$(aws configure export-credentials --profile "$(AWS_PROFILE)" --format env); \
	eval "$$CREDS"; \
	VPC_ID=$$(terraform -chdir=infra state pull | jq -er \
		'[.resources[] | select(.mode == "managed" and .type == "aws_vpc" and .name == "main" and (.module // "") == "") | .instances[] | .attributes.id | select(type == "string")] | unique | if length == 1 then .[0] else error("state에서 루트 aws_vpc.main을 하나로 식별하지 못했습니다.") end'); \
	if [[ ! "$$VPC_ID" =~ ^vpc-([0-9a-f]{8}|[0-9a-f]{17})$$ ]]; then \
		echo "올바르지 않은 VPC ID: $$VPC_ID"; \
		exit 1; \
	fi; \
	echo "대상 VPC: $$VPC_ID"; \
	SGS=$$(aws ec2 describe-security-groups \
		--region $(AWS_REGION) \
		--filters "Name=vpc-id,Values=$$VPC_ID" \
		--query "SecurityGroups[?starts_with(GroupName, 'k8s-')].GroupId" \
		--output text); \
	if [ -z "$$SGS" ]; then \
		echo "삭제할 k8s-* 보안 그룹이 없습니다."; \
		exit 0; \
	fi; \
	echo "삭제 대상 K8s 보안 그룹: $$SGS"; \
	for SG in $$SGS; do \
		ENIS=$$(aws ec2 describe-network-interfaces \
			--region $(AWS_REGION) \
			--filters "Name=group-id,Values=$$SG" \
			--query 'NetworkInterfaces[].NetworkInterfaceId' \
			--output text); \
		if [ -n "$$ENIS" ]; then \
			echo "보안 그룹 $$SG 를 사용하는 ENI가 남아 있습니다:"; \
			echo "$$ENIS"; \
			exit 1; \
		fi; \
	done; \
	for SG in $$SGS; do \
		IN_RULES=$$(aws ec2 describe-security-groups \
			--region $(AWS_REGION) --group-ids "$$SG" \
			--query 'SecurityGroups[0].IpPermissions' --output json); \
		if [ "$$IN_RULES" != "[]" ] && [ "$$IN_RULES" != "null" ]; then \
			aws ec2 revoke-security-group-ingress \
				--region $(AWS_REGION) --group-id "$$SG" \
				--ip-permissions "$$IN_RULES"; \
		fi; \
		OUT_RULES=$$(aws ec2 describe-security-groups \
			--region $(AWS_REGION) --group-ids "$$SG" \
			--query 'SecurityGroups[0].IpPermissionsEgress' --output json); \
		if [ "$$OUT_RULES" != "[]" ] && [ "$$OUT_RULES" != "null" ]; then \
			aws ec2 revoke-security-group-egress \
				--region $(AWS_REGION) --group-id "$$SG" \
				--ip-permissions "$$OUT_RULES"; \
		fi; \
	done; \
	for SG in $$SGS; do \
		echo "보안 그룹 삭제: $$SG"; \
		aws ec2 delete-security-group --region $(AWS_REGION) --group-id "$$SG"; \
	done

	@echo "=========================================================="
	@echo " K8s finalizer 정리"
	@echo "=========================================================="
	@for TYPE in ingress targetgroupbindings.elbv2.k8s.aws applications.argoproj.io; do \
		kubectl get $$TYPE -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | \
		while read NS NAME; do \
			[ -z "$$NAME" ] || kubectl patch $$TYPE "$$NAME" -n "$$NS" \
				--type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true; \
		done; \
	done

	@echo "======================================================"
	@echo " [4/4] Infra 메인 스택 Terraform Destroy 실행"
	@echo "=============================================================="
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
