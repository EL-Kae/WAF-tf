terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
    fastly = {
      source  = "fastly/fastly"
      version = ">= 3.0.2"
    }
    sigsci = {
      source = "signalsciences/sigsci"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = "us-east-1"
}

# -----------------
# NETWORKING
# -----------------

resource "aws_vpc" "app_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
}

resource "aws_subnet" "app_public_subnet" {
  count             = 2
  cidr_block        = element(["10.0.0.0/24", "10.0.1.0/24"], count.index)
  vpc_id            = aws_vpc.app_vpc.id
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]
}

resource "aws_subnet" "app_private_subnet" {
  count             = 2
  cidr_block        = element(["10.0.2.0/24", "10.0.3.0/24"], count.index)
  availability_zone = data.aws_availability_zones.available_zones.names[count.index]
  vpc_id            = aws_vpc.app_vpc.id
}

resource "aws_internet_gateway" "app_igw" {
  vpc_id = aws_vpc.app_vpc.id
}

resource "aws_eip" "app_ips" {
  count      = 2
  depends_on = [aws_internet_gateway.app_igw]
}

resource "aws_nat_gateway" "app_nat" {
  count         = 2
  subnet_id     = element(aws_subnet.app_public_subnet.*.id, count.index)
  allocation_id = element(aws_eip.app_ips.*.id, count.index)
}

resource "aws_route_table" "app_private_route" {
  count  = 2
  vpc_id = aws_vpc.app_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = element(aws_nat_gateway.app_nat.*.id, count.index)
  }
}

resource "aws_route_table" "app_public_route" {
  vpc_id = aws_vpc.app_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.app_igw.id
  }
}

resource "aws_route_table_association" "app_private_table_association" {
  count          = 2
  subnet_id      = element(aws_subnet.app_private_subnet.*.id, count.index)
  route_table_id = element(aws_route_table.app_private_route.*.id, count.index)
}

resource "aws_route_table_association" "app_public_table_association" {
  count          = 2
  subnet_id      = element(aws_subnet.app_public_subnet.*.id, count.index)
  route_table_id = aws_route_table.app_public_route.id
}

# -----------------
# LOAD BALANCER
# -----------------

# Uncomment and use when https is not avaiable by CDN
/*resource "aws_security_group" "app_https_sg" {
  name        = "app-https-sg"
  description = "Security group for https traffic."
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow public web traffic to alb"
    from_port   = 443
    protocol    = "tcp"
    to_port     = 443
  }

  egress {
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow public web traffic to alb"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
  }
}*/

resource "aws_security_group" "app_http_sg" {
  name        = "app-http-sg"
  description = "Security group for http traffic."
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow public web traffic to alb"
    from_port   = 80
    protocol    = "tcp"
    to_port     = 80
  }

  egress {
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow public web traffic to alb"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb" "app_lb" {
  name                       = "app-lb"
  drop_invalid_header_fields = true
  subnets                    = aws_subnet.app_public_subnet.*.id
  security_groups            = [aws_security_group.app_http_sg.id] //, aws_security_group.app_https_sg.id]
  # enable_waf_fail_open = false
}

resource "aws_lb_target_group" "app_target_group" {
  name        = "app-target-group"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.app_vpc.id

  health_check {
    matcher = "200,302"
  }
}

resource "aws_lb_listener" "app_listener_http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = aws_lb_target_group.app_target_group.arn
    type             = "forward"
  }
}

resource "aws_cloudwatch_log_group" "app_logs" {
  name              = "aws-waf-logs-app"
  retention_in_days = 365
}

resource "aws_wafv2_web_acl_association" "alb-waf" {
  resource_arn = aws_lb.app_lb.arn
  web_acl_arn  = aws_wafv2_web_acl.app_waf.arn
}

resource "aws_wafv2_web_acl_logging_configuration" "waf-logs" {
  log_destination_configs = [aws_cloudwatch_log_group.app_logs.arn]
  resource_arn            = aws_wafv2_web_acl.app_waf.arn
}

/*data "aws_acm_certificate" "app_cert" {
  domain      = "example.com"
  types       = ["AMAZON_ISSUED"]
  most_recent = true
}

resource "aws_lb_listener" "app_listener_https" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = data.aws_acm_certificate.app_cert.arn

  default_action {
    target_group_arn = aws_lb_target_group.app_target_group.arn
    type             = "forward"
  }
}

resource "aws_lb_listener" "app_listener_http" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}*/

# -----------------
# ECS
# -----------------

resource "aws_security_group" "app_ecs_sg" {
  name        = "app-ecs-security-group"
  description = "Security group for ecs service."
  vpc_id      = aws_vpc.app_vpc.id

  ingress {
    description     = "Allow public web traffic to app"
    from_port       = 9090
    protocol        = "tcp"
    to_port         = 9090
    security_groups = [aws_security_group.app_http_sg.id] //, aws_security_group.app_https_sg.id]
  }

  egress {
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow public web traffic to app"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_ecs_task_definition" "app" {
  family                   = "app_app"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 2048
  memory                   = 4096
  container_definitions = jsonencode([
    {
      name         = "app"
      image        = "some/image"
      cpu          = 2048
      memory       = 4096
      network_mode = "awsvpc"
      portMappings = [
        {
          containerPort = 9090
          hostPort      = 9090
        }
      ]
    }
  ])
}

resource "aws_ecs_cluster" "app_cluster" {
  name = "app_cluster"
}

resource "aws_ecs_service" "app" {
  name            = "app"
  cluster         = aws_ecs_cluster.app_cluster.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.app_ecs_sg.id]
    subnets         = aws_subnet.app_private_subnet.*.id
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app_target_group.arn
    container_name   = "app"
    container_port   = 9090
  }

  depends_on = [aws_lb_listener.app_listener_http] //, aws_lb_listener.app_listener_https]
}

# -----------------
# FASTLY
# -----------------

provider "fastly" {
  api_key = jsondecode(data.aws_secretsmanager_secret_version.fastly_api_key.secret_string)["api_key"]
}

resource "fastly_service_vcl" "app" {
  name = "app"

  domain {
    name = "example.com"
  }

  backend {
    address           = aws_lb.app_lb.dns_name
    name              = "app"
    port              = 80
    ssl_cert_hostname = "app.example.com"
  }

  force_destroy = true
}

# -----------------
# Signal Sciences
# -----------------

provider "sigsci" {
  corp = "vmg"
  # email      = "" // Required. may also provide via env variable SIGSCI_EMAIL
  # auth_token = "" //may also provide via env variable SIGSCI_TOKEN, this or password is required
  # password   = "" //may also provide via env variable SIGSCI_PASSWORD
  fastly_key = jsondecode(data.aws_secretsmanager_secret_version.fastly_api_key.secret_string)["api_key"]
}

resource "sigsci_site" "app" {
  short_name             = "app"
  display_name           = "app"
  block_duration_seconds = 1000
  agent_anon_mode        = ""
  agent_level            = "log"
}

resource "sigsci_edge_deployment" "app_deployment" {
  site_short_name = sigsci_site.app.short_name
}

resource "sigsci_edge_deployment_service" "app-edge-service" {
  site_short_name  = sigsci_site.app.short_name
  fastly_sid       = fastly_service_vcl.app.id
  activate_version = true
  percent_enabled  = 100

  depends_on = [
    sigsci_edge_deployment.app_deployment
  ]
}

# -----------------
# OUTPUT
# -----------------

output "load_balancer_ip" {
  description = "Outputs dns name of load balancer."
  value       = aws_lb.app_lb.dns_name
}
