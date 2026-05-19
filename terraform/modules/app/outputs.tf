output "namespace" {
  description = "Kubernetes namespace for the application"
  value       = kubernetes_namespace.app.metadata[0].name
}

output "deployment_name" {
  description = "Kubernetes deployment name"
  value       = kubernetes_deployment_v1.app.metadata[0].name
}

output "service_name" {
  description = "Kubernetes service name"
  value       = kubernetes_service_v1.app.metadata[0].name
}

output "ingress_hostname" {
  description = "ALB hostname assigned to the ingress (available after ingress is provisioned)"
  value       = var.create_ingress ? try(kubernetes_ingress_v1.app[0].status[0].load_balancer[0].ingress[0].hostname, "") : ""
}
