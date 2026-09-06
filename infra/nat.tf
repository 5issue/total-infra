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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.public_2a.id
  vpc_security_group_ids      = [aws_security_group.nat_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  associate_public_ip_address = true
  source_dest_check           = false

  user_data = <<-EOF
              #!/bin/bash
              echo 1 > /proc/sys/net/ipv4/ip_forward
              echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/nat.conf
              dnf install -y iptables-services
              iptables -t nat -A POSTROUTING -o $(ip route show default | awk '{print $5}') -j MASQUERADE
              service iptables save
              systemctl enable --now iptables
              EOF

  tags = { Name = "eks-nat-instance-2a" }
}

# NAT 2c 인스턴스 (AZ-c 전용)
resource "aws_instance" "nat_instance_2c" {
  ami                         = data.aws_ami.amazon_linux_2023_arm64.id
  instance_type               = "t4g.nano"
  subnet_id                   = aws_subnet.public_2c.id
  vpc_security_group_ids      = [aws_security_group.nat_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  associate_public_ip_address = true
  source_dest_check           = false

  user_data = <<-EOF
              #!/bin/bash
              echo 1 > /proc/sys/net/ipv4/ip_forward
              echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.d/nat.conf
              dnf install -y iptables-services
              iptables -t nat -A POSTROUTING -o $(ip route show default | awk '{print $5}') -j MASQUERADE
              service iptables save
              systemctl enable --now iptables
              EOF

  tags = { Name = "eks-nat-instance-2c" }
}