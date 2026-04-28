variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "environment" {
  description = "Environment name (test, staging, prod)"
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

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  type        = string
}

variable "oidc_issuer_url" {
  description = "OIDC issuer URL"
  type        = string
}

variable "datadog_api_key" {
  description = "Datadog API key"
  type        = string
  sensitive   = true
}

variable "datadog_app_key" {
  description = "Datadog application key (used for dashboards and monitors)"
  type        = string
  sensitive   = true
  default     = ""
}

variable "datadog_site" {
  description = "Datadog intake site (datadoghq.com, datadoghq.eu, us3.datadoghq.com, us5.datadoghq.com)"
  type        = string
  default     = "datadoghq.com"
}

variable "namespace" {
  description = "Kubernetes namespace for Datadog"
  type        = string
  default     = "datadog"
}

variable "helm_chart_version" {
  description = "Datadog Helm chart version"
  type        = string
  default     = "3.69.0"
}

variable "enable_apm" {
  description = "Enable APM distributed tracing"
  type        = bool
  default     = true
}

variable "enable_logs" {
  description = "Enable container log collection"
  type        = bool
  default     = true
}

variable "enable_npm" {
  description = "Enable Network Performance Monitoring (requires kernel eBPF support)"
  type        = bool
  default     = false
}

variable "enable_process_monitoring" {
  description = "Enable live process and container monitoring"
  type        = bool
  default     = true
}

variable "cluster_agent_replicas" {
  description = "Number of Datadog Cluster Agent replicas (use 2+ for HA)"
  type        = number
  default     = 1
}

variable "tags" {
  description = "Tags to apply to all AWS resources"
  type        = map(string)
  default     = {}
}
