locals {
  vpc_cidr = "10.0.0.0/16"

  subnet_a_cidr = "10.0.10.0/24"
  subnet_b_cidr = "10.0.20.0/24"
  subnet_c_cidr = "10.0.30.0/24"

  # Random host octets: avoid .0, .1, .255, and common reserved-ish low IPs.
  host_min = 10
  host_max = 250

  # Packages requested. Debian uses "apache2" and "openssh-server".
  apt_packages = "tcpdump iptables openssh-server nginx apache2 vim"

  # Simple per-node start script
  start_script = <<-EOT
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "[start.sh] $(date -Is) running on $(hostname)"
    ip -br addr || true
    systemctl enable --now ssh || true
    systemctl enable --now nginx || true
    systemctl disable --now apache2 || true
    echo "OK" > /var/www/html/index.html
  EOT
}

data "aws_availability_zones" "available" {}

# Debian 12 (bookworm) official AMI via owner+name filter
# (Works in most regions; if it fails in yours, tell me your region and I’ll adjust the filter.)
data "aws_ami" "debian12" {
  most_recent = true
  owners      = ["136693071363"] # Debian Cloud official AWS account

  filter {
    name   = "name"
    values = ["debian-12-amd64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

resource "aws_key_pair" "this" {
  key_name   = var.key_name
  public_key = file(var.public_key_path)
}

resource "aws_vpc" "this" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

resource "aws_subnet" "a" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.subnet_a_cidr
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.name_prefix}-subnet-a" }
}

resource "aws_subnet" "b" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.subnet_b_cidr
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${var.name_prefix}-subnet-b" }
}

resource "aws_subnet" "c" {
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.subnet_c_cidr
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = { Name = "${var.name_prefix}-subnet-c" }
}

# Public route table for subnet A
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.name_prefix}-rt-public" }
}

resource "aws_route_table_association" "a_public" {
  subnet_id      = aws_subnet.a.id
  route_table_id = aws_route_table.public.id
}

# NAT gateway in subnet A (for B/C outbound apt-get without public IPs)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.name_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "nat" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.a.id
  depends_on    = [aws_internet_gateway.igw]
  tags          = { Name = "${var.name_prefix}-natgw" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat.id
  }
  tags = { Name = "${var.name_prefix}-rt-private" }
}

resource "aws_route_table_association" "b_private" {
  subnet_id      = aws_subnet.b.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "c_private" {
  subnet_id      = aws_subnet.c.id
  route_table_id = aws_route_table.private.id
}

# Security groups
resource "aws_security_group" "node_a" {
  name        = "${var.name_prefix}-sg-node-a"
  description = "Node A: SSH from allowed CIDR; HTTP from world; all VPC internal."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "VPC internal any"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg-node-a" }
}

resource "aws_security_group" "internal" {
  name        = "${var.name_prefix}-sg-internal"
  description = "Nodes B/C/D: SSH only from within VPC; allow all within VPC; egress all."
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "SSH from VPC"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.vpc_cidr]
  }

  ingress {
    description = "VPC internal any"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-sg-internal" }
}

# Random host octets for each interface that needs a fixed private IP
resource "random_integer" "a_host" {
  min = local.host_min
  max = local.host_max
}

resource "random_integer" "b_a_host" {
  min = local.host_min
  max = local.host_max
}

resource "random_integer" "b_b_host" {
  min = local.host_min
  max = local.host_max
}

resource "random_integer" "c_b_host" {
  min = local.host_min
  max = local.host_max
}

resource "random_integer" "c_c_host" {
  min = local.host_min
  max = local.host_max
}

resource "random_integer" "d_host" {
  min = local.host_min
  max = local.host_max
}


locals {
  ip_a   = "10.0.10.${random_integer.a_host.result}"
  ip_b_a = "10.0.10.${random_integer.b_a_host.result}"
  ip_b_b = "10.0.20.${random_integer.b_b_host.result}"
  ip_c_b = "10.0.20.${random_integer.c_b_host.result}"
  ip_c_c = "10.0.30.${random_integer.c_c_host.result}"
  ip_d   = "10.0.30.${random_integer.d_host.result}"
}

# Cloud-init/user-data
locals {
  user_data_common = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ${local.apt_packages}
    cat > /usr/local/bin/start.sh <<'SCRIPT'
    ${local.start_script}
    SCRIPT
    chmod +x /usr/local/bin/start.sh
    /usr/local/bin/start.sh
  EOT
}

# ENIs
resource "aws_network_interface" "eni_a" {
  subnet_id       = aws_subnet.a.id
  private_ips     = [local.ip_a]
  security_groups = [aws_security_group.node_a.id]
  tags            = { Name = "${var.name_prefix}-eni-a" }
}

resource "aws_network_interface" "eni_b_a" {
  subnet_id       = aws_subnet.a.id
  private_ips     = [local.ip_b_a]
  security_groups = [aws_security_group.internal.id]
  tags            = { Name = "${var.name_prefix}-eni-b-a" }
}

resource "aws_network_interface" "eni_b_b" {
  subnet_id       = aws_subnet.b.id
  private_ips     = [local.ip_b_b]
  security_groups = [aws_security_group.internal.id]
  tags            = { Name = "${var.name_prefix}-eni-b-b" }
}

resource "aws_network_interface" "eni_c_b" {
  subnet_id       = aws_subnet.b.id
  private_ips     = [local.ip_c_b]
  security_groups = [aws_security_group.internal.id]
  tags            = { Name = "${var.name_prefix}-eni-c-b" }
}

resource "aws_network_interface" "eni_c_c" {
  subnet_id       = aws_subnet.c.id
  private_ips     = [local.ip_c_c]
  security_groups = [aws_security_group.internal.id]
  tags            = { Name = "${var.name_prefix}-eni-c-c" }
}

resource "aws_network_interface" "eni_d" {
  subnet_id       = aws_subnet.c.id
  private_ips     = [local.ip_d]
  security_groups = [aws_security_group.internal.id]
  tags            = { Name = "${var.name_prefix}-eni-d" }
}

# Instances
resource "aws_instance" "node_a" {
  ami                         = data.aws_ami.debian12.id
  instance_type               = var.instance_type
  key_name                    = aws_key_pair.this.key_name
  user_data                   = local.user_data_common
  associate_public_ip_address = true

  network_interface {
    network_interface_id = aws_network_interface.eni_a.id
    device_index         = 0
  }

  tags = { Name = "${var.name_prefix}-node-a" }
}

resource "aws_instance" "node_b" {
  ami           = data.aws_ami.debian12.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.this.key_name
  user_data     = local.user_data_common

  network_interface {
    network_interface_id = aws_network_interface.eni_b_a.id
    device_index         = 0
  }

  network_interface {
    network_interface_id = aws_network_interface.eni_b_b.id
    device_index         = 1
  }

  tags = { Name = "${var.name_prefix}-node-b" }
}

resource "aws_instance" "node_c" {
  ami           = data.aws_ami.debian12.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.this.key_name
  user_data     = local.user_data_common

  network_interface {
    network_interface_id = aws_network_interface.eni_c_b.id
    device_index         = 0
  }

  network_interface {
    network_interface_id = aws_network_interface.eni_c_c.id
    device_index         = 1
  }

  tags = { Name = "${var.name_prefix}-node-c" }
}

resource "aws_instance" "node_d" {
  ami           = data.aws_ami.debian12.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.this.key_name
  user_data     = local.user_data_common

  network_interface {
    network_interface_id = aws_network_interface.eni_d.id
    device_index         = 0
  }

  tags = { Name = "${var.name_prefix}-node-d" }
}
