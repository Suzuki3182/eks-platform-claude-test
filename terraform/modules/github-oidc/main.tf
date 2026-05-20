terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

# ──────────────────────────────────────────────
# Fetch GitHub OIDC TLS thumbprint dynamically
# ──────────────────────────────────────────────
data "tls_certificate" "github_actions" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

# ──────────────────────────────────────────────
# GitHub Actions OIDC Provider
# Created once per AWS account; set
# create_oidc_provider = false for environments
# that share an account with an existing provider.
# ──────────────────────────────────────────────
resource "aws_iam_openid_connect_provider" "github_actions" {
  count = var.create_oidc_provider ? 1 : 0

  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [
    data.tls_certificate.github_actions.certificates[0].sha1_fingerprint
  ]

  tags = var.tags
}

locals {
  oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github_actions[0].arn : "arn:aws:iam::${var.aws_account_id}:oidc-provider/token.actions.githubusercontent.com"
}

# ──────────────────────────────────────────────
# GitHub Actions IAM Role
# Scoped to the specific repository and environment
# ──────────────────────────────────────────────
data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scope to this repo + environment (branch or GitHub environment)
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repo}:environment:${var.environment}",
        "repo:${var.github_repo}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name                 = "${var.role_name_prefix}-github-actions-${var.environment}"
  description          = "Assumed by GitHub Actions for eks-platform ${var.environment} deployments"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume.json
  max_session_duration = 3600

  tags = var.tags
}

# ──────────────────────────────────────────────
# Terraform state access (S3 + DynamoDB)
# ──────────────────────────────────────────────
data "aws_iam_policy_document" "terraform_state" {
  # Allow bootstrap of the Terraform backend when buckets/tables are missing.
  statement {
    sid    = "TerraformStateBootstrap"
    effect = "Allow"
    actions = [
      "s3:CreateBucket",
      "s3:GetBucketLocation",
      "s3:PutBucketVersioning",
      "s3:PutBucketPublicAccessBlock",
      "dynamodb:CreateTable",
      "dynamodb:DescribeTable",
    ]
    resources = [
      "arn:aws:s3:::eks-platform-tfstate-${var.environment}",
      "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/eks-platform-tfstate-lock",
    ]
  }

  statement {
    sid    = "TerraformStateS3"
    effect = "Allow"
    actions = [
      "s3:HeadBucket",
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketVersioning",
    ]
    resources = [
      "arn:aws:s3:::eks-platform-tfstate-${var.environment}",
      "arn:aws:s3:::eks-platform-tfstate-${var.environment}/*",
    ]
  }

  statement {
    sid    = "TerraformStateLock"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:DeleteItem",
      "dynamodb:DescribeTable",
    ]
    resources = [
      "arn:aws:dynamodb:${var.aws_region}:${var.aws_account_id}:table/eks-platform-tfstate-lock",
    ]
  }

  # Required when backend bucket uses SSE-KMS with a customer-managed key.
  statement {
    sid    = "TerraformStateKMS"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [
      "arn:aws:kms:${var.aws_region}:${var.aws_account_id}:key/*",
    ]
  }
}

resource "aws_iam_policy" "terraform_state" {
  name        = "${var.role_name_prefix}-github-actions-tfstate-${var.environment}"
  description = "Terraform state access for GitHub Actions (${var.environment})"
  policy      = data.aws_iam_policy_document.terraform_state.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "terraform_state" {
  role       = aws_iam_role.github_actions.name
  policy_arn = aws_iam_policy.terraform_state.arn
}

# ──────────────────────────────────────────────
# AWS Managed policies for EKS infrastructure management
# ──────────────────────────────────────────────
resource "aws_iam_role_policy_attachment" "eks_full" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role_policy_attachment" "ec2_full" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

resource "aws_iam_role_policy_attachment" "iam_full" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/IAMFullAccess"
}

resource "aws_iam_role_policy_attachment" "vpc_full" {
  role       = aws_iam_role.github_actions.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonVPCFullAccess"
}

# ──────────────────────────────────────────────
# Inline policy for EKS, KMS, CloudWatch, DynamoDB
# permissions not covered by managed policies
# ──────────────────────────────────────────────
data "aws_iam_policy_document" "eks_operations" {
  statement {
    sid    = "EKSManagement"
    effect = "Allow"
    actions = [
      "eks:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "KMSForEKS"
    effect = "Allow"
    actions = [
      "kms:CreateKey",
      "kms:CreateAlias",
      "kms:DescribeKey",
      "kms:EnableKeyRotation",
      "kms:GetKeyPolicy",
      "kms:GetKeyRotationStatus",
      "kms:ListAliases",
      "kms:ListKeys",
      "kms:PutKeyPolicy",
      "kms:ScheduleKeyDeletion",
      "kms:ListResourceTags",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:ReEncrypt*",
      "kms:CreateGrant",
      "kms:RetireGrant",
      "kms:RevokeGrant",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DescribeLogGroups",
      "logs:ListTagsLogGroup",
      "logs:PutRetentionPolicy",
      "logs:TagLogGroup",
      "logs:UntagLogGroup",
      "logs:ListTagsForResource",
      "logs:TagResource",
      "logs:UntagResource",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AutoScaling"
    effect = "Allow"
    actions = [
      "autoscaling:*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ElasticLoadBalancing"
    effect = "Allow"
    actions = [
      "elasticloadbalancing:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "eks_operations" {
  name   = "eks-operations"
  role   = aws_iam_role.github_actions.name
  policy = data.aws_iam_policy_document.eks_operations.json
}
