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
	@cd iam && export AWS_PROFILE=$(AWS_PROFILE) && terraform init && terraform plan

iam:
	@echo "=========================================================="
	@echo " [IAM] 전역 IAM / KMS 배포 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	@cd iam && export AWS_PROFILE=$(AWS_PROFILE) && terraform init && terraform apply -auto-approve

iam-destroy:
	@echo "=========================================================="
	@echo " [IAM] 전역 IAM 리소스 Destroy (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	@cd iam && export AWS_PROFILE=$(AWS_PROFILE) && terraform destroy -auto-approve

# ----------------------------------------------------------------
# 3. Init 스택 Plan & 배포 (공통 기반 리소스)
# ----------------------------------------------------------------
base-plan:
	@echo "=========================================================="
	@echo " [Init] 공통 기반 리소스 Plan 실행 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	@cd init && export AWS_PROFILE=$(AWS_PROFILE) && terraform init && terraform plan

base:
	@echo "=========================================================="
	@echo " [Init] 공통 기반 리소스 배포 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	@cd init && export AWS_PROFILE=$(AWS_PROFILE) && terraform init && terraform apply -auto-approve

# Init 스택 전용 파기 (공통 기반 리소스 전체)
base-destroy:
	@echo "=========================================================="
	@echo " [Init] 공통 기반 리소스 Destroy (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	@cd init && export AWS_PROFILE=$(AWS_PROFILE) && terraform destroy -auto-approve

# ----------------------------------------------------------------
# 4. Infra 스택 전용 Init
# ----------------------------------------------------------------
init:
	@echo "=========================================================="
	@echo " [Infra] Terraform Init 실행 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	@cd infra && export AWS_PROFILE=$(AWS_PROFILE) && terraform init

# ----------------------------------------------------------------
# 5. Infra 스택 Plan 검증
# ----------------------------------------------------------------
plan:
	@echo "=========================================================="
	@echo " [Infra] 메인 인프라 Plan 실행 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	@cd infra && export AWS_PROFILE=$(AWS_PROFILE) && terraform init && terraform plan

