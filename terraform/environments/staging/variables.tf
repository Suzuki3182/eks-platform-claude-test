variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "staging"
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "eks-platform"
}

variable "github_repo" {
  description = "GitHub repository in 'org/repo' format"
  type        = string
  default     = "Suzuki3182/eks-platform-claude-test"
}

variable "app_image_tag" {
  description = "Docker image tag for the TypeScript application"
  type        = string
  default     = "latest"
}
