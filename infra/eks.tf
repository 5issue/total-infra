# 현재 AWS 계정 정보(Account ID 등)를 가져오는 데이터 소스 선언
data "aws_caller_identity" "current" {}

# ==============================================================================
# [보안 요구사항 4.1] 리전 단위 EBS 기본 볼륨 암호화 강제 활성화
# EKS 워커 노드의 OS 루트 볼륨 및 추후 생성되는 모든 EBS PVC가 자동 암호화됨
# ==============================================================================
resource "aws_ebs_encryption_by_default" "ebs_encryption" {
  enabled = true
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name                             = var.cluster_name
  cluster_version                          = "1.36"

  vpc_id                                   = aws_vpc.main.id
  subnet_ids                               = [aws_subnet.private_2a.id, aws_subnet.private_2c.id]
  cluster_endpoint_public_access           = true

  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  # =========================================================================
  # [보안 요구사항] EKS Secrets KMS 암호화 활성화 및 권한 위임 명시
  # KMS 키 관리자 및 사용자에 현재 실행 주체(Caller ARN) 직접 등록
  # =========================================================================
  create_kms_key                = true
  kms_key_enable_default_policy = true

  # AWS 계정의 IAM 관리 체계(root)에 키 관리 권한을 일임 (특정 유저 종속 제거)
  kms_key_administrators = [
    "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
  ]

  # EKS 클러스터 IAM 역할이 KMS 키를 Describe/Encrypt/Decrypt 할 수 있도록 허용
  kms_key_service_users = [
    module.eks.cluster_iam_role_arn
  ]

  node_security_group_tags = {
    "karpenter.sh/discovery"               = var.cluster_name
  }

  cluster_addons = {
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        enableNetworkPolicy = "true" # VPC CNI NetworkPolicy 엔진 활성화됨
        env = {
          ENABLE_PREFIX_DELEGATION = "true"
          WARM_PREFIX_TARGET       = "1"
        }
      })
    }
    eks-pod-identity-agent = { most_recent = true }
  }

  node_security_group_additional_rules = {
    ingress_vpc_all = {
      description   = "Allow all traffic from VPC CIDR"
      protocol      = "-1"
      from_port     = 0
      to_port       = 0
      type          = "ingress"
      cidr_blocks   = [aws_vpc.main.cidr_block]
    }
  }

  eks_managed_node_groups = {
    worker_node = {
      instance_types = ["t3.medium"]            # t4g.large 예정
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_x86_64_STANDARD" # AL2023_ARM_64_STANDARD 예정
      min_size       = 2
      max_size       = 2
      desired_size   = 2

      # 노드가 시작 템플릿 및 EKS 워커 노드 역할을 수행하는 데 필요한 기본 정책 연결
      iam_role_additional_policies = {
        AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      # ========================================================
      # [핵심] 노드 부팅 시 자동으로 실행되는 보안 강화 스크립트
      # ========================================================
      pre_bootstrap_user_data = <<-EOT
        #!/bin/bash
        set -xe

        echo "=== [Security Hardening] Start ==="

        # [U-01] root 계정의 직접 원격 접속 차단
        mkdir -p /etc/ssh/sshd_config.d
        cat << 'EOF' > /etc/ssh/sshd_config.d/01-hardening.conf
        PermitRootLogin no
        EOF
        systemctl reload sshd || systemctl restart sshd

        # [U-02] 패스워드 최소 길이 및 복잡도 설정
        cat << 'EOF' > /etc/security/pwquality.conf
        minlen = 8
        dcredit = -1
        ucredit = -1
        lcredit = -1
        ocredit = -1
        EOF

        # [U-06] su 명령어는 허가된(wheel) 사용자만 사용
        sed -i 's/^#\?auth\s\+required\s\+pam_wheel\.so\s\+use_uid/auth required pam_wheel.so use_uid/' /etc/pam.d/su

        # [U-11] 시스템 계정(UID < 1000) 로그인 Shell 차단 (root 제외)
        awk -F: '($3 < 1000 && $1 != "root" && $7 !~ /(nologin|false)/) {print $1}' /etc/passwd | while read -r user; do
            usermod -s /sbin/nologin "$user"
        done

        # [U-12] 비활성 세션 자동 종료 (10분 = 600초 미입력 시 자동 로그아웃)
        cat << 'EOF' > /etc/profile.d/timeout.sh
        export TMOUT=600
        readonly TMOUT
        EOF
        chmod 0644 /etc/profile.d/timeout.sh

        # [U-13] 패스워드 안전 암호화 저장 (yescrypt/sha512)
        if grep -q "^ENCRYPT_METHOD" /etc/login.defs; then
            sed -i 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD YESCRYPT/' /etc/login.defs
        else
            echo "ENCRYPT_METHOD YESCRYPT" >> /etc/login.defs
        fi

        # [U-63] sudo 접근(/etc/sudoers) 권한 관리
        chown -R root:root /etc/sudoers /etc/sudoers.d
        chmod 0440 /etc/sudoers
        chmod 750 /etc/sudoers.d
        chmod 0440 /etc/sudoers.d/* 2>/dev/null || true

        # --------------------------------------------------------
        # 추가 파일 무결성 및 권한 보안 설정 (U-16 ~ U-67)
        # --------------------------------------------------------
        
        # [U-16, U-18] passwd 및 shadow 파일 권한 및 소유자 설정
        chown root:root /etc/passwd /etc/shadow
        chmod 0644 /etc/passwd
        chmod 0400 /etc/shadow

        # [U-19, U-22] hosts, services 파일 권한 설정
        chown root:root /etc/hosts /etc/services
        chmod 0644 /etc/hosts /etc/services

        # [U-20, U-21] xinetd 및 rsyslog 설정 파일 (존재 시에만 적용)
        [ -f /etc/xinetd.conf ] && chmod 0600 /etc/xinetd.conf && chown root:root /etc/xinetd.conf || true
        [ -f /etc/rsyslog.conf ] && chmod 0640 /etc/rsyslog.conf && chown root:root /etc/rsyslog.conf || true

        # [U-27, U-29] 레거시 취약 파일 강제 삭제 (hosts.equiv, .rhosts, hosts.lpd)
        rm -f /etc/hosts.equiv /root/.rhosts /etc/hosts.lpd

        # [U-30] 기본 UMASK 022 명시 설정
        sed -i -E 's/UMASK\s+[0-9]+/UMASK 022/' /etc/login.defs || true

        # [U-34 ~ U-52] 불필요 및 취약 데몬/소켓 비활성화
        # AL2023에 미설치되어 있으나, 감사 통과 및 예방 차원의 즉시 비활성화
        systemctl disable --now finger.socket rsh.socket rlogin.socket rexec.socket \
          echo-stream.socket echo-dgram.socket discard-stream.socket discard-dgram.socket \
          daytime-stream.socket daytime-dgram.socket tftp.socket telnet.socket 2>/dev/null || true

        # [U-48, U-53, U-55] SMTP / FTP 관련 서비스 정지 및 비활성화 (설치되어 있을 경우 대비)
        systemctl disable --now postfix sendmail vsftpd proftpd 2>/dev/null || true

        # FTP 계정이 존재할 경우 쉘 제한 (U-55 방어)
        if id ftp &>/dev/null; then
            usermod -s /sbin/nologin ftp || true
        fi

        # [U-67] 주요 로그 파일 소유권 및 상세 권한 보강
        chown -R root:root /var/log/
        find /var/log -type f -exec chmod go-w {} + 2>/dev/null || true
        # 보안 감사 핵심 파일 640 적용
        chmod 0640 /var/log/messages /var/log/secure /var/log/audit/audit.log 2>/dev/null || true
        
        echo "=== [Security Hardening] Complete ==="
      EOT
    }
  }

  # EKS가 라우팅 및 게이트웨이, 서브넷보다 먼저 삭제되도록 명시
  depends_on = [
    aws_route_table_association.private_2a,
    aws_route_table_association.private_2c,
    aws_route_table_association.public_2a,
    aws_route_table_association.public_2c,
    aws_internet_gateway.igw
  ]
}

# ==============================================================================
# ebs 모듈 호출 (EKS 생성 완료 후 OIDC ARN을 받아 자동 실행)
# ==============================================================================
module "ebs_csi" {
  source = "../modules/ebs_csi"

  cluster_name      = module.eks.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
}


resource "null_resource" "update_kubeconfig" {
  depends_on = [module.eks]

  triggers  = {
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
  }
}

# [보안 요구사항] 익명/미인증 바인딩 자동 제거
resource "null_resource" "remove_anonymous_access" {
  depends_on = [null_resource.update_kubeconfig]

  triggers = {
    cluster_endpoint = module.eks.cluster_endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "=== [보안 조치] 익명/미인증 사용자 ClusterRoleBinding 제거 ==="
      
      # 1. system:public-info-viewer 완전 삭제 (미인증 정보 공개 차단)
      kubectl delete clusterrolebinding system:public-info-viewer --ignore-not-found=true

      # 2. system:discovery에서 system:unauthenticated만 제거하고,
      #    인증된 계정(system:authenticated)은 Discovery가 가능하도록 명시 유지
      kubectl patch clusterrolebinding system:discovery --type='merge' -p='{
        "subjects": [
          {
            "apiGroup": "rbac.authorization.k8s.io",
            "kind": "Group",
            "name": "system:authenticated"
          }
        ]
      }'
    EOT
  }
}