# Определяем провайдера
provider "aws" {
  region = "us-east-1" # Указываем регион
}

# Создаем VPC и подсети
resource "aws_vpc" "demoapp_vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "demoapp-vpc"
  }
}

resource "aws_internet_gateway" "inet_gateway" {
  vpc_id = aws_vpc.demoapp_vpc.id
  tags = {
    Name = "inet-gateway"
  }
}


resource "aws_subnet" "demoapp_privat_subnet_a" {
  vpc_id = aws_vpc.demoapp_vpc.id
  cidr_block = "10.0.1.0/24"
  availability_zone = "us-east-1a"
  tags = {
    Name = "demoapp-subnet-a"
  }
}

resource "aws_subnet" "demoapp_subnet_a_pub" {
  vpc_id = aws_vpc.demoapp_vpc.id
  cidr_block = "10.0.3.0/24"
  availability_zone = "us-east-1a"
  map_public_ip_on_launch = true
  tags = {
    Name = "demoapp-subnet-a-pub"
  }
}

resource "aws_subnet" "demoapp_privat_subnet_b" {
  vpc_id            = aws_vpc.demoapp_vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "us-east-1b"
  tags              = {
    Name = "demoapp-subnet-b"
  }
}

resource "aws_subnet" "demoapp_subnet_b_pub" {
  vpc_id = aws_vpc.demoapp_vpc.id
  map_public_ip_on_launch = true
  cidr_block = "10.0.4.0/24"
  availability_zone = "us-east-1b"
  tags = {
    Name = "demoapp-subnet-b-pub"
  }
}

resource "aws_eip" "nat_a" {
  vpc = true

  tags = {
    Name = "nata"
  }
}

resource "aws_eip" "nat_b" {
  vpc = true

  tags = {
    Name = "natb"
  }
}

resource "aws_nat_gateway" "nat_gw_a" {
  subnet_id = aws_subnet.demoapp_privat_subnet_a.id
  allocation_id = aws_eip.nat_a.allocation_id
}

resource "aws_nat_gateway" "nat_gw_b" {
  subnet_id = aws_subnet.demoapp_privat_subnet_b.id
  allocation_id = aws_eip.nat_b.allocation_id
}

resource "aws_route_table" "private_a" {
  vpc_id = aws_vpc.demoapp_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw_a.id
  }

  tags = {
    Name = "private"
  }
}

resource "aws_route_table" "private_b" {
  vpc_id = aws_vpc.demoapp_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw_b.id
  }

  tags = {
    Name = "private"
  }
}

# Create route table association betn prv sub1 & NAT GW1
resource "aws_route_table_association" "privat_a_to_nat_a" {
  count          = "1"
  route_table_id = aws_route_table.private_a.id
  subnet_id      = aws_subnet.demoapp_privat_subnet_a.id
}

resource "aws_route_table_association" "privat_b_to_nat_b" {
  count          = "1"
  route_table_id = aws_route_table.private_b.id
  subnet_id      = aws_subnet.demoapp_privat_subnet_b.id
}

#resource "aws_route_table" "public" {
#  vpc_id = aws_vpc.demoapp_vpc.id
#
#  route {
#    cidr_block = "0.0.0.0/0"
#    gateway_id = aws_internet_gateway.inet_gateway.id
#  }
#
#  tags = {
#    Name = "public"
#  }
#}

resource "aws_route_table_association" "public_us_east_1a" {
  count          = "1"
  subnet_id      = aws_subnet.demoapp_subnet_a_pub.id
  route_table_id = aws_vpc.demoapp_vpc.default_route_table_id
}

resource "aws_route_table_association" "public_us_east_1b" {
  count          = "1"
  subnet_id      = aws_subnet.demoapp_subnet_b_pub.id
  route_table_id = aws_vpc.demoapp_vpc.default_route_table_id
}

# Создаем группу безопасности
resource "aws_security_group" "demoapp_sg" {
  name_prefix = "demoapp-sg"
  vpc_id = aws_vpc.demoapp_vpc.id
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Создаем IAM роль
resource "aws_iam_role" "demoapp_role" {
  name_prefix = "demoapp-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Создаем лаунч конфиг, для настройки EC2 экземпляров
#data "template_file" "userdata" {
#  template = filebase64("${path.module}/userdata.sh.tpl")
#  vars = {
#    DOCKER_IMAGE = "bencuk/nodejs-demoapp:latest"
#    APP_PORT = 80
#  }
#}

resource "aws_launch_template" "demoapp_lc" {
  name_prefix = "demo-lc"
  image_id = "ami-00c39f71452c08778" # Указываем ID образа Amazon Linux 2
  instance_type = "t2.micro"
  user_data = filebase64("${path.module}/userdata.sh")
  vpc_security_group_ids = [aws_security_group.demoapp_sg.id]
}

# Создаем группу автоскейлинга
resource "aws_autoscaling_group" "demoapp-asg" {
#  source = "terraform-aws-modules/autoscaling/aws"

  vpc_zone_identifier = [aws_subnet.demoapp_privat_subnet_a.id, aws_subnet.demoapp_privat_subnet_b.id]

  launch_template {
    id      = aws_launch_template.demoapp_lc.id
    version = "$Latest"
  }
  target_group_arns = [aws_lb_target_group.demo_tg.arn]

  # Настраиваем автомасштабирование
  min_size = 2
  max_size = 3
  desired_capacity = 2
  health_check_grace_period = 300
  health_check_type = "EC2"
  force_delete = true

  # Настраиваем мониторинг
  metrics_granularity = "1Minute"
  enabled_metrics = []
}

# Создаем лоадбалансер и таргет группу
resource "aws_lb" "demo_lb" {
  name_prefix = "demolb"
  load_balancer_type = "application"
  subnets = [aws_subnet.demoapp_privat_subnet_a.id, aws_subnet.demoapp_privat_subnet_b.id]
  security_groups = [aws_security_group.demoapp_sg.id]
}

resource "aws_lb_target_group" "demo_tg" {
  name_prefix = "demotg"
  port = 80
  protocol = "HTTP"
  vpc_id = aws_vpc.demoapp_vpc.id

}

# Добавляем таргет группу в лоадбалансер
resource "aws_lb_listener" "demoapp_listener" {
  load_balancer_arn = aws_lb.demo_lb.arn
  port = 80
  protocol = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.demo_tg.arn
    type = "forward"
  }
}
