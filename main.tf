provider "aws" {
  region = var.region
}

# VPC
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
}

# Public Subnets
resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[0]
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = true
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[1]
  availability_zone       = var.azs[1]
  map_public_ip_on_launch = true
}

# Private Subnets
resource "aws_subnet" "private_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[0]
  availability_zone       = var.azs[0]
  map_public_ip_on_launch = false
}

resource "aws_subnet" "private_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.private_subnet_cidrs[1]
  availability_zone       = var.azs[1]
  map_public_ip_on_launch = false
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# Route Table for Public Subnet
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

# NAT Gateways
resource "aws_eip" "nat_1" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_1" {
  allocation_id = aws_eip.nat_1.id
  subnet_id     = aws_subnet.public_1.id
}

resource "aws_eip" "nat_2" {
  domain = "vpc"
}

resource "aws_nat_gateway" "nat_2" {
  allocation_id = aws_eip.nat_2.id
  subnet_id     = aws_subnet.public_2.id
}

# Route Table for Private Subnets
resource "aws_route_table" "private_1" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_1.id
  }
}

resource "aws_route_table_association" "private_1_association" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private_1.id
}

resource "aws_route_table" "private_2" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_2.id
  }
}

resource "aws_route_table_association" "private_2_association" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private_2.id
}

# Security Group for ALB
resource "aws_security_group" "alb_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Security Group for EC2 instances
resource "aws_security_group" "web_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Application Load Balancer
resource "aws_lb" "main" {
  name               = "web-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public_1.id, aws_subnet.public_2.id]  # Use both public subnets
}

# Target Group for ALB
resource "aws_lb_target_group" "main" {
  name     = "web-targets-mine"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id
  health_check {
    path                = "/"
    interval            = 30
    protocol            = "HTTP"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# Listener for ALB
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# Launch Template for Auto Scaling Group
resource "aws_launch_template" "web" {
  name_prefix   = "web-launch-template"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type
  key_name      = var.key_name

  user_data = filebase64("${path.module}/userdata.sh")

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = [aws_security_group.web_sg.id]
  }
}

# Auto Scaling Group (spread across both private subnets)
resource "aws_autoscaling_group" "web-asg" {
  desired_capacity     = var.desired_capacity
  max_size             = var.max_size
  min_size             = var.min_size
  vpc_zone_identifier  = [aws_subnet.private_1.id, aws_subnet.private_2.id]   # Use both private subnets
  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }
  depends_on = [aws_lb_target_group.main]
  target_group_arns = [aws_lb_target_group.main.arn]
}

# Data source for Amazon Linux 2 AMI
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }
}

resource "aws_db_instance" "my_rds_instance" {
  allocated_storage    = 20                        # Adjust based on your requirements
  engine               = "mysql"                   # Use "postgres" for PostgreSQL
  engine_version       = "8.0.39"                  # Adjust based on your DB engine
  instance_class       = "db.t3.micro"             # Adjust to your needs
  identifier           = "my-db-instance"
  username             = var.db_username
  password             = var.db_password
  parameter_group_name = "default.mysql8.0"        # Parameter group for MySQL 8.0
  skip_final_snapshot  = true                      # To skip snapshot on deletion
  publicly_accessible  = false                     # Ensure it's not publicly accessible

  vpc_security_group_ids = [aws_security_group.rds_sg.id]  # Security group for RDS

  db_subnet_group_name = aws_db_subnet_group.rds_subnet_group.name  # Subnets for RDS

  # Define maintenance and backup windows as needed
  backup_retention_period = 7                    # Retain backups for 7 days
  backup_window           = "03:00-04:00"        # Adjust based on your needs
  maintenance_window      = "sun:04:00-sun:05:00"  # Define maintenance window
}

resource "aws_db_subnet_group" "rds_subnet_group" {
  name       = "my-rds-subnet-group"
  subnet_ids = [aws_subnet.private_1.id, aws_subnet.private_2.id]  # Your private subnets

  tags = {
    Name = "my-rds-subnet-group"
  }
}

resource "aws_security_group" "rds_sg" {
  name        = "rds-security-group"
  description = "Allow EC2 instances to access RDS"

  vpc_id = aws_vpc.main.id   # The VPC where the RDS and EC2 instances are located

  ingress {
    from_port   = 3306        # Port for MySQL, use 5432 for PostgreSQL
    to_port     = 3306
    protocol    = "tcp"
    security_groups = [aws_security_group.web_sg.id]  # Allow traffic from EC2 security group
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]  # Allow all outbound traffic (or restrict as needed)
  }

  tags = {
    Name = "rds-security-group"
  }
}