# ----------------------------------------------------------------
# 6. Infra 메인 스택 배포 (VPC/EKS -> Ingress 대기 -> CloudFront 연동)
# ----------------------------------------------------------------
apply:
	@echo "=========================================================="
	@echo " [1/3] 기본 인프라(VPC, EKS 등) 1차 프로비저닝"
	@echo "=========================================================="
	@cd infra && export AWS_PROFILE=$(AWS_PROFILE) && terraform init && terraform apply -auto-approve

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
	cd infra && export AWS_PROFILE=$(AWS_PROFILE) && terraform apply -auto-approve -var="alb_dns_name=$$ALB_HOSTNAME"

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
	@echo " [3/4] AWS ALB, Target Group, ENI 및 k8s 동적 보안 그룹 강제 소멸"
	@echo "=========================================================="
	@for alb in $$(export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 describe-load-balancers --region $(AWS_REGION) --query "LoadBalancers[?contains(LoadBalancerName, 'mainalbgroup') || contains(LoadBalancerName, 'k8s')].LoadBalancerArn" --output text 2>/dev/null); do \
		echo "ALB 삭제: $$alb"; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 delete-load-balancer --load-balancer-arn "$$alb" --region $(AWS_REGION) 2>/dev/null || true; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 wait load-balancers-deleted --load-balancer-arns "$$alb" --region $(AWS_REGION); \
	done
	@echo "ALB 연결 ELB ENI 완전 소멸 대기..."
	@while [ -n "$$(aws ec2 describe-network-interfaces --region $(AWS_REGION) --profile $(AWS_PROFILE) --filters 'Name=description,Values=*ELB*' --query 'NetworkInterfaces[*].NetworkInterfaceId' --output text 2>/dev/null)" ]; do \
		echo -n "."; \
		sleep 5; \
	done
	@echo ""

	@for tg in $$(export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 describe-target-groups --region $(AWS_REGION) --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-')].TargetGroupArn" --output text 2>/dev/null); do \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 delete-target-group --target-group-arn "$$tg" --region $(AWS_REGION) 2>/dev/null || true; \
	done

	@VPC_ID=$$(cd infra && terraform output -raw vpc_id 2>/dev/null); \
	if [ -z "$$VPC_ID" ] || [ "$$VPC_ID" = "None" ]; then \
		VPC_ID=$$(aws ec2 describe-vpcs --region $(AWS_REGION) --profile $(AWS_PROFILE) --filters "Name=tag:Name,Values=*$(CLUSTER_NAME)*" "Name=tag:Name,Values=*vpc*" --query "Vpcs[0].VpcId" --output text 2>/dev/null); \
	fi; \
	if [ -n "$$VPC_ID" ] && [ "$$VPC_ID" != "None" ]; then \
		echo "타깃 VPC 확인: $$VPC_ID"; \
		echo " VPC 내 잔여 ENI 강제 분리 및 제거..."; \
		for eni in $$(aws ec2 describe-network-interfaces --region $(AWS_REGION) --profile $(AWS_PROFILE) --filters "Name=vpc-id,Values=$$VPC_ID" --query "NetworkInterfaces[*].NetworkInterfaceId" --output text 2>/dev/null); do \
			attach_id=$$(aws ec2 describe-network-interfaces --region $(AWS_REGION) --profile $(AWS_PROFILE) --network-interface-ids "$$eni" --query "NetworkInterfaces[0].Attachment.AttachmentId" --output text 2>/dev/null); \
			if [ "$$attach_id" != "None" ] && [ -n "$$attach_id" ]; then \
				aws ec2 detach-network-interface --region $(AWS_REGION) --profile $(AWS_PROFILE) --attachment-id "$$attach_id" --force 2>/dev/null || true; \
				sleep 2; \
			fi; \
			aws ec2 delete-network-interface --region $(AWS_REGION) --profile $(AWS_PROFILE) --network-interface-id "$$eni" 2>/dev/null || true; \
		done; \
		\
		CUSTOM_SGS=$$(aws ec2 describe-security-groups --region $(AWS_REGION) --profile $(AWS_PROFILE) --filters "Name=vpc-id,Values=$$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); \
		if [ -n "$$CUSTOM_SGS" ]; then \
			echo " k8s 동적 보안 그룹(default 제외) 규칙 전면 철회..."; \
			for sg in $$CUSTOM_SGS; do \
				IN_RULES=$$(aws ec2 describe-security-groups --region $(AWS_REGION) --profile $(AWS_PROFILE) --group-ids "$$sg" --query "SecurityGroups[0].IpPermissions" --output json 2>/dev/null); \
				if [ "$$IN_RULES" != "[]" ] && [ "$$IN_RULES" != "null" ]; then \
					aws ec2 revoke-security-group-ingress --region $(AWS_REGION) --profile $(AWS_PROFILE) --group-id "$$sg" --ip-permissions "$$IN_RULES" 2>/dev/null || true; \
				fi; \
				OUT_RULES=$$(aws ec2 describe-security-groups --region $(AWS_REGION) --profile $(AWS_PROFILE) --group-ids "$$sg" --query "SecurityGroups[0].IpPermissionsEgress" --output json 2>/dev/null); \
				if [ "$$OUT_RULES" != "[]" ] && [ "$$OUT_RULES" != "null" ]; then \
					aws ec2 revoke-security-group-egress --region $(AWS_REGION) --profile $(AWS_PROFILE) --group-id "$$sg" --ip-permissions "$$OUT_RULES" 2>/dev/null || true; \
				fi; \
			done; \
			sleep 3; \
			echo " k8s 동적 보안 그룹 본체 삭제 재시도 루프..."; \
			for attempt in {1..8}; do \
				REMAINING_SGS=$$(aws ec2 describe-security-groups --region $(AWS_REGION) --profile $(AWS_PROFILE) --filters "Name=vpc-id,Values=$$VPC_ID" --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null); \
				if [ -z "$$REMAINING_SGS" ]; then \
					break; \
				fi; \
				for sg in $$REMAINING_SGS; do \
					aws ec2 delete-security-group --region $(AWS_REGION) --profile $(AWS_PROFILE) --group-id "$$sg" 2>/dev/null || true; \
				done; \
				sleep 3; \
			done; \
			echo "k8s 동적 보안 그룹 및 네트워크 인터페이스 정리 완료!"; \
		fi; \
	fi

	@echo "=========================================================="
	@echo " [4/4] Infra 메인 스택 Terraform Destroy 실행"
	@echo "=========================================================="
	@cd infra && export AWS_PROFILE=$(AWS_PROFILE) && terraform destroy -auto-approve

	
# ----------------------------------------------------------------
# Scheduler 스택 Plan & 배포 (EventBridge + Lambda)
# ----------------------------------------------------------------
scheduler-plan:
	@cd scheduler && export AWS_PROFILE=$(AWS_PROFILE) && terraform init && terraform plan

scheduler:
	@cd scheduler && export AWS_PROFILE=$(AWS_PROFILE) && terraform init && terraform apply -auto-approve

scheduler-destroy:
	@cd scheduler && export AWS_PROFILE=$(AWS_PROFILE) && terraform destroy -auto-approve
