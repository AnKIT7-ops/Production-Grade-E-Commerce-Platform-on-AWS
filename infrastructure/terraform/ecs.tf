resource "aws_ecs_cluster" "main" {
  name = "${var.project_name}-cluster"

  tags = {
    Name      = "${var.project_name}-cluster"
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

# --- Task definitions -------------------------------------------------------

resource "aws_ecs_task_definition" "backend" {
  family                   = "${var.project_name}-backend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "backend"
      image        = "${aws_ecr_repository.backend.repository_url}:${var.backend_image_tag}"
      essential    = true
      portMappings = [{ containerPort = 8000, protocol = "tcp" }]

      environment = [
        { name = "ENVIRONMENT", value = "production" }
      ]

      # Only the ARNs live here; ECS fetches the values at task start, so they
      # never appear in Terraform source, state, or the task definition.
      secrets = [
        { name = "DATABASE_URL", valueFrom = local.ssm_database_url_arn },
        { name = "SECRET_KEY", valueFrom = local.ssm_secret_key_arn }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.backend.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "backend"
        }
      }
    }
  ])

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_ecs_task_definition" "frontend" {
  family                   = "${var.project_name}-frontend"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  container_definitions = jsonencode([
    {
      name         = "frontend"
      image        = "${aws_ecr_repository.frontend.repository_url}:${var.frontend_image_tag}"
      essential    = true
      portMappings = [{ containerPort = 80, protocol = "tcp" }]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.frontend.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "frontend"
        }
      }
    }
  ])

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

# --- Services ---------------------------------------------------------------
# Tasks run in the public subnets with a public IP so they can reach ECR and
# CloudWatch without a NAT gateway. Their security groups admit traffic only
# from the ALB, so the public IP is outbound-only in practice.

resource "aws_ecs_service" "backend" {
  name            = "${var.project_name}-backend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.backend.arn
  launch_type     = "FARGATE"

  # ponytail: one task, because every container start runs `alembic upgrade
  # head`; scale out only after moving migrations to a one-off task.
  desired_count = 1

  # Migrations run before uvicorn starts; don't let the ALB kill the task
  # while they are still running.
  health_check_grace_period_seconds = 120

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.backend.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.backend.arn
    container_name   = "backend"
    container_port   = 8000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener_rule.backend]

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_ecs_service" "frontend" {
  name            = "${var.project_name}-frontend"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.frontend.arn
  launch_type     = "FARGATE"
  desired_count   = 1

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.frontend.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.frontend.arn
    container_name   = "frontend"
    container_port   = 80
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_lb_listener.http]

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}
