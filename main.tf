provider "aws" {
  region = "ap-northeast-2" # 원하는 리전으로 설정
}

# VPC 생성
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  enable_dns_support   = true  # DNS 해석 활성화
  enable_dns_hostnames = true  # DNS 호스트명 활성화
}

# Public 서브넷 생성 (API Gateway와 인터넷 게이트웨이 연결)
resource "aws_subnet" "public_subnet" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-northeast-2a"
}

# Private 서브넷 생성 (NLB, EC2 인스턴스 배치)
resource "aws_subnet" "private_subnet_1" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-northeast-2a"
}

resource "aws_subnet" "private_subnet_2" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.3.0/24"
  availability_zone = "ap-northeast-2c"
}

# 인터넷 게이트웨이 생성
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

# NAT 게이트웨이 생성 (Private 서브넷에서 인터넷 접근)
resource "aws_eip" "nat_eip" {
  vpc = true
}

resource "aws_nat_gateway" "nat_gw" {
  allocation_id = aws_eip.nat_eip.id
  subnet_id     = aws_subnet.public_subnet.id
}

# 퍼블릭 라우팅 테이블 생성 및 연결 (Public Subnet)
resource "aws_route_table" "public_route_table" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_route_table.id
}

# Private 라우팅 테이블 생성 및 연결 (Private Subnet)
resource "aws_route_table" "private_route_table" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gw.id
  }
}

resource "aws_route_table_association" "private_assoc_1" {
  subnet_id      = aws_subnet.private_subnet_1.id
  route_table_id = aws_route_table.private_route_table.id
}

resource "aws_route_table_association" "private_assoc_2" {
  subnet_id      = aws_subnet.private_subnet_2.id
  route_table_id = aws_route_table.private_route_table.id
}

# 보안 그룹 생성 (NLB와 EC2용)
resource "aws_security_group" "nlb_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "nlb-sg"
  }
}

resource "aws_security_group" "ec2_sg" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"] # VPC 내 통신만 허용
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ec2-sg"
  }
}

# IAM 역할 생성 (SSM 정책 연결)
resource "aws_iam_role" "ec2_ssm_role" {
  name = "ec2-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action    = "sts:AssumeRole"
        Effect    = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })
}

# AmazonSSMManagedInstanceCore 정책 연결 (SSM을 사용하기 위한 기본 정책)
resource "aws_iam_role_policy_attachment" "ssm_policy_attach" {
  role       = aws_iam_role.ec2_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# IAM 인스턴스 프로파일 생성 (EC2에 연결)
resource "aws_iam_instance_profile" "ec2_ssm_profile" {
  name = "ec2-ssm-instance-profile"
  role = aws_iam_role.ec2_ssm_role.name
}

# EC2 인스턴스 생성 및 SSM IAM 역할 연결
resource "aws_instance" "test" {
  ami           = "ami-0023481579962abd4" # Amazon Linux 2 AMI
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.public_subnet.id
  security_groups = [aws_security_group.ec2_sg.id]

  associate_public_ip_address = true
  iam_instance_profile = aws_iam_instance_profile.ec2_ssm_profile.name
  tags = {
    Name = "test-server"
  }
}

# EC2 인스턴스 생성 및 SSM IAM 역할 연결
resource "aws_instance" "nginx" {
  ami           = "ami-0023481579962abd4" # Amazon Linux 2 AMI
  instance_type = "t2.micro"
  subnet_id     = aws_subnet.private_subnet_1.id
  security_groups = [aws_security_group.ec2_sg.id]

  iam_instance_profile = aws_iam_instance_profile.ec2_ssm_profile.name

  user_data = <<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo yum install -y nginx
    sudo systemctl start nginx
    sudo systemctl enable nginx
    sudo mkdir -p /usr/share/nginx/html
    echo "<h1>Hello from Nginx on EC2 in Private Subnet</h1>" | sudo tee /usr/share/nginx/html/index.html
    sudo systemctl restart nginx
  EOF

  tags = {
    Name = "nginx-server"
  }
}

# NLB 생성 (Private Subnet 2개에 배치)
resource "aws_lb" "nlb" {
  name               = "api-nlb"
  internal           = true  # Internal NLB 설정
  load_balancer_type = "network"
  subnets            = [aws_subnet.private_subnet_1.id, aws_subnet.private_subnet_2.id]
  security_groups    = [aws_security_group.nlb_sg.id]
}

# NLB 타겟 그룹 생성 (TCP 프로토콜 사용)
resource "aws_lb_target_group" "tg" {
  name     = "api-tg"
  port     = 80
  protocol = "TCP"  # NLB는 TCP로 통신
  vpc_id   = aws_vpc.main.id

  health_check {
    port = "80"
  }
}

# NLB 리스너 생성 (TCP 리스너)
resource "aws_lb_listener" "tls_listener" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 443
  protocol          = "TLS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = aws_acm_certificate.main.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

# 타겟 그룹에 EC2 인스턴스 등록
resource "aws_lb_target_group_attachment" "tg_attachment" {
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.nginx.id
  port             = 80
}

# VPC Link 생성 (API Gateway가 Internal NLB에 접근할 수 있도록)
resource "aws_api_gateway_vpc_link" "vpc_link" {
  name = "api-gateway-vpc-link"
  target_arns = [aws_lb.nlb.arn]  # Internal NLB의 ARN
}

# API Gateway 생성 (REST API)
resource "aws_api_gateway_rest_api" "rest_api" {
  name        = "api-gw"
  description = "Public REST API Gateway"
}

# API Gateway 리소스 추가 (/example)
resource "aws_api_gateway_resource" "api_resource" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  parent_id   = aws_api_gateway_rest_api.rest_api.root_resource_id
  path_part   = "example"
}

