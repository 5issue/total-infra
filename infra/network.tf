# VPC, Subnet, IGW, Routing
# -------------------------------------------------------------
# VPC 
# -------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "eks-vpc"
  }
}
# -------------------------------------------------------------
# 서브넷
# -------------------------------------------------------------
resource "aws_subnet" "public_2a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true

  tags = {
    Name                     = "eks-public-2a"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "public_2c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "${var.aws_region}c"
  map_public_ip_on_launch = true

  tags = {
    Name                     = "eks-public-2c"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private_2a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.16.0/20"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = false

  tags = {
    Name                              = "eks-private-2a"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  }
}

resource "aws_subnet" "private_2c" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.32.0/20"
  availability_zone       = "${var.aws_region}c"
  map_public_ip_on_launch = false

  tags = {
    Name                              = "eks-private-2c"
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  }
}
# -------------------------------------------------------------
# IGW
# -------------------------------------------------------------
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "eks-igw" }
}
# -------------------------------------------------------------
# 라우팅 테이블
# -------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "eks-public-rt" }
}

resource "aws_route_table_association" "public_2a" {
  subnet_id      = aws_subnet.public_2a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_2c" {
  subnet_id      = aws_subnet.public_2c.id
  route_table_id = aws_route_table.public.id
}

# Private 2a 라우팅 테이블 -> nat_instance_2a 연결
resource "aws_route_table" "private_2a" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "eks-private-rt" }
}

resource "aws_route" "private_2a_nat" {
  route_table_id         = aws_route_table.private_2a.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat_instance_2a.primary_network_interface_id
}

resource "aws_route_table_association" "private_2a" {
  subnet_id      = aws_subnet.private_2a.id
  route_table_id = aws_route_table.private_2a.id
}

# Private 2c 라우팅 테이블 -> nat_instance_2c 연결
resource "aws_route_table" "private_2c" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "eks-private-rt-2c" }
}

resource "aws_route" "private_2c_nat" {
  route_table_id         = aws_route_table.private_2c.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.nat_instance_2c.primary_network_interface_id
}

resource "aws_route_table_association" "private_2c" {
  subnet_id      = aws_subnet.private_2c.id
  route_table_id = aws_route_table.private_2c.id
}