# ==============================================================================
# [보안 요구사항 3.3] 서브넷 전용 Custom NACL (Any-Any Default NACL 대체)
# ==============================================================================

# 1. 퍼블릭 서브넷 NACL (ALB 및 NAT 인스턴스)
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.public_2a.id, aws_subnet.public_2c.id]

  # [Inbound] HTTP (80), HTTPS (443)
  ingress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # [Inbound] VPC 내부 통신
  ingress {
    rule_no    = 120
    protocol   = "-1"
    action     = "allow"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 0
    to_port    = 0
  }

  # [Inbound] 임시 포트 (NAT 인스턴스 아웃바운드 응답 수신)
  ingress {
    rule_no    = 130
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # [Outbound] HTTP (80), HTTPS (443)
  egress {
    rule_no    = 100
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }
  egress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # [Outbound] DNS (53 UDP/TCP), NTP (123 UDP)
  egress {
    rule_no    = 120
    protocol   = "udp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 53
    to_port    = 53
  }
  egress {
    rule_no    = 121
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 53
    to_port    = 53
  }
  egress {
    rule_no    = 130
    protocol   = "udp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 123
    to_port    = 123
  }

  # [Outbound] VPC 내부 통신
  egress {
    rule_no    = 140
    protocol   = "-1"
    action     = "allow"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 0
    to_port    = 0
  }

  # [Outbound] 임시 포트 (웹 요청 응답 반환)
  egress {
    rule_no    = 150
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  tags = { Name = "eks-public-nacl" }
}

# 2. 프라이빗 서브넷 NACL (EKS 워커 노드 및 파드)
resource "aws_network_acl" "private" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [aws_subnet.private_2a.id, aws_subnet.private_2c.id]

  # [Inbound] VPC 내부 통신 전체 허용
  ingress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 0
    to_port    = 0
  }

  # [Inbound] 임시 포트 (NAT 경유 아웃바운드 응답 수신)
  ingress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  # [Outbound] VPC 내부 통신 전체 허용
  egress {
    rule_no    = 100
    protocol   = "-1"
    action     = "allow"
    cidr_block = aws_vpc.main.cidr_block
    from_port  = 0
    to_port    = 0
  }

  # [Outbound] HTTP (80), HTTPS (443)
  egress {
    rule_no    = 110
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 80
    to_port    = 80
  }
  egress {
    rule_no    = 120
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 443
    to_port    = 443
  }

  # [Outbound] DNS & NTP
  egress {
    rule_no    = 130
    protocol   = "udp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 53
    to_port    = 53
  }
  egress {
    rule_no    = 131
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 53
    to_port    = 53
  }
  egress {
    rule_no    = 140
    protocol   = "udp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 123
    to_port    = 123
  }

  # [Outbound] 임시 포트 (내부 요청에 대한 응답 반환)
  egress {
    rule_no    = 150
    protocol   = "tcp"
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 1024
    to_port    = 65535
  }

  tags = { Name = "eks-private-nacl" }
}