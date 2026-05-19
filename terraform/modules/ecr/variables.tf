variable "name" {
  description = "ECR repository name"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for ECR encryption at rest"
  type        = string
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
