output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability zones"
  value       = data.aws_availability_zones.available.names
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "backend_security_group_id" {
  value = aws_security_group.backend.id
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

output "ecs_cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.main.name
}

output "alb_url" {
  description = "Public URL of the application"
  value       = "http://${aws_lb.main.dns_name}"
}

output "rds_endpoint" {
  description = "RDS hostname, for building DATABASE_URL"
  value       = aws_db_instance.postgres.address
}

output "ecs_cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.main.arn
}