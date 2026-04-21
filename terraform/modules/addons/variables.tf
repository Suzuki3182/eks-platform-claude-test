variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "cluster_version" {
  description = "EKS cluster Kubernetes version"
  type        = string
}

variable "vpc_cni_role_arn" {
  description = "IAM role ARN for VPC CNI addon"
  type        = string
}

variable "ebs_csi_role_arn" {
  description = "IAM role ARN for EBS CSI driver addon"
  type        = string
}

variable "lbc_role_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller"
  type        = string
}

variable "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for Cluster Autoscaler"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for AWS Load Balancer Controller"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
