output "lbc_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller"
  value       = try(aws_iam_role.lbc[0].arn, null)
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for Cluster Autoscaler"
  value       = try(aws_iam_role.cluster_autoscaler[0].arn, null)
}

output "vpc_cni_role_arn" {
  description = "IAM role ARN for VPC CNI"
  value       = try(aws_iam_role.vpc_cni[0].arn, null)
}

output "ebs_csi_role_arn" {
  description = "IAM role ARN for EBS CSI Driver"
  value       = try(aws_iam_role.ebs_csi[0].arn, null)
}

output "node_role_arn" {
  description = "IAM role ARN for EKS worker nodes"
  value       = try(aws_iam_role.node[0].arn, null)
}

output "node_role_name" {
  description = "IAM role name for EKS worker nodes"
  value       = try(aws_iam_role.node[0].name, null)
}

output "cluster_role_arn" {
  description = "IAM role ARN for EKS cluster"
  value       = try(aws_iam_role.cluster[0].arn, null)
}
