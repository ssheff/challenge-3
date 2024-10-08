output "alb_dns_name" {
  description = "The DNS name of the load balancer"
  value       = aws_lb.main.dns_name
}

output "rds_endpoint" {
  value = aws_db_instance.my_rds_instance.endpoint
  description = "RDS endpoint to connect to the database."
}
