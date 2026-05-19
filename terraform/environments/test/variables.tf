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
  default     = "test"
}

variable "project" {
  description = "Project name"
  type        = string
  default     = "eks-platform"
}

variable "app_image_tag" {
  description = "Docker image tag for the TypeScript application"
  type        = string
  default     = "latest"
}

