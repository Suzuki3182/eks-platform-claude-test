variable "app_name" {
  description = "Application name used for all Kubernetes resource names"
  type        = string
  default     = "typescript-app"
}

variable "namespace" {
  description = "Kubernetes namespace for the application"
  type        = string
  default     = "app"
}

variable "environment" {
  description = "Environment name (test, staging, prod)"
  type        = string
}

variable "image_repository" {
  description = "ECR repository URL without tag"
  type        = string
}

variable "image_tag" {
  description = "Docker image tag to deploy"
  type        = string
  default     = "latest"
}

variable "container_port" {
  description = "Port the container listens on"
  type        = number
  default     = 3000
}

variable "replicas" {
  description = "Desired number of pod replicas"
  type        = number
  default     = 2
}

variable "min_replicas" {
  description = "Minimum replicas for HPA"
  type        = number
  default     = 1
}

variable "max_replicas" {
  description = "Maximum replicas for HPA"
  type        = number
  default     = 10
}

variable "cpu_request" {
  description = "CPU resource request"
  type        = string
  default     = "100m"
}

variable "cpu_limit" {
  description = "CPU resource limit"
  type        = string
  default     = "500m"
}

variable "memory_request" {
  description = "Memory resource request"
  type        = string
  default     = "128Mi"
}

variable "memory_limit" {
  description = "Memory resource limit"
  type        = string
  default     = "512Mi"
}

variable "create_ingress" {
  description = "Whether to create an ALB Ingress resource"
  type        = bool
  default     = true
}

variable "ingress_scheme" {
  description = "ALB scheme: internet-facing or internal"
  type        = string
  default     = "internet-facing"
}
