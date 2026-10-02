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

  cluster_name    = var.cluster_name
  cluster_version = "1.36"

  vpc_id                          = aws_vpc.main.id
  subnet_ids                      = [aws_subnet.private_2a.id, aws_subnet.private_2c.id]
  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  # [보안 요구사항 4.14] EKS 제어 플레인 전체 로깅 활성화
  # CloudWatch 수집 비용 절감을 위해 평상시 비활성화 유지
  # cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # 1명만 독점하는 옵션 제거
  enable_cluster_creator_admin_permissions = false
  enable_irsa                              = true

  # EKS 클러스터 관리자 권한 발급
  access_entries = {
    target_infra_role = {
      principal_arn = data.aws_iam_role.target_infra.arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }

    workload_publication = {
      principal_arn     = aws_iam_role.workload_publication.arn
      kubernetes_groups = [local.workload_publication_group]
    }

    eks_cluster_access = {
      principal_arn = aws_iam_role.eks_cluster_access.arn
      policy_associations = {
        view = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }

    db_admin_secret_reader = {
      principal_arn     = aws_iam_role.db_admin_secret_reader.arn
      kubernetes_groups = ["db-admin-readers"]
    }

    rabbitmq_redis_secret_reader = {
      principal_arn     = aws_iam_role.rabbitmq_redis_secret_reader.arn
      kubernetes_groups = ["rabbitmq-redis-readers"]
    }

    be_user1 = {
      principal_arn     = "arn:aws:iam::596601390909:user/be-user1"
      kubernetes_groups = ["backend-developers"]
    }

    be_user2 = {
      principal_arn     = "arn:aws:iam::596601390909:user/be-user2"
      kubernetes_groups = ["backend-developers"]
    }

    be_user3 = {
      principal_arn     = "arn:aws:iam::596601390909:user/be-user3"
      kubernetes_groups = ["backend-developers"]
    }
  }

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
    "karpenter.sh/discovery" = var.cluster_name
  }

  cluster_addons = {
    # coredns    = { most_recent = true }
    # kube-proxy = { most_recent = true }
    vpc-cni = {
      before_compute           = true
      most_recent              = true
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn
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

  # =========================================================================
  # [U-28 대응] 22번 포트 제외 VPC 내부 인바운드 허용
  # =========================================================================
  node_security_group_additional_rules = {
    ingress_vpc_low = {
      description = "Allow VPC TCP traffic below port 22"
      protocol    = "tcp"
      from_port   = 1
      to_port     = 21
      type        = "ingress"
      cidr_blocks = [aws_vpc.main.cidr_block]
    }
    ingress_vpc_high = {
      description = "Allow VPC TCP traffic above port 22"
      protocol    = "tcp"
      from_port   = 23
      to_port     = 65535
      type        = "ingress"
      cidr_blocks = [aws_vpc.main.cidr_block]
    }
    ingress_vpc_udp = {
      description = "Allow VPC UDP traffic for DNS and Pod overlays"
      protocol    = "udp"
      from_port   = 1
      to_port     = 65535
      type        = "ingress"
      cidr_blocks = [aws_vpc.main.cidr_block]
    }
  }

  eks_managed_node_groups = {
    worker_node = {
      instance_types = ["t4g.large"] # [변경] t3.medium -> t4g.large (또는 t3.large)
      capacity_type  = "ON_DEMAND"
      ami_type       = "AL2023_ARM_64_STANDARD" # [변경] x86_64 -> ARM_64 (t4g 사용 시 필수)
      min_size       = 2
      max_size       = 2
      desired_size   = 2

      # 모듈 기본 CNI 정책 자동 부착 방지
      iam_role_attach_cni_policy = true

      # 노드가 시작 템플릿 및 EKS 워커 노드 역할을 수행하는 데 필요한 기본 정책 연결
      iam_role_additional_policies = {
        AmazonEKSWorkerNodePolicy          = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
        AmazonEC2ContainerRegistryReadOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
        AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
        AnsibleS3Access                    = aws_iam_policy.node_ansible_s3.arn
      }

      # ========================================================
      # [핵심] 노드 부팅 시 자동으로 실행되는 보안 강화 스크립트
      # ========================================================
      cloudinit_pre_nodeadm = [
        {
          content_type = "text/x-shellscript"
          content      = <<-EOT
            #!/bin/bash
            set -x

            echo "=== [Security Hardening] Start ==="

            # [U-01] root 계정의 직접 원격 접속 차단
            mkdir -p /etc/ssh/sshd_config.d
            cat << 'EOF' > /etc/ssh/sshd_config.d/01-hardening.conf
            PermitRootLogin no
            EOF
            systemctl reload sshd || systemctl restart sshd

            # [U-02 & U-03] 비밀번호 복잡도, 만료 주기(90/1), 계정 잠금(5회/300초), 이전 이력(6회)
            cat << 'EOF' > /etc/security/pwquality.conf
            minlen = 8
            dcredit = -1
            ucredit = -1
            lcredit = -1
            ocredit = -1
            EOF
            sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs || echo "PASS_MAX_DAYS   90" >> /etc/login.defs
            sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' /etc/login.defs || echo "PASS_MIN_DAYS   1" >> /etc/login.defs
            chage -M 90 -m 1 root || true
            id ec2-user &>/dev/null && chage -M 90 -m 1 ec2-user || true

            # 점검 가이드 기준 authselect 기능 활성화 및 faillock 설정
            authselect enable-feature with-faillock || true
            authselect enable-feature with-pwhistory || true
            authselect apply-changes || true

            sed -i 's/^#\?deny\s*=.*/deny = 5/' /etc/security/faillock.conf || echo "deny = 5" >> /etc/security/faillock.conf
            sed -i 's/^#\?unlock_time\s*=.*/unlock_time = 600/' /etc/security/faillock.conf || echo "unlock_time = 600" >> /etc/security/faillock.conf
            sed -i 's/^#\?remember\s*=.*/remember = 6/' /etc/security/pwhistory.conf || echo "remember = 6" >> /etc/security/pwhistory.conf

            # [U-06] su 명령어 wheel 그룹 사용자 제한 및 wheel 그룹 등록
            # 1. PAM 설정 활성화 (기존 라인이 없거나 주석이어도 확실하게 적용)
            grep -q "pam_wheel.so use_uid" /etc/pam.d/su || echo "auth required pam_wheel.so use_uid" >> /etc/pam.d/su
            sed -i 's/^#\s*\(auth\s\+required\s\+pam_wheel\.so\s\+use_uid\)/\1/' /etc/pam.d/su

            # 2. su 허용 사용자를 wheel 그룹에 추가 (가이드라인 필수 요구사항)
            usermod -aG wheel root
            id ec2-user &>/dev/null && usermod -aG wheel ec2-user || true
            
            # [U-07] ec2-user 패스워드 잠금 (SSM Session Manager만 사용)
            id ec2-user &>/dev/null && usermod -L -s /sbin/nologin ec2-user || true

            # [U-11] 시스템 계정(UID < 1000) 로그인 Shell 차단 (root 제외)
            awk -F: '($3 < 1000 && $1 != "root" && $7 !~ /(nologin|false)/) {print $1}' /etc/passwd | while read -r user; do
                usermod -s /sbin/nologin "$user"
            done

            # [U-12] 세션 타임아웃 600초 (profile.d, profile, bashrc 반영)
            cat << 'EOF' > /etc/profile.d/timeout.sh
            export TMOUT=600
            readonly TMOUT
            EOF
            chmod 0644 /etc/profile.d/timeout.sh
            echo "export TMOUT=600" >> /etc/profile
            echo "readonly TMOUT" >> /etc/profile

            # [U-13] SHA512 암호화 알고리즘
            if grep -q "^ENCRYPT_METHOD" /etc/login.defs; then
                sed -i 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' /etc/login.defs
            else
                echo "ENCRYPT_METHOD SHA512" >> /etc/login.defs
            fi

            # =========================================================================
            # [U-15] 무소유자 파일 조치 및 Kubelet 구조적 미조치 보안 대책
            # =========================================================================
            # 1. Kubelet 및 Pods 상위 디렉터리를 root 전용 700 권한으로 통제 (가이드 대책 ①)
            mkdir -p /var/lib/kubelet/pods
            chown root:root /var/lib/kubelet /var/lib/kubelet/pods
            chmod 0700 /var/lib/kubelet /var/lib/kubelet/pods

            # 2. 계정 생성/UID 위변조 탐지를 위한 auditd 감시 룰 추가 (가이드 대책 ③)
            if command -v auditctl &>/dev/null; then
                auditctl -w /etc/passwd -p wa -k user_modification || true
            fi
            mkdir -p /etc/audit/rules.d
            echo "-w /etc/passwd -p wa -k user_modification" >> /etc/audit/rules.d/audit.rules || true

            # 3. 파드 볼륨(/var/lib/kubelet)과 컨테이너 런타임을 "제외한" 시스템 영역의 무소유자 파일만 정리
            find / -xdev \( -nouser -o -nogroup \) \
              -not -path "/var/lib/kubelet/*" \
              -not -path "/var/lib/containerd/*" \
              -exec chown root:root {} + 2>/dev/null || true

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

            # [U-23] 불필요한 SUID/SGID 제거 (점검 지적 목록 반영)
            chmod -s /usr/sbin/grub2-set-bootflag /usr/sbin/pam_timestamp_check /usr/bin/newgrp /usr/sbin/traceroute /usr/bin/pkexec 2>/dev/null || true

            # [U-27, U-29] 레거시 취약 파일 강제 삭제 (hosts.equiv, .rhosts, hosts.lpd)
            rm -f /etc/hosts.equiv /root/.rhosts /etc/hosts.lpd

            # [U-30] 기본 UMASK 022 명시 설정
            sed -i -E 's/UMASK\s+[0-9]+/UMASK 022/' /etc/login.defs || echo "UMASK 022" >> /etc/login.defs
            echo "umask 022" >> /etc/profile
            echo "umask 022" >> /etc/bashrc

            # [U-34 ~ U-52] 불필요 및 취약 데몬/소켓 비활성화
            # AL2023에 미설치되어 있으나, 감사 통과 및 예방 차원의 즉시 비활성화
            systemctl disable --now finger.socket rsh.socket rlogin.socket rexec.socket \
              echo-stream.socket echo-dgram.socket discard-stream.socket discard-dgram.socket \
              daytime-stream.socket daytime-dgram.socket tftp.socket telnet.socket 2>/dev/null || true

            # [U-37] crontab 및 at 명령어 권한 통제 (점검 가이드 전체 반영)
            # 1. crontab 및 at 바이너리 750 설정 (SUID 자동 제거)
            chmod 750 /usr/bin/crontab /usr/bin/at 2>/dev/null || true

            # 2. cron 및 at 설정 파일 권한(640 이하) 및 소유자(root) 통제
            [ -f /etc/crontab ] && chown root:root /etc/crontab && chmod 640 /etc/crontab || true
            [ -d /etc/cron.d ] && chown -R root:root /etc/cron.d && chmod 750 /etc/cron.d && chmod 640 /etc/cron.d/* 2>/dev/null || true

            # 3. cron.allow 생성 및 allow/deny 파일 권한 640 통제
            touch /etc/cron.allow
            chown root:root /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny 2>/dev/null || true
            chmod 640 /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny 2>/dev/null || true

            # [U-48] SMTP 서비스 비활성화 및 VRFY 명령어 차단 설정 (U-48 대응)
            systemctl disable --now postfix sendmail 2>/dev/null || true
            if [ -f /etc/postfix/main.cf ]; then
                grep -q "^disable_vrfy_command" /etc/postfix/main.cf && \
                  sed -i 's/^disable_vrfy_command.*/disable_vrfy_command = yes/' /etc/postfix/main.cf || \
                  echo "disable_vrfy_command = yes" >> /etc/postfix/main.cf
            fi

            # [U-53, U-55] FTP 서비스 비활성화, 배너 노출 제한 및 쉘 격리 (U-53, U-55 대응)
            systemctl disable --now vsftpd proftpd 2>/dev/null || true
            if [ -f /etc/vsftpd/vsftpd.conf ]; then
                grep -q "^ftpd_banner" /etc/vsftpd/vsftpd.conf && \
                  sed -i 's/^ftpd_banner.*/ftpd_banner=Authorized Users Only/' /etc/vsftpd/vsftpd.conf || \
                  echo "ftpd_banner=Authorized Users Only" >> /etc/vsftpd/vsftpd.conf
            fi
            if id ftp &>/dev/null; then
                usermod -s /sbin/nologin ftp || true
            fi

            # [U-62] 로그인 접속 배너 경고문구 단독 설정
            echo "Authorized users only. All activity may be monitored and reported." > /etc/issue
            echo "Authorized users only. All activity may be monitored and reported." > /etc/issue.net
            echo "Authorized users only. All activity may be monitored and reported." > /etc/motd

            # [U-65] NTP 서버 AWS 내부 단일화 (추가됨)
            if [ -f /etc/chrony.conf ]; then
                sed -i 's/^server /#server /' /etc/chrony.conf
                sed -i 's/^pool /#pool /' /etc/chrony.conf
                grep -q "169.254.169.123" /etc/chrony.conf || echo "server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4" >> /etc/chrony.conf
                systemctl restart chronyd || true
            fi

            # =========================================================================
            # [U-67] 주요 로그 파일 소유권 및 권한 관리 (점검 가이드 전체 반영)
            # =========================================================================

            # 1. wtmp, btmp, lastlog 파일 생성 및 권한 설정 (소유자: root)
            touch /var/log/wtmp /var/log/btmp /var/log/lastlog
            chown root:root /var/log/wtmp /var/log/btmp /var/log/lastlog
            chmod 0644 /var/log/wtmp /var/log/lastlog
            chmod 0600 /var/log/btmp

            # 2. systemd-tmpfiles 권한 원복 방지 설정 (/etc/tmpfiles.d/ 재정의 - 필수 요구사항)
            mkdir -p /etc/tmpfiles.d
            cat << 'EOF' > /etc/tmpfiles.d/security-hardening.conf
            f /var/log/wtmp 0644 root utmp -
            f /var/log/btmp 0600 root utmp -
            f /var/log/lastlog 0644 root root -
            EOF
            systemd-tmpfiles --create /etc/tmpfiles.d/security-hardening.conf || true

            # 3. 보안 감사 핵심 파일 권한 (640 이하)
            chmod 0640 /var/log/messages /var/log/secure /var/log/audit/audit.log 2>/dev/null || true
            find /var/log -type f -exec chmod go-w {} + 2>/dev/null || true

            # 4. chrony 로그는 데몬 정상 로깅 유지를 위해 chrony 소유 유지 및 권한 강화 (640 이하)
            if [ -d /var/log/chrony ]; then
                chown -R chrony:chrony /var/log/chrony
                chmod 0750 /var/log/chrony
                find /var/log/chrony -type f -exec chmod 0640 {} + 2>/dev/null || true
            fi
            
            echo "=== [Security Hardening] Complete ==="
          EOT
        }
      ]


    }
  }

  # EKS가 라우팅 및 게이트웨이, 서브넷보다 먼저 삭제되도록 명시
  depends_on = [
    aws_route_table_association.private_2a,
    aws_route_table_association.private_2c,
    aws_route_table_association.public_2a,
    aws_route_table_association.public_2c,
    aws_internet_gateway.igw,
    aws_instance.nat_instance_2a,
    aws_instance.nat_instance_2c,
    time_sleep.wait_for_nat
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

  triggers = {
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
