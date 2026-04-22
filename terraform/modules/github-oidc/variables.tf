variable "github_repo" {
  description = "GitHub repository in 'org/repo' format (e.g. 'Suzuki3182/eks-platform-claude-test')"
  type        = string
}

variable "environment" {
  description = "Environment name (test, staging, prod)"
  type        = string
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "role_name_prefix" {
  description = "Prefix for the IAM role name"
  type        = string
  default     = "eks-platform"
}

variable "create_oidc_provider" {
  description = "Whether to create the GitHub Actions OIDC provider. Set to false if it already exists in the account (only one provider per account is needed)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
