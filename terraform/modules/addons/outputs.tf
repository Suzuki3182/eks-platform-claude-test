output "vpc_cni_addon_id" {
  description = "VPC CNI addon ID"
  value       = aws_eks_addon.vpc_cni.id
}

output "coredns_addon_id" {
  description = "CoreDNS addon ID"
  value       = aws_eks_addon.coredns.id
}

output "kube_proxy_addon_id" {
  description = "kube-proxy addon ID"
  value       = aws_eks_addon.kube_proxy.id
}

output "ebs_csi_addon_id" {
  description = "EBS CSI driver addon ID"
  value       = aws_eks_addon.ebs_csi.id
}

output "lbc_helm_status" {
  description = "AWS Load Balancer Controller Helm release status"
  value       = helm_release.aws_lbc.status
}

output "cluster_autoscaler_helm_status" {
  description = "Cluster Autoscaler Helm release status"
  value       = helm_release.cluster_autoscaler.status
}

output "metrics_server_helm_status" {
  description = "Metrics Server Helm release status"
  value       = helm_release.metrics_server.status
}
