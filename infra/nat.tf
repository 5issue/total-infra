# -------------------------------------------------------------
# NAT 인스턴스 (ARM64 t4g.nano)
# -------------------------------------------------------------
data "aws_ami" "amazon_linux_2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-arm64"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }
}

resource "aws_security_group" "nat_sg" {
  name        = "nat-instance-sg"
  description = "Security group for NAT Instance"
  vpc_id      = aws_vpc.main.id

  # [U-28 대응] 22번 포트를 제외하고, NAT 포워딩에 필요한 VPC 내부 트래픽만 인바운드 허용
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
    description = "Allow HTTP from VPC for NAT"
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
    description = "Allow HTTPS from VPC for NAT"
  }

  ingress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [aws_vpc.main.cidr_block]
    description = "Allow DNS UDP from VPC for NAT"
  }

  ingress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
    description = "Allow DNS TCP from VPC for NAT"
  }

  ingress {
    from_port   = 123
    to_port     = 123
    protocol    = "udp"
    cidr_blocks = [aws_vpc.main.cidr_block]
    description = "Allow NTP from VPC for NAT"
  }

  ingress {
    from_port   = 1024
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
    description = "Allow High Ephemeral Ports from VPC"
  }

  # [아웃바운드 1] HTTP (80)
  egress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTP outbound"
  }

  # [아웃바운드 2] HTTPS (443 - AWS API, ECR, 패키지 다운로드)
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow HTTPS outbound"
  }

  # [아웃바운드 3] DNS (53 - TCP/UDP)
  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow DNS UDP outbound"
  }
  egress {
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow DNS TCP outbound"
  }

  # [아웃바운드 4] NTP (123 - 시간 동기화)
  egress {
    from_port   = 123
    to_port     = 123
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow NTP outbound"
  }

  tags = { Name = "nat-instance-sg" }
}

resource "aws_iam_role" "ssm_role" {
  name = "nat-instance-ssm-role-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "nat-instance-ssm-profile-${var.cluster_name}"
  role = aws_iam_role.ssm_role.name
}

