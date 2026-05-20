variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL (without https://)"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID for LBC permissions"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "create_cluster_and_node_roles" {
  description = "Whether to create EKS cluster and node IAM roles"
  type        = bool
  default     = true
}

variable "create_irsa_roles" {
  description = "Whether to create IRSA IAM roles and policies for addons"
  type        = bool
  default     = true
}
