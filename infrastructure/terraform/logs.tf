resource "aws_cloudwatch_log_group" "backend" {
  name              = "/ecs/${var.project_name}/backend"
  retention_in_days = 7

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}

resource "aws_cloudwatch_log_group" "frontend" {
  name              = "/ecs/${var.project_name}/frontend"
  retention_in_days = 7

  tags = {
    Project   = var.project_name
    ManagedBy = "Terraform"
  }
}