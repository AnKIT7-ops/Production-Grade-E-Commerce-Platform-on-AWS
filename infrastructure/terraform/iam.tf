resource "aws_iam_role" "ecs_task_execution" {
  name = "${var.project_name}-ecs-task-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name      = "${var.project_name}-ecs-task-execution-role"
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

data "aws_caller_identity" "current" {}

# The parameters themselves are created with the AWS CLI, outside Terraform,
# so their values never enter source or state. Terraform only knows the names.
locals {
  ssm_prefix           = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/${var.project_name}/backend"
  ssm_database_url_arn = "${local.ssm_prefix}/DATABASE_URL"
  ssm_secret_key_arn   = "${local.ssm_prefix}/SECRET_KEY"
}

# Lets ECS read exactly these two parameters when starting the backend task.
# No kms:Decrypt needed: SecureStrings use the AWS-managed aws/ssm key.
resource "aws_iam_role_policy" "ecs_task_execution_ssm" {
  name = "${var.project_name}-read-backend-secrets"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "ssm:GetParameters"
        Resource = [local.ssm_database_url_arn, local.ssm_secret_key_arn]
      }
    ]
  })
}