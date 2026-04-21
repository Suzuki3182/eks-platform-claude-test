output "lbc_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller"
  value       = aws_iam_role.lbc.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for Cluster Autoscaler"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "vpc_cni_role_arn" {
  description = "IAM role ARN for VPC CNI"
  value       = aws_iam_role.vpc_cni.arn
}

output "ebs_csi_role_arn" {
  description = "IAM role ARN for EBS CSI Driver"
  value       = aws_iam_role.ebs_csi.arn
}

output "node_role_arn" {
  description = "IAM role ARN for EKS worker nodes"
  value       = aws_iam_role.node.arn
}

output "node_role_name" {
  description = "IAM role name for EKS worker nodes"
  value       = aws_iam_role.node.name
}

output "cluster_role_arn" {
  description = "IAM role ARN for EKS cluster"
  value       = aws_iam_role.cluster.arn
}
