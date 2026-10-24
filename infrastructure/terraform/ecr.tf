resource "aws_ecr_repository" "backend" {
  name                 = "ecommerce-backend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "ecommerce-backend"
    Project     = var.project_name
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "ecommerce-frontend"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name        = "ecommerce-frontend"
    Project     = var.project_name
    Environment = "production"
    ManagedBy   = "Terraform"
  }
}