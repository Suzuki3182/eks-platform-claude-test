output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS cluster API server endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions (set as AWS_ROLE_TEST secret)"
  value       = module.github_oidc.github_actions_role_arn
}

output "oidc_issuer_url" {
  description = "OIDC issuer URL"
  value       = module.eks.oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN"
  value       = module.eks.oidc_provider_arn
}

output "node_security_group_id" {
  description = "Node security group ID"
  value       = module.eks.node_security_group_id
}

output "cluster_security_group_id" {
  description = "Cluster security group ID"
  value       = module.eks.cluster_security_group_id
}

output "lbc_role_arn" {
  description = "AWS Load Balancer Controller IAM role ARN"
  value       = module.iam.lbc_role_arn
}

output "cluster_autoscaler_role_arn" {
  description = "Cluster Autoscaler IAM role ARN"
  value       = module.iam.cluster_autoscaler_role_arn
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = module.vpc.private_subnet_ids
}

output "kms_key_arn" {
  description = "KMS key ARN"
  value       = aws_kms_key.eks.arn
  sensitive   = true
}

output "kubeconfig_command" {
  description = "Command to update kubeconfig"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "ecr_repository_url" {
  description = "ECR repository URL for the TypeScript app"
  value       = module.ecr.repository_url
}

output "app_namespace" {
  description = "Kubernetes namespace for the TypeScript app"
  value       = module.app.namespace
}

output "app_ingress_hostname" {
  description = "ALB hostname for the TypeScript app"
  value       = module.app.ingress_hostname
}