# GET 메서드 추가
resource "aws_api_gateway_method" "get_method" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  resource_id   = aws_api_gateway_resource.api_resource.id
  http_method   = "GET"
  authorization = "NONE"
}

# API Gateway와 NLB 통합 (VPC Link 사용)
resource "aws_api_gateway_integration" "api_integration" {
  rest_api_id             = aws_api_gateway_rest_api.rest_api.id
  resource_id             = aws_api_gateway_resource.api_resource.id
  http_method             = aws_api_gateway_method.get_method.http_method
  integration_http_method = "GET"
  type                    = "HTTP_PROXY"
  uri                     = "http://${aws_lb.nlb.dns_name}"  # NLB의 내부 DNS 이름 사용
  connection_type         = "VPC_LINK"  # VPC Link 사용
  connection_id           = aws_api_gateway_vpc_link.vpc_link.id  # VPC Link ID 설정
}

# API 배포
resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.rest_api.id
  depends_on  = [aws_api_gateway_integration.api_integration]
}

# 배포 스테이지 생성
resource "aws_api_gateway_stage" "api_stage" {
  rest_api_id   = aws_api_gateway_rest_api.rest_api.id
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  stage_name    = "dev"
}

# ACM 인증서 생성
resource "aws_acm_certificate" "main" {
  domain_name       = "test.fnfdns.com" # 공인 도메인 입력
  validation_method = "DNS"

  tags = {
    Name = "api-cert"
  }
}


# Route 53 Private Hosted Zone 생성
resource "aws_route53_zone" "private_zone" {
  name = "fnfdns.com"
  vpc {
    vpc_id = aws_vpc.main.id
  }
}

# Route 53 A 레코드 생성 (test.fnfdns.com을 NLB로 가리킴)
resource "aws_route53_record" "test_subdomain" {
  zone_id = aws_route53_zone.private_zone.zone_id  # Private Hosted Zone의 ID
  name    = "test.fnfdns.com"                      # 서브도메인 레코드 이름
  type    = "A"

  alias {
    name                   = aws_lb.nlb.dns_name  # NLB의 DNS 이름
    zone_id                = aws_lb.nlb.zone_id   # NLB의 호스트존 ID
    evaluate_target_health = false  # NLB 헬스체크를 필요에 따라 평가 (default: false)
  }
}