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

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  # egress {
  #   from_port   = 0
  #   to_port     = 0
  #   protocol    = "-1"
  #   cidr_blocks = ["0.0.0.0/0"]
  # }

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

    # U-01: root SSH 접속 제한
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/01-hardening.conf <<'CONF'
    PermitRootLogin no
    CONF
    if /usr/sbin/sshd -t; then
      systemctl reload sshd || systemctl restart sshd
    fi

    # U-02: 비밀번호 최소 길이 및 복잡도
    cat > /etc/security/pwquality.conf <<'CONF'
    minlen = 8
    dcredit = -1
    ucredit = -1
    lcredit = -1
    ocredit = -1
    CONF

    # U-12: 세션 타임아웃
    cat > /etc/profile.d/timeout.sh <<'CONF'
    export TMOUT=600
    readonly TMOUT
    CONF
    chmod 0644 /etc/profile.d/timeout.sh

    # U-13: 비밀번호 해시 기본값
    if grep -qE '^[[:space:]]*ENCRYPT_METHOD[[:space:]]' /etc/login.defs; then
      sed -i -E 's/^[[:space:]]*ENCRYPT_METHOD[[:space:]].*/ENCRYPT_METHOD SHA512/' /etc/login.defs
    else
      echo "ENCRYPT_METHOD SHA512" >> /etc/login.defs
    fi

    # U-30: 기본 UMASK
    if grep -qE '^[[:space:]]*UMASK[[:space:]]' /etc/login.defs; then
      sed -i -E 's/^[[:space:]]*UMASK[[:space:]].*/UMASK 022/' /etc/login.defs
    else
      echo "UMASK 022" >> /etc/login.defs
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

    # U-01: root SSH 접속 제한
    mkdir -p /etc/ssh/sshd_config.d
    cat > /etc/ssh/sshd_config.d/01-hardening.conf <<'CONF'
    PermitRootLogin no
    CONF
    if /usr/sbin/sshd -t; then
      systemctl reload sshd || systemctl restart sshd
    fi

    # U-02: 비밀번호 최소 길이 및 복잡도
    cat > /etc/security/pwquality.conf <<'CONF'
    minlen = 8
    dcredit = -1
    ucredit = -1
    lcredit = -1
    ocredit = -1
    CONF

    # U-12: 세션 타임아웃
    cat > /etc/profile.d/timeout.sh <<'CONF'
    export TMOUT=600
    readonly TMOUT
    CONF
    chmod 0644 /etc/profile.d/timeout.sh

    # U-13: 비밀번호 해시 기본값
    if grep -qE '^[[:space:]]*ENCRYPT_METHOD[[:space:]]' /etc/login.defs; then
      sed -i -E 's/^[[:space:]]*ENCRYPT_METHOD[[:space:]].*/ENCRYPT_METHOD SHA512/' /etc/login.defs
    else
      echo "ENCRYPT_METHOD SHA512" >> /etc/login.defs
    fi

    # U-30: 기본 UMASK
    if grep -qE '^[[:space:]]*UMASK[[:space:]]' /etc/login.defs; then
      sed -i -E 's/^[[:space:]]*UMASK[[:space:]].*/UMASK 022/' /etc/login.defs
    else
      echo "UMASK 022" >> /etc/login.defs
    fi

    echo "=== [Security Hardening] Script finished ==="
  EOT

  tags = { Name = "eks-nat-instance-2c" }
}

resource "time_sleep" "wait_for_nat" {
  depends_on      = [aws_instance.nat_instance_2a, aws_instance.nat_instance_2c]
  create_duration = "30s" # NAT 부팅 및 iptables 세팅이 안정화될 때까지 30초 대기
}