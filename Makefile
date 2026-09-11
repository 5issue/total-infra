SHELL := /bin/bash

# 두 스택 모두 등록된 IAM 프로파일(596601390909 계정) 사용
AWS_PROFILE  := target-infra
AWS_REGION   := ap-northeast-2
CLUSTER_NAME := test-eks

# AWS CLI 페이저(less) 비활성화 -> CLI 실행 시 멈춤 현상 원천 차단
export AWS_PAGER :=

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
	@echo " NAT 인스턴스 및 네트워크 선행 배포"
	@echo "=========================================================="
	@cd infra && export AWS_PROFILE=$(AWS_PROFILE) && terraform init && \
		terraform apply -target=aws_instance.nat_instance_2a -target=aws_instance.nat_instance_2c -auto-approve
	@echo "NAT 인스턴스 부팅 및 iptables 포워딩 안정화 대기 (30초)..."
	@sleep 30

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
# 7. 전체 인프라 안전 파기
# ----------------------------------------------------------------
destroy:
	@echo "=========================================================="
	@echo " [1/5] K8s Ingress 및 Application 파이널라이저 안전 해제"
	@echo "=========================================================="
	@echo "Ingress 삭제 신호 전달..."
	-kubectl delete ingress --all -A --ignore-not-found --timeout=20s 2>/dev/null || true

	@echo "Argo CD Application 파이널라이저 강제 해제 및 삭제..."
	-kubectl get application -n argocd -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
		xargs -r -n 1 kubectl patch application -n argocd -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
	-kubectl delete application --all -n argocd --ignore-not-found --timeout=20s 2>/dev/null || true

	@echo "Ingress 파이널라이저 강제 해제..."
	@for ns in frontend backend dev prometheus argocd; do \
		for ing in $$(kubectl get ingress -n $$ns -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do \
			kubectl patch ingress $$ing -n $$ns -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true; \
		done \
	done

	@echo "=========================================================="
	@echo " [2/5] K8s 네임스페이스 파이널라이저 사전 강제 제거 (Terminating 방지)"
	@echo "=========================================================="
	@for ns in frontend backend dev argocd prometheus; do \
		kubectl get ns "$$ns" -o json 2>/dev/null | \
		python3 -c 'import sys, json; data=json.load(sys.stdin); data["spec"]["finalizers"]=[]; print(json.dumps(data))' | \
		kubectl replace --raw "/api/v1/namespaces/$$ns/finalize" -f - 2>/dev/null || true; \
	done

	@echo "=========================================================="
	@echo " [3/5] Karpenter 스팟 노드 정리 및 인스턴스 완전 종료 대기"
	@echo "=========================================================="
	-kubectl delete nodepools --all --timeout=20s 2>/dev/null || true
	-kubectl delete nodeclaims --all --timeout=20s 2>/dev/null || true

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
	@echo " [4/5] AWS ALB, Target Group, ENI 및 k8s 동적 보안 그룹 강제 소멸"
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
	@echo " [5/5] Infra 메인 스택 Terraform Destroy 실행"
	@echo "=========================================================="
	@cd infra && export AWS_PROFILE=$(AWS_PROFILE) && terraform destroy -auto-approve