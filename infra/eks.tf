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
    # CLI / Terraform 스크립트 실행용 공용 관리자 Role (AssumeRole + MFA)
    target_infra_role = {
      principal_arn = data.aws_iam_role.target_infra.arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
      # 쿠버네티스 내부에서 활동할 그룹 지정
      kubernetes_groups = ["db-admin-readers"]
    }

    # Workload publication uses Kubernetes RBAC only. Do not associate an
    # EKS access policy with this entry.
    workload_publication = {
      principal_arn     = aws_iam_role.workload_publication.arn
      kubernetes_groups = [local.workload_publication_group]
    }

    # 팀원 5명 개인 IAM User (웹 콘솔 직접 조회 및 권한 부여)
    jongwon = {
      principal_arn = "arn:aws:iam::596601390909:user/infra-jongwon"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
      kubernetes_groups = ["db-admin-readers"]
    }

    youngheon = {
      principal_arn = "arn:aws:iam::596601390909:user/infra-youngheon"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
      kubernetes_groups = ["db-admin-readers"]
    }

    mingyu = {
      principal_arn = "arn:aws:iam::596601390909:user/infra-mingyu"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
      kubernetes_groups = ["db-admin-readers"]
    }

    jaehyeok = {
      principal_arn = "arn:aws:iam::596601390909:user/infra-jaehyeok"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
      kubernetes_groups = ["db-admin-readers"]
    }

    jiyoon = {
      principal_arn = "arn:aws:iam::596601390909:user/infra-jiyoon"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
      kubernetes_groups = ["db-admin-readers"]
    }

    # =========================================================================
    # 백엔드 개발팀 전용 Access Entry (ClusterAdmin 권한 제외, K8s RBAC 연동용)
    # =========================================================================
    be_user1 = {
      principal_arn     = "arn:aws:iam::596601390909:user/be-user1"
      kubernetes_groups = ["backend-developers"]
      # 주의: policy_associations(AmazonEKSClusterAdminPolicy)를 넣지 않습니다!
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

  node_security_group_additional_rules = {
    ingress_vpc_all = {
      description = "Allow all traffic from VPC CIDR"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
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

            # [U-13] 패스워드 안전 암호화 저장 (감사 기준 가이드 준수: SHA512)
            if grep -q "^ENCRYPT_METHOD" /etc/login.defs; then
                sed -i 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' /etc/login.defs
            else
                echo "ENCRYPT_METHOD SHA512" >> /etc/login.defs
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

            # [U-67] 주요 로그 파일 소유권 및 상세 권한 보강
            find /var/log -type f -exec chmod go-w {} + 2>/dev/null || true
            # 보안 감사 핵심 파일 640 적용
            chmod 0640 /var/log/messages /var/log/secure /var/log/audit/audit.log 2>/dev/null || true
            
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
