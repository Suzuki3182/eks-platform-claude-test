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
  deletion_window_in_days = 30
  enable_key_rotation     = true
  multi_region            = true

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
  vpc_cidr           = "10.30.0.0/16"
  az_count           = 3
  single_nat_gateway = false
  aws_region         = var.aws_region
  kms_key_arn        = aws_kms_key.eks.arn

  flow_logs_retention_days = 90

  tags = local.common_tags
}

module "iam_bootstrap" {
  source = "../../modules/iam"

  cluster_name      = local.cluster_name
  oidc_provider_arn = "arn:aws:iam::${var.aws_account_id}:oidc-provider/placeholder"
  oidc_issuer_url   = "https://placeholder"
  aws_region        = var.aws_region
  aws_account_id    = var.aws_account_id
  vpc_id            = module.vpc.vpc_id

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

  cluster_log_retention_days = 90

  node_groups = {
    system = {
      instance_types = ["m5.xlarge"]
      capacity_type  = "ON_DEMAND"
      min_size       = 3
      max_size       = 6
      desired_size   = 3
      disk_size      = 50
      labels         = { role = "system" }
      taints         = []
    }
    workload_on_demand = {
      instance_types = ["m5.2xlarge"]
      capacity_type  = "ON_DEMAND"
      min_size       = 2
      max_size       = 20
      desired_size   = 3
      disk_size      = 200
      labels         = { role = "workload", tier = "on-demand" }
      taints         = []
    }
    workload_spot = {
      instance_types = ["m5.2xlarge", "m5a.2xlarge", "m4.2xlarge", "m5d.2xlarge"]
      capacity_type  = "SPOT"
      min_size       = 0
      max_size       = 50
      desired_size   = 5
      disk_size      = 200
      labels         = { role = "workload", tier = "spot" }
      taints = [{
        key    = "spot"
        value  = "true"
        effect = "PREFER_NO_SCHEDULE"
      }]
    }
  }

  tags = local.common_tags
}

module "iam" {
  source = "../../modules/iam"

  cluster_name      = local.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_issuer_url   = module.eks.oidc_issuer_url
  aws_region        = var.aws_region
  aws_account_id    = var.aws_account_id
  vpc_id            = module.vpc.vpc_id

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