# NAT 2a 인스턴스 (AZ-a 전용)
resource "aws_instance" "nat_instance_2a" {
  ami                         = data.aws_ami.amazon_linux_2023_arm64.id
  instance_type               = "t4g.micro"
  subnet_id                   = aws_subnet.public_2a.id
  vpc_security_group_ids      = [aws_security_group.nat_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  associate_public_ip_address = true
  source_dest_check           = false

  user_data = <<-EOT
    #!/bin/bash

    # 기존 NAT 설정
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/nat.conf
    dnf install -y iptables-services
    iptables -t nat -A POSTROUTING -o $(ip route show default | awk '{print $5}') -j MASQUERADE
    service iptables save
    systemctl enable --now iptables

    # 하드닝 시작
    echo "=== [Security Hardening] Start ==="

    # [U-01] root SSH 접속 제한
    mkdir -p /etc/ssh/sshd_config.d
    echo "PermitRootLogin no" > /etc/ssh/sshd_config.d/01-hardening.conf
    if /usr/sbin/sshd -t; then
      systemctl reload sshd || systemctl restart sshd
    fi

    # [U-02 & U-03] 비밀번호 최소 길이, 복잡도, 만료 주기(90/1), 계정 잠금(5회/600초)
    mkdir -p /etc/security
    echo "minlen = 8" > /etc/security/pwquality.conf
    echo "dcredit = -1" >> /etc/security/pwquality.conf
    echo "ucredit = -1" >> /etc/security/pwquality.conf
    echo "lcredit = -1" >> /etc/security/pwquality.conf
    echo "ocredit = -1" >> /etc/security/pwquality.conf

    sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs || echo "PASS_MAX_DAYS   90" >> /etc/login.defs
    sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' /etc/login.defs || echo "PASS_MIN_DAYS   1" >> /etc/login.defs
    chage -M 90 -m 1 root || true
    id ec2-user &>/dev/null && chage -M 90 -m 1 ec2-user || true

    authselect enable-feature with-faillock || true
    authselect enable-feature with-pwhistory || true
    authselect apply-changes || true

    sed -i 's/^#\?deny\s*=.*/deny = 5/' /etc/security/faillock.conf || echo "deny = 5" >> /etc/security/faillock.conf
    sed -i 's/^#\?unlock_time\s*=.*/unlock_time = 600/' /etc/security/faillock.conf || echo "unlock_time = 600" >> /etc/security/faillock.conf
    sed -i 's/^#\?remember\s*=.*/remember = 6/' /etc/security/pwhistory.conf || echo "remember = 6" >> /etc/security/pwhistory.conf

    # [U-06] su 명령어 wheel 제한 및 사용자 추가
    grep -q "pam_wheel.so use_uid" /etc/pam.d/su || echo "auth required pam_wheel.so use_uid" >> /etc/pam.d/su
    sed -i 's/^#\s*\(auth\s\+required\s\+pam_wheel\.so\s\+use_uid\)/\1/' /etc/pam.d/su
    usermod -aG wheel root
    id ec2-user &>/dev/null && usermod -aG wheel ec2-user || true

    # [U-07] ec2-user 로그인 잠금 (접속은 SSM 이용)
    id ec2-user &>/dev/null && usermod -L -s /sbin/nologin ec2-user || true

    # [U-12] 세션 타임아웃
    echo "export TMOUT=600" > /etc/profile.d/timeout.sh
    echo "readonly TMOUT" >> /etc/profile.d/timeout.sh
    chmod 0644 /etc/profile.d/timeout.sh
    echo "export TMOUT=600" >> /etc/profile
    echo "readonly TMOUT" >> /etc/profile

    # [U-13] 비밀번호 해시 SHA512
    if grep -q "^ENCRYPT_METHOD" /etc/login.defs; then
      sed -i 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' /etc/login.defs
    else
      echo "ENCRYPT_METHOD SHA512" >> /etc/login.defs
    fi

    # [U-23] 불필요한 SUID 제거 (점검 지적 대상 포함)
    chmod -s /usr/sbin/grub2-set-bootflag /usr/sbin/pam_timestamp_check /usr/bin/newgrp /usr/sbin/traceroute /usr/bin/pkexec 2>/dev/null || true

    # [U-30] 기본 UMASK 022 (login.defs, profile, bashrc)
    sed -i -E 's/UMASK\s+[0-9]+/UMASK 022/' /etc/login.defs || echo "UMASK 022" >> /etc/login.defs
    echo "umask 022" >> /etc/profile
    echo "umask 022" >> /etc/bashrc

    # [U-37] crontab 및 at 권한 통제
    chmod 750 /usr/bin/crontab /usr/bin/at 2>/dev/null || true
    [ -f /etc/crontab ] && chown root:root /etc/crontab && chmod 640 /etc/crontab || true
    [ -d /etc/cron.d ] && chown -R root:root /etc/cron.d && chmod 750 /etc/cron.d && chmod 640 /etc/cron.d/* 2>/dev/null || true
    touch /etc/cron.allow
    chown root:root /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny 2>/dev/null || true
    chmod 640 /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny 2>/dev/null || true

    # [U-62 추가] 로그인 접속 배너 경고문구 설정
    echo "Authorized users only. All activity may be monitored and reported." > /etc/issue
    echo "Authorized users only. All activity may be monitored and reported." > /etc/issue.net
    echo "Authorized users only. All activity may be monitored and reported." > /etc/motd

    # U-65: AWS NTP(169.254.169.123) 단일화
    if [ -f /etc/chrony.conf ]; then
      sed -i 's/^server /#server /' /etc/chrony.conf
      sed -i 's/^pool /#pool /' /etc/chrony.conf
      echo "server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4" >> /etc/chrony.conf
      systemctl restart chronyd || true
    fi

    # [U-67] 로그 파일, tmpfiles 권한 원복 방지 및 chrony 권한
    touch /var/log/wtmp /var/log/btmp /var/log/lastlog
    chown root:root /var/log/wtmp /var/log/btmp /var/log/lastlog
    chmod 0644 /var/log/wtmp /var/log/lastlog
    chmod 0600 /var/log/btmp

    mkdir -p /etc/tmpfiles.d
    echo "f /var/log/wtmp 0644 root utmp -" > /etc/tmpfiles.d/security-hardening.conf
    echo "f /var/log/btmp 0600 root utmp -" >> /etc/tmpfiles.d/security-hardening.conf
    echo "f /var/log/lastlog 0644 root root -" >> /etc/tmpfiles.d/security-hardening.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/security-hardening.conf || true

    chmod 0640 /var/log/messages /var/log/secure 2>/dev/null || true
    find /var/log -type f -exec chmod go-w {} + 2>/dev/null || true

    if [ -d /var/log/chrony ]; then
      chown -R chrony:chrony /var/log/chrony
      chmod 0750 /var/log/chrony
      find /var/log/chrony -type f -exec chmod 0640 {} + 2>/dev/null || true
    fi

    echo "=== [Security Hardening] Script finished ==="
  EOT

  tags = { Name = "eks-nat-instance-2a" }
}

# NAT 2c 인스턴스 (AZ-c 전용)
resource "aws_instance" "nat_instance_2c" {
  ami                         = data.aws_ami.amazon_linux_2023_arm64.id
  instance_type               = "t4g.micro"
  subnet_id                   = aws_subnet.public_2c.id
  vpc_security_group_ids      = [aws_security_group.nat_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  associate_public_ip_address = true
  source_dest_check           = false

  user_data = <<-EOT
    #!/bin/bash

    # 기존 NAT 설정
    echo 1 > /proc/sys/net/ipv4/ip_forward
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/nat.conf
    dnf install -y iptables-services
    iptables -t nat -A POSTROUTING -o $(ip route show default | awk '{print $5}') -j MASQUERADE
    service iptables save
    systemctl enable --now iptables

    # 하드닝 시작
    echo "=== [Security Hardening] Start ==="

    # [U-01] root SSH 접속 제한
    mkdir -p /etc/ssh/sshd_config.d
    echo "PermitRootLogin no" > /etc/ssh/sshd_config.d/01-hardening.conf
    if /usr/sbin/sshd -t; then
      systemctl reload sshd || systemctl restart sshd
    fi

    # [U-02 & U-03] 비밀번호 최소 길이, 복잡도, 만료 주기(90/1), 계정 잠금(5회/600초)
    mkdir -p /etc/security
    echo "minlen = 8" > /etc/security/pwquality.conf
    echo "dcredit = -1" >> /etc/security/pwquality.conf
    echo "ucredit = -1" >> /etc/security/pwquality.conf
    echo "lcredit = -1" >> /etc/security/pwquality.conf
    echo "ocredit = -1" >> /etc/security/pwquality.conf

    sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS   90/' /etc/login.defs || echo "PASS_MAX_DAYS   90" >> /etc/login.defs
    sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS   1/' /etc/login.defs || echo "PASS_MIN_DAYS   1" >> /etc/login.defs
    chage -M 90 -m 1 root || true
    id ec2-user &>/dev/null && chage -M 90 -m 1 ec2-user || true

    authselect enable-feature with-faillock || true
    authselect enable-feature with-pwhistory || true
    authselect apply-changes || true

    sed -i 's/^#\?deny\s*=.*/deny = 5/' /etc/security/faillock.conf || echo "deny = 5" >> /etc/security/faillock.conf
    sed -i 's/^#\?unlock_time\s*=.*/unlock_time = 600/' /etc/security/faillock.conf || echo "unlock_time = 600" >> /etc/security/faillock.conf
    sed -i 's/^#\?remember\s*=.*/remember = 6/' /etc/security/pwhistory.conf || echo "remember = 6" >> /etc/security/pwhistory.conf

    # [U-06] su 명령어 wheel 제한 및 사용자 추가
    grep -q "pam_wheel.so use_uid" /etc/pam.d/su || echo "auth required pam_wheel.so use_uid" >> /etc/pam.d/su
    sed -i 's/^#\s*\(auth\s\+required\s\+pam_wheel\.so\s\+use_uid\)/\1/' /etc/pam.d/su
    usermod -aG wheel root
    id ec2-user &>/dev/null && usermod -aG wheel ec2-user || true

    # [U-07] ec2-user 로그인 잠금 (접속은 SSM 이용)
    id ec2-user &>/dev/null && usermod -L -s /sbin/nologin ec2-user || true

    # [U-12] 세션 타임아웃
    echo "export TMOUT=600" > /etc/profile.d/timeout.sh
    echo "readonly TMOUT" >> /etc/profile.d/timeout.sh
    chmod 0644 /etc/profile.d/timeout.sh
    echo "export TMOUT=600" >> /etc/profile
    echo "readonly TMOUT" >> /etc/profile

    # [U-13] 비밀번호 해시 SHA512
    if grep -q "^ENCRYPT_METHOD" /etc/login.defs; then
      sed -i 's/^ENCRYPT_METHOD.*/ENCRYPT_METHOD SHA512/' /etc/login.defs
    else
      echo "ENCRYPT_METHOD SHA512" >> /etc/login.defs
    fi

    # [U-23] 불필요한 SUID 제거 (점검 지적 대상 포함)
    chmod -s /usr/sbin/grub2-set-bootflag /usr/sbin/pam_timestamp_check /usr/bin/newgrp /usr/sbin/traceroute /usr/bin/pkexec 2>/dev/null || true

    # [U-30] 기본 UMASK 022 (login.defs, profile, bashrc)
    sed -i -E 's/UMASK\s+[0-9]+/UMASK 022/' /etc/login.defs || echo "UMASK 022" >> /etc/login.defs
    echo "umask 022" >> /etc/profile
    echo "umask 022" >> /etc/bashrc

    # [U-37] crontab 및 at 권한 통제
    chmod 750 /usr/bin/crontab /usr/bin/at 2>/dev/null || true
    [ -f /etc/crontab ] && chown root:root /etc/crontab && chmod 640 /etc/crontab || true
    [ -d /etc/cron.d ] && chown -R root:root /etc/cron.d && chmod 750 /etc/cron.d && chmod 640 /etc/cron.d/* 2>/dev/null || true
    touch /etc/cron.allow
    chown root:root /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny 2>/dev/null || true
    chmod 640 /etc/cron.allow /etc/cron.deny /etc/at.allow /etc/at.deny 2>/dev/null || true

    # [U-62 추가] 로그인 접속 배너 경고문구 설정
    echo "Authorized users only. All activity may be monitored and reported." > /etc/issue
    echo "Authorized users only. All activity may be monitored and reported." > /etc/issue.net
    echo "Authorized users only. All activity may be monitored and reported." > /etc/motd

    # U-65: AWS NTP(169.254.169.123) 단일화
    if [ -f /etc/chrony.conf ]; then
      sed -i 's/^server /#server /' /etc/chrony.conf
      sed -i 's/^pool /#pool /' /etc/chrony.conf
      echo "server 169.254.169.123 prefer iburst minpoll 4 maxpoll 4" >> /etc/chrony.conf
      systemctl restart chronyd || true
    fi

    # [U-67] 로그 파일, tmpfiles 권한 원복 방지 및 chrony 권한
    touch /var/log/wtmp /var/log/btmp /var/log/lastlog
    chown root:root /var/log/wtmp /var/log/btmp /var/log/lastlog
    chmod 0644 /var/log/wtmp /var/log/lastlog
    chmod 0600 /var/log/btmp

    mkdir -p /etc/tmpfiles.d
    echo "f /var/log/wtmp 0644 root utmp -" > /etc/tmpfiles.d/security-hardening.conf
    echo "f /var/log/btmp 0600 root utmp -" >> /etc/tmpfiles.d/security-hardening.conf
    echo "f /var/log/lastlog 0644 root root -" >> /etc/tmpfiles.d/security-hardening.conf
    systemd-tmpfiles --create /etc/tmpfiles.d/security-hardening.conf || true

    chmod 0640 /var/log/messages /var/log/secure 2>/dev/null || true
    find /var/log -type f -exec chmod go-w {} + 2>/dev/null || true

    if [ -d /var/log/chrony ]; then
      chown -R chrony:chrony /var/log/chrony
      chmod 0750 /var/log/chrony
      find /var/log/chrony -type f -exec chmod 0640 {} + 2>/dev/null || true
    fi

    echo "=== [Security Hardening] Script finished ==="
  EOT

  tags = { Name = "eks-nat-instance-2c" }
}

resource "time_sleep" "wait_for_nat" {
  depends_on      = [aws_instance.nat_instance_2a, aws_instance.nat_instance_2c]
  create_duration = "30s" # NAT 부팅 및 iptables 세팅이 안정화될 때까지 30초 대기
}