SHELL := /bin/bash

# 두 스택 모두 등록된 IAM 프로파일(596601390909 계정) 사용
AWS_PROFILE := target-infra

.PHONY: iam-setup iam-plan iam iam-destroy base-plan base base-destroy init plan apply destroy

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
# 3. Init 스택 Plan & 배포 (S3, ECR, ACM 등 기반 리소스)
# ----------------------------------------------------------------
base-plan:
	@echo "=========================================================="
	@echo " [Init] S3, ECR, ACM Plan 실행 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	@cd init && export AWS_PROFILE=$(AWS_PROFILE) && terraform init && terraform plan

base:
	@echo "=========================================================="
	@echo " [Init] S3, ECR, ACM 배포 (Profile: $(AWS_PROFILE))"
	@echo "=========================================================="
	@cd init && export AWS_PROFILE=$(AWS_PROFILE) && terraform init && terraform apply -auto-approve

# Init 스택 전용 파기 (S3, ECR, ACM 등 기반 리소스만 삭제)
base-destroy:
	@echo "=========================================================="
	@echo " [Init] S3, ECR, ACM 리소스 Destroy (Profile: $(AWS_PROFILE))"
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
	@echo " [2/3] K8s Ingress 생성 및 ALB DNS 할당 대기 중..."
	@echo "=========================================================="
	@echo "🔔 Ingress 매니페스트 배포 후 ALB DNS가 할당될 때까지 대기합니다..."
	@while [ -z "$$(kubectl get ingress -n frontend -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null)" ]; do \
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
# 7. 전체 인프라 안전 파기 (Ingress/ALB 정리 -> Infra 파기 -> Init 파기)
# ----------------------------------------------------------------
destroy: # 삭제 전 반드시 alb 삭제할것: kubectl delete -f k8s/frontend/
	@echo "=========================================================="
	@echo " [1/4] K8s Ingress 리소스(Frontend & Backend) 선행 삭제"
	@echo "=========================================================="
	-kubectl delete ingress --all -n frontend --ignore-not-found 2>/dev/null || true
	-kubectl delete ingress --all -n backend --ignore-not-found 2>/dev/null || true

	@echo "=========================================================="
	@echo " [2/4] Karpenter 스팟 노드 선행 반납 및 EC2 완전 종료 대기"
	@echo "=========================================================="
	@echo "K8s 리소스 삭제 신호 전달..."
	-kubectl delete nodepools --all --timeout=30s 2>/dev/null || true
	-kubectl delete nodeclaims --all --timeout=30s 2>/dev/null || true

	@echo "Karpenter가 띄운 실제 잔여 EC2 스팟 인스턴스 검색 및 강제 종료..."
	@SPOT_IDS=$$(export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 describe-instances \
		--region ap-northeast-2 \
		--filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=pending,running,shutting-down,stopping,stopped" \
		--query "Reservations[*].Instances[*].InstanceId" \
		--output text 2>/dev/null); \
	if [ -n "$$SPOT_IDS" ]; then \
		echo "종료 대기/진행 중인 스팟 인스턴스 발견: $$SPOT_IDS"; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 terminate-instances --instance-ids $$SPOT_IDS --region ap-northeast-2 2>/dev/null || true; \
		echo "AWS에서 인스턴스가 완전히 'terminated' 될 때까지 대기 중..."; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 wait instance-terminated --instance-ids $$SPOT_IDS --region ap-northeast-2; \
		echo "스팟 인스턴스 종료 및 ENI 반납 완료!"; \
	else \
		echo "남아있는 Karpenter 스팟 인스턴스가 없습니다."; \
	fi
	@echo "ENI 정리 안정화 대기 (15초)..."
	@sleep 15

	@echo "=========================================================="
	@echo " [3/4] AWS ALB 및 Target Group 안전 반납 대기"
	@echo "=========================================================="
	@ALB_ARN=$$(export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 describe-load-balancers --region ap-northeast-2 --query "LoadBalancers[?contains(LoadBalancerName, 'mainalbgroup') || contains(LoadBalancerName, 'k8s')].LoadBalancerArn" --output text 2>/dev/null | head -n 1); \
	if [ "$$ALB_ARN" != "None" ] && [ -n "$$ALB_ARN" ]; then \
		echo "ALB 삭제 및 ENI 반납 대기 중..."; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 delete-load-balancer --load-balancer-arn "$$ALB_ARN" --region ap-northeast-2 2>/dev/null || true; \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 wait load-balancers-deleted --load-balancer-arns "$$ALB_ARN" --region ap-northeast-2; \
		echo "ALB 완전 삭제 및 ENI 반납 확인 완료!"; \
	else \
		echo "정리할 잔여 ALB가 없습니다."; \
	fi
	@echo "잔여 Target Group 자동 정리 진행..."
	@for tg in $$(export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 describe-target-groups --region ap-northeast-2 --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-')].TargetGroupArn" --output text 2>/dev/null); do \
		export AWS_PROFILE=$(AWS_PROFILE) && aws elbv2 delete-target-group --target-group-arn "$$tg" --region ap-northeast-2 2>/dev/null || true; \
	done
	@echo "k8s 동적 보안 그룹의 모든 인바운드/아웃바운드 규칙(상호참조) 강제 해제 및 삭제 진행..."
	@K8S_SGS=$$(export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 describe-security-groups --region ap-northeast-2 --filters "Name=group-name,Values=k8s-*" --query "SecurityGroups[*].GroupId" --output text 2>/dev/null); \
	if [ -n "$$K8S_SGS" ]; then \
		echo "발견된 k8s 잔여 보안 그룹: $$K8S_SGS"; \
		for sg in $$K8S_SGS; do \
			INGRESS_RULES=$$(export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 describe-security-groups --region ap-northeast-2 --group-ids "$$sg" --query "SecurityGroups[0].IpPermissions" --output json 2>/dev/null); \
			if [ "$$INGRESS_RULES" != "[]" ] && [ -n "$$INGRESS_RULES" ]; then \
				export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 revoke-security-group-ingress --region ap-northeast-2 --group-id "$$sg" --ip-permissions "$$INGRESS_RULES" 2>/dev/null || true; \
			fi; \
			EGRESS_RULES=$$(export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 describe-security-groups --region ap-northeast-2 --group-ids "$$sg" --query "SecurityGroups[0].IpPermissionsEgress" --output json 2>/dev/null); \
			if [ "$$EGRESS_RULES" != "[]" ] && [ -n "$$EGRESS_RULES" ]; then \
				export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 revoke-security-group-egress --region ap-northeast-2 --group-id "$$sg" --ip-permissions "$$EGRESS_RULES" 2>/dev/null || true; \
			fi; \
		done; \
		for sg in $$K8S_SGS; do \
			echo "보안 그룹 삭제: $$sg"; \
			export AWS_PROFILE=$(AWS_PROFILE) && aws ec2 delete-security-group --region ap-northeast-2 --group-id "$$sg" 2>/dev/null || true; \
		done; \
		echo "k8s 보안 그룹 정리 완료!"; \
	else \
		echo "남아있는 k8s 보안 그룹이 없습니다."; \
	fi

	@echo "=========================================================="
	@echo " [4/4] Infra 메인 스택 Terraform Destroy 실행"
	@echo "=========================================================="
	@cd infra && export AWS_PROFILE=$(AWS_PROFILE) && terraform destroy -auto-approve

