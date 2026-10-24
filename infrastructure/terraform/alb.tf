resource "aws_lb" "main" {
  name               = "${var.project_name}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = aws_subnet.public[*].id
  security_groups    = [aws_security_group.alb.id]

  drop_invalid_header_fields = true

  tags = {
    Name      = "${var.project_name}-alb"
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

# target_type "ip" is required for Fargate: each task gets its own network
# interface, so the ALB registers task IPs rather than EC2 instances.
resource "aws_lb_target_group" "frontend" {
  name                 = "${var.project_name}-frontend-tg"
  port                 = 80
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_lb_target_group" "backend" {
  name                 = "${var.project_name}-backend-tg"
  port                 = 8000
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = aws_vpc.main.id
  deregistration_delay = 30

  # /health also checks the database, so a task that can't reach RDS is
  # taken out of rotation.
  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

# Everything goes to the frontend unless a rule below matches.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend.arn
  }
}

resource "aws_lb_listener_rule" "backend" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }

  condition {
    path_pattern {
      values = ["/api/*", "/health"]
    }
  }
}
