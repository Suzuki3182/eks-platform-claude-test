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
  oidc_issuer = replace(var.oidc_issuer_url, "https://", "")
  common_tags = merge(var.tags, {
    ManagedBy = "terraform"
    Module    = "datadog"
  })

  datadog_tags = [
    "env:${var.environment}",
    "cluster:${var.cluster_name}",
    "region:${var.aws_region}",
    "managed-by:terraform",
  ]
}

# ──────────────────────────────────────────────
# Kubernetes Namespace
# ──────────────────────────────────────────────
resource "kubernetes_namespace" "datadog" {
  metadata {
    name = var.namespace
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
      "app.kubernetes.io/name"       = "datadog"
    }
  }
}

# ──────────────────────────────────────────────
# API Key Secret
# Keys must match what the Datadog Helm chart expects:
#   apiKeyExistingSecret → key "api-key"
#   appKeyExistingSecret → key "app-key"
# ──────────────────────────────────────────────
resource "kubernetes_secret" "datadog" {
  metadata {
    name      = "datadog-secret"
    namespace = kubernetes_namespace.datadog.metadata[0].name
  }

  data = {
    api-key = var.datadog_api_key
    app-key = var.datadog_app_key
  }

  type = "Opaque"
}

# ──────────────────────────────────────────────
# IRSA — Datadog Cluster Agent (read-only AWS API access)
# ──────────────────────────────────────────────
resource "aws_iam_role" "datadog_cluster_agent" {
  name = "${var.cluster_name}-datadog-cluster-agent"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = var.oidc_provider_arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:${var.namespace}:datadog-cluster-agent"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_policy" "datadog_cluster_agent" {
  #tfsec:ignore:aws-iam-no-policy-wildcards:exp:2027-04-21
  # Datadog requires read-only AWS APIs for host/cluster metadata and CloudWatch metrics; no write permissions.
  name        = "${var.cluster_name}-datadog-cluster-agent-policy"
  description = "Read-only policy for Datadog Cluster Agent: EC2/EKS metadata and CloudWatch metrics"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DatadogEC2Read"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeTags",
          "ec2:DescribeVolumes",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
        ]
        Resource = "*"
      },
      {
        Sid    = "DatadogEKSRead"
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters",
          "eks:ListNodegroups",
          "eks:DescribeNodegroup",
        ]
        Resource = "*"
      },
      {
        Sid    = "DatadogCloudWatchRead"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
        ]
        Resource = "*"
      },
      {
        Sid    = "DatadogAutoScalingRead"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribePolicies",
          "autoscaling:DescribeTags",
        ]
        Resource = "*"
      },
      {
        Sid    = "DatadogTaggingRead"
        Effect = "Allow"
        Action = [
          "tag:GetResources",
          "tag:GetTagKeys",
          "tag:GetTagValues",
        ]
        Resource = "*"
      },
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "datadog_cluster_agent" {
  role       = aws_iam_role.datadog_cluster_agent.name
  policy_arn = aws_iam_policy.datadog_cluster_agent.arn
}

# ──────────────────────────────────────────────
# Datadog Agent Helm Release
# ──────────────────────────────────────────────
resource "helm_release" "datadog" {
  name       = "datadog"
  repository = "https://helm.datadoghq.com"
  chart      = "datadog"
  namespace  = kubernetes_namespace.datadog.metadata[0].name
  version    = var.helm_chart_version

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      datadog = {
        # Credentials from pre-created Kubernetes secret
        apiKeyExistingSecret = kubernetes_secret.datadog.metadata[0].name
        appKeyExistingSecret = kubernetes_secret.datadog.metadata[0].name
        site                 = var.datadog_site
        clusterName          = var.cluster_name
        tags                 = local.datadog_tags

        # EKS kubelet uses a self-signed certificate — skip TLS verification
        kubelet = {
          tlsVerify = false
        }

        # EKS nodes use containerd as the container runtime
        criSocketPath = "/var/run/containerd/containerd.sock"

        # Container log collection
        logs = {
          enabled                    = var.enable_logs
          containerCollectAll        = var.enable_logs
          containerCollectUsingFiles = true
        }

        # APM: distributed tracing via TCP port 8126 and Unix socket
        apm = {
          portEnabled   = var.enable_apm
          socketEnabled = var.enable_apm
        }

        # Live process and container monitoring
        processAgent = {
          enabled           = var.enable_process_monitoring
          processCollection = var.enable_process_monitoring
        }

        # Network Performance Monitoring (requires eBPF — disabled by default)
        networkMonitoring = {
          enabled = var.enable_npm
        }

        # Kubernetes event collection and leader election for dedup
        collectEvents  = true
        leaderElection = true

        # Use Cluster Agent's KSM Core check instead of a separate kube-state-metrics pod
        kubeStateMetricsEnabled = false
        kubeStateMetricsCore = {
          enabled = true
        }

        # Live containers / pod topology in Datadog UI
        orchestratorExplorer = {
          enabled = true
        }

        # Container image metadata for Software Catalog and vulnerability tracking
        containerImageCollection = {
          enabled = true
        }

        # SBOM collection for container image vulnerability scanning
        sbom = {
          containerImage = {
            enabled = true
          }
        }
      }

      clusterAgent = {
        enabled                   = true
        replicas                  = var.cluster_agent_replicas
        createPodDisruptionBudget = true

        # Enables Kubernetes HPA scaled on Datadog custom metrics
        metricsProvider = {
          enabled = true
        }

        # Auto-injects APM / log correlation env vars into new pods
        admissionController = {
          enabled = true
        }

        # IRSA annotation so the Cluster Agent can call AWS APIs
        serviceAccount = {
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.datadog_cluster_agent.arn
          }
        }

        resources = {
          requests = {
            cpu    = "200m"
            memory = "256Mi"
          }
          limits = {
            cpu    = "400m"
            memory = "512Mi"
          }
        }
      }

      agents = {
        # Run on all nodes including tainted system/spot nodes
        tolerations = [
          { operator = "Exists", effect = "NoSchedule" },
          { operator = "Exists", effect = "NoExecute" },
        ]

        updateStrategy = {
          type = "RollingUpdate"
          rollingUpdate = {
            maxUnavailable = "10%"
          }
        }

        containers = {
          agent = {
            resources = {
              requests = { cpu = "200m", memory = "256Mi" }
              limits   = { cpu = "400m", memory = "512Mi" }
            }
          }
          processAgent = {
            resources = {
              requests = { cpu = "50m", memory = "64Mi" }
              limits   = { cpu = "200m", memory = "256Mi" }
            }
          }
          traceAgent = {
            resources = {
              requests = { cpu = "50m", memory = "64Mi" }
              limits   = { cpu = "200m", memory = "256Mi" }
            }
          }
          logAgent = {
            resources = {
              requests = { cpu = "50m", memory = "64Mi" }
              limits   = { cpu = "200m", memory = "256Mi" }
            }
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_secret.datadog,
    aws_iam_role_policy_attachment.datadog_cluster_agent,
  ]
}
