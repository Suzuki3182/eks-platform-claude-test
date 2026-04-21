terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.12"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }
  }
}

locals {
  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "addons"
  })

  addon_resolve_conflicts = "OVERWRITE"
}

# ──────────────────────────────────────────────
# EKS Managed Addons
# ──────────────────────────────────────────────
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = var.cluster_name
  addon_name                  = "vpc-cni"
  resolve_conflicts_on_create = local.addon_resolve_conflicts
  resolve_conflicts_on_update = local.addon_resolve_conflicts
  service_account_role_arn    = var.vpc_cni_role_arn
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })
  tags = local.common_tags
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = var.cluster_name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = local.addon_resolve_conflicts
  resolve_conflicts_on_update = local.addon_resolve_conflicts
  tags                        = local.common_tags

  depends_on = [aws_eks_addon.vpc_cni]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = var.cluster_name
  addon_name                  = "kube-proxy"
  resolve_conflicts_on_create = local.addon_resolve_conflicts
  resolve_conflicts_on_update = local.addon_resolve_conflicts
  tags                        = local.common_tags
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name                = var.cluster_name
  addon_name                  = "aws-ebs-csi-driver"
  resolve_conflicts_on_create = local.addon_resolve_conflicts
  resolve_conflicts_on_update = local.addon_resolve_conflicts
  service_account_role_arn    = var.ebs_csi_role_arn
  tags                        = local.common_tags
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name                = var.cluster_name
  addon_name                  = "eks-pod-identity-agent"
  resolve_conflicts_on_create = local.addon_resolve_conflicts
  resolve_conflicts_on_update = local.addon_resolve_conflicts
  tags                        = local.common_tags
}

# ──────────────────────────────────────────────
# AWS Load Balancer Controller
# ──────────────────────────────────────────────
resource "helm_release" "aws_lbc" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  namespace  = "kube-system"
  version    = "1.7.2"

  set {
    name  = "clusterName"
    value = var.cluster_name
  }

  set {
    name  = "serviceAccount.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.lbc_role_arn
  }

  set {
    name  = "region"
    value = var.aws_region
  }

  set {
    name  = "vpcId"
    value = var.vpc_id
  }

  set {
    name  = "replicaCount"
    value = "2"
  }

  set {
    name  = "podDisruptionBudget.maxUnavailable"
    value = "1"
  }

  set {
    name  = "resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "resources.requests.memory"
    value = "128Mi"
  }

  set {
    name  = "resources.limits.cpu"
    value = "200m"
  }

  set {
    name  = "resources.limits.memory"
    value = "256Mi"
  }

  depends_on = [aws_eks_addon.vpc_cni, aws_eks_addon.coredns]
}

# ──────────────────────────────────────────────
# Cluster Autoscaler
# ──────────────────────────────────────────────
resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  namespace  = "kube-system"
  version    = "9.35.0"

  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }

  set {
    name  = "awsRegion"
    value = var.aws_region
  }

  set {
    name  = "rbac.serviceAccount.create"
    value = "true"
  }

  set {
    name  = "rbac.serviceAccount.name"
    value = "cluster-autoscaler"
  }

  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = var.cluster_autoscaler_role_arn
  }

  set {
    name  = "extraArgs.balance-similar-node-groups"
    value = "true"
  }

  set {
    name  = "extraArgs.skip-nodes-with-system-pods"
    value = "false"
  }

  set {
    name  = "extraArgs.expander"
    value = "least-waste"
  }

  set {
    name  = "resources.requests.cpu"
    value = "100m"
  }

  set {
    name  = "resources.requests.memory"
    value = "128Mi"
  }

  depends_on = [aws_eks_addon.vpc_cni, aws_eks_addon.coredns]
}

# ──────────────────────────────────────────────
# Metrics Server
# ──────────────────────────────────────────────
resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  namespace  = "kube-system"
  version    = "3.12.0"

  set {
    name  = "replicas"
    value = "2"
  }

  set {
    name  = "podDisruptionBudget.enabled"
    value = "true"
  }

  set {
    name  = "podDisruptionBudget.minAvailable"
    value = "1"
  }

  depends_on = [aws_eks_addon.coredns]
}

# ──────────────────────────────────────────────
# Network Policy (Kubernetes native)
# ──────────────────────────────────────────────
resource "kubernetes_network_policy" "deny_all_ingress" {
  metadata {
    name      = "default-deny-ingress"
    namespace = "default"
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]
  }
}

resource "kubernetes_network_policy" "allow_same_namespace" {
  metadata {
    name      = "allow-same-namespace"
    namespace = "default"
  }

  spec {
    pod_selector {}

    ingress {
      from {
        pod_selector {}
      }
    }

    policy_types = ["Ingress"]
  }
}
