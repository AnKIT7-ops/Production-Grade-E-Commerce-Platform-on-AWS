variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "ap-south-1"
}

variable "project_name" {
  description = "Project name"
  type        = string
  default     = "ecommerce-platform"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

variable "backend_image_tag" {
  description = "ecommerce-backend image tag to deploy"
  type        = string
  default     = "v1.0.0"
}

variable "frontend_image_tag" {
  description = "ecommerce-frontend image tag to deploy"
  type        = string
  default     = "v1.0.1"
}

variable "db_password" {
  description = "RDS PostgreSQL master password"
  type        = string
  sensitive   = true
}