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

variable "datadog_api_key" {
  description = "Datadog API key (passed via CI/CD secret DD_API_KEY)"
  type        = string
  sensitive   = true
}

variable "datadog_app_key" {
  description = "Datadog application key (passed via CI/CD secret DD_APP_KEY)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "datadog_site" {
  description = "Datadog intake site"
  type        = string
  default     = "datadoghq.com"
}

