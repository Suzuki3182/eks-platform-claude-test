output "datadog_namespace" {
  description = "Kubernetes namespace where Datadog is deployed"
  value       = kubernetes_namespace.datadog.metadata[0].name
}

output "cluster_agent_role_arn" {
  description = "IAM role ARN for Datadog Cluster Agent AWS API access"
  value       = aws_iam_role.datadog_cluster_agent.arn
}

output "helm_release_status" {
  description = "Datadog Helm release deployment status"
  value       = helm_release.datadog.status
}
