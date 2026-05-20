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
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = var.environment
      ManagedBy   = "terraform"
      Project     = var.project
      Compliance  = "pci-dss"
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.aws_region]
    }
  }
}

locals {
  cluster_name = "${var.project}-${var.environment}"
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project
    Compliance  = "pci-dss"
  }
}

resource "aws_kms_key" "eks" {
  description             = "KMS key for ${local.cluster_name} EKS secrets and EBS volumes"
  deletion_window_in_days = 14
  enable_key_rotation     = true
  multi_region            = false

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.aws_account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowEKS"
        Effect    = "Allow"
        Principal = { Service = "eks.amazonaws.com" }
        Action    = ["kms:DescribeKey", "kms:GenerateDataKey", "kms:Decrypt"]
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatch"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
      },
      {
        Sid       = "AllowEC2EBSUse"
        Effect    = "Allow"
        Principal = { AWS = "*" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:CreateGrant", "kms:DescribeKey"]
        Resource  = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = var.aws_account_id
            "kms:ViaService"    = "ec2.${var.aws_region}.amazonaws.com"
          }
          Bool = {
            "kms:GrantIsForAWSResource" = true
          }
        }
      },
      {
        Sid       = "AllowAutoScalingServiceRoleUse"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.aws_account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:DescribeKey"]
        Resource  = "*"
      },
      {
        Sid       = "AllowAutoScalingServiceRoleGrant"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${var.aws_account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling" }
        Action    = ["kms:CreateGrant"]
        Resource  = "*"
        Condition = {
          Bool = {
            "kms:GrantIsForAWSResource" = true
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.cluster_name}"
  target_key_id = aws_kms_key.eks.key_id
}

module "vpc" {
  source = "../../modules/vpc"

  name               = local.cluster_name
  cluster_name       = local.cluster_name
  vpc_cidr           = "10.20.0.0/16"
  az_count           = 3
  single_nat_gateway = false
  aws_region         = var.aws_region
  kms_key_arn        = aws_kms_key.eks.arn

  flow_logs_retention_days = 30

  tags = local.common_tags
}

module "iam_bootstrap" {
  source = "../../modules/iam"

  cluster_name                  = local.cluster_name
  oidc_provider_arn             = "arn:aws:iam::${var.aws_account_id}:oidc-provider/placeholder"
  oidc_issuer_url               = "https://placeholder"
  aws_region                    = var.aws_region
  aws_account_id                = var.aws_account_id
  vpc_id                        = module.vpc.vpc_id
  create_cluster_and_node_roles = true
  create_irsa_roles             = false

  tags = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = local.cluster_name
  cluster_version    = "1.29"
  vpc_id             = module.vpc.vpc_id
  vpc_cidr           = module.vpc.vpc_cidr
  private_subnet_ids = module.vpc.private_subnet_ids
  cluster_role_arn   = module.iam_bootstrap.cluster_role_arn
  node_role_arn      = module.iam_bootstrap.node_role_arn
  kms_key_arn        = aws_kms_key.eks.arn
  aws_region         = var.aws_region
  aws_account_id     = var.aws_account_id

  cluster_log_retention_days = 30

  node_groups = {
    system = {
      instance_types = ["m5.large"]
      capacity_type  = "ON_DEMAND"
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      disk_size      = 50
      labels         = { role = "system" }
      taints         = []
    }
    workload = {
      instance_types = ["m5.xlarge", "m5a.xlarge", "m4.xlarge"]
      capacity_type  = "SPOT"
      min_size       = 1
      max_size       = 20
      desired_size   = 3
      disk_size      = 100
      labels         = { role = "workload" }
      taints         = []
    }
  }

  tags = local.common_tags
}

module "iam" {
  source = "../../modules/iam"

  cluster_name                  = local.cluster_name
  oidc_provider_arn             = module.eks.oidc_provider_arn
  oidc_issuer_url               = module.eks.oidc_issuer_url
  aws_region                    = var.aws_region
  aws_account_id                = var.aws_account_id
  vpc_id                        = module.vpc.vpc_id
  create_cluster_and_node_roles = false
  create_irsa_roles             = true

  tags = local.common_tags

  depends_on = [module.eks]
}

module "addons" {
  source = "../../modules/addons"

  cluster_name                = module.eks.cluster_name
  cluster_version             = "1.29"
  vpc_cni_role_arn            = module.iam.vpc_cni_role_arn
  ebs_csi_role_arn            = module.iam.ebs_csi_role_arn
  lbc_role_arn                = module.iam.lbc_role_arn
  cluster_autoscaler_role_arn = module.iam.cluster_autoscaler_role_arn
  vpc_id                      = module.vpc.vpc_id
  aws_region                  = var.aws_region

  tags = local.common_tags

  depends_on = [module.eks, module.iam]
}

# ──────────────────────────────────────────────
# ECR Repository
# ──────────────────────────────────────────────
module "ecr" {
  source = "../../modules/ecr"

  name        = "${local.cluster_name}-app"
  kms_key_arn = aws_kms_key.eks.arn

  tags = local.common_tags
}

# ──────────────────────────────────────────────
# TypeScript Application
# ──────────────────────────────────────────────
module "app" {
  source = "../../modules/app"

  app_name         = "typescript-app"
  namespace        = "app"
  environment      = var.environment
  image_repository = module.ecr.repository_url
  image_tag        = var.app_image_tag
  replicas         = 2
  min_replicas     = 2
  max_replicas     = 20
  create_ingress   = true
  ingress_scheme   = "internet-facing"

  depends_on = [module.addons]
}

# ──────────────────────────────────────────────
# GitHub Actions OIDC
# OIDC provider already created in test environment
# (same AWS account); only creates the staging role.
# ──────────────────────────────────────────────
module "github_oidc" {
  source = "../../modules/github-oidc"

  github_repo          = var.github_repo
  environment          = var.environment
  aws_account_id       = var.aws_account_id
  aws_region           = var.aws_region
  create_oidc_provider = false

  tags = local.common_tags
}