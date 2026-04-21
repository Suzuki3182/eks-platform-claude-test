# EKS Platform — Complete Setup & Execution Guide

Production-grade EKS infrastructure on AWS with a fully autonomous CI/CD pipeline. Covers everything from zero to a running cluster in all three environments (test → staging → prod) with security scanning, health validation, and a manual production approval gate.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Repository Initialization](#2-repository-initialization)
3. [AWS Account Preparation](#3-aws-account-preparation)
4. [Bootstrap Remote State](#4-bootstrap-remote-state)
5. [KMS Key for State Encryption](#5-kms-key-for-state-encryption)
6. [Configure GitHub OIDC Trust](#6-configure-github-oidc-trust)
7. [Create IAM Deployment Roles](#7-create-iam-deployment-roles)
8. [Configure GitHub Repository](#8-configure-github-repository)
9. [Update Project Variables](#9-update-project-variables)
10. [Local Validation (Pre-Pipeline)](#10-local-validation-pre-pipeline)
11. [First Manual Deploy — Test Environment](#11-first-manual-deploy--test-environment)
12. [First Manual Deploy — Staging Environment](#12-first-manual-deploy--staging-environment)
13. [First Manual Deploy — Production Environment](#13-first-manual-deploy--production-environment)
14. [Push to GitHub & Run the Pipeline](#14-push-to-github--run-the-pipeline)
15. [Verify Each Pipeline Stage](#15-verify-each-pipeline-stage)
16. [Post-Deploy Cluster Access](#16-post-deploy-cluster-access)
17. [Teardown & Cleanup](#17-teardown--cleanup)
18. [Troubleshooting](#18-troubleshooting)
19. [Architecture Reference](#19-architecture-reference)

---

## 1. Prerequisites

Install all required tools before proceeding. Versions listed are the minimum required.

### Required tools

```bash
# Terraform >= 1.6.0
terraform version

# AWS CLI v2
aws --version

# kubectl >= 1.28
kubectl version --client

# Helm >= 3.13
helm version

# jq (JSON processor)
jq --version

# tfsec (security scanner)
curl -L https://github.com/aquasecurity/tfsec/releases/latest/download/tfsec-linux-amd64 \
  -o /usr/local/bin/tfsec && chmod +x /usr/local/bin/tfsec

# checkov (policy-as-code)
pip3 install checkov

# tflint (Terraform linter)
curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash

# shellcheck (script linter)
sudo apt-get install -y shellcheck    # Debian/Ubuntu
# brew install shellcheck             # macOS

# GitHub CLI (for environment setup)
gh --version
```

### Verify installs

```bash
terraform version && aws --version && kubectl version --client \
  && helm version && tfsec --version && checkov --version \
  && tflint --version && shellcheck --version
```

---

## 2. Repository Initialization

```bash
# Clone or initialize the repository
cd /path/to/your/workspace
git init eks-platform
cd eks-platform

# Copy the generated codebase into this directory
# (if running from the generated location at ~/eks-platform)
cp -r ~/eks-platform/* ~/eks-platform/.github .

# Initialize git and create first commit
git add .
git commit -m "Initial EKS platform infrastructure"

# Connect to GitHub (replace with your org/repo)
gh repo create <YOUR_ORG>/eks-platform --private --push --source=.
```

> **Note:** The repository must be named exactly as it appears in your GitHub OIDC trust policy (configured in Step 6).

---

## 3. AWS Account Preparation

### Set environment variables (used throughout this guide)

```bash
export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export PROJECT="eks-platform"
export GITHUB_ORG="<YOUR_GITHUB_ORG>"
export GITHUB_REPO="eks-platform"

# Verify identity
aws sts get-caller-identity
```

### Confirm required AWS service limits

Ensure the following are available in your region:
- EKS clusters: at least 3 (one per environment)
- VPCs: at least 3
- Elastic IPs: at least 7 (2×3 for per-AZ NAT gateways in staging/prod + 1 for test)
- EC2 instance limits for your chosen instance types

```bash
# Check EKS service limits
aws service-quotas get-service-quota \
  --service-code eks \
  --quota-code L-1194D53C \
  --region $AWS_REGION
```

---

## 4. Bootstrap Remote State

Run **once** before any Terraform commands. Creates the S3 buckets and DynamoDB table used for remote state locking.

```bash
# Create state buckets for each environment
for ENV in test staging prod; do
  echo "Creating state bucket for: $ENV"

  # Create bucket (use --region flag; us-east-1 does not use LocationConstraint)
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket ${PROJECT}-tfstate-${ENV} \
      --region $AWS_REGION
  else
    aws s3api create-bucket \
      --bucket ${PROJECT}-tfstate-${ENV} \
      --region $AWS_REGION \
      --create-bucket-configuration LocationConstraint=$AWS_REGION
  fi

  # Enable versioning
  aws s3api put-bucket-versioning \
    --bucket ${PROJECT}-tfstate-${ENV} \
    --versioning-configuration Status=Enabled

  # Enable KMS encryption
  aws s3api put-bucket-encryption \
    --bucket ${PROJECT}-tfstate-${ENV} \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "aws:kms"
        },
        "BucketKeyEnabled": true
      }]
    }'

  # Block all public access
  aws s3api put-public-access-block \
    --bucket ${PROJECT}-tfstate-${ENV} \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  echo "Done: ${PROJECT}-tfstate-${ENV}"
done

# Create DynamoDB lock table (shared across all environments)
aws dynamodb create-table \
  --table-name ${PROJECT}-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $AWS_REGION \
  --tags Key=Project,Value=$PROJECT Key=ManagedBy,Value=bootstrap

echo "DynamoDB lock table created: ${PROJECT}-tfstate-lock"
```

### Verify state backend

```bash
for ENV in test staging prod; do
  aws s3api get-bucket-versioning --bucket ${PROJECT}-tfstate-${ENV}
  aws s3api get-bucket-encryption --bucket ${PROJECT}-tfstate-${ENV}
done

aws dynamodb describe-table --table-name ${PROJECT}-tfstate-lock --region $AWS_REGION \
  | jq '.Table.TableStatus'
```

Expected output: `"ACTIVE"` for DynamoDB, `"Enabled"` for versioning.

---

## 5. KMS Key for State Encryption

Create a KMS CMK used to encrypt the Terraform state bucket contents and referenced in `backend.tf`.

```bash
# Create the key
KMS_KEY_ID=$(aws kms create-key \
  --description "KMS key for EKS Platform Terraform state encryption" \
  --enable-key-rotation \
  --region $AWS_REGION \
  --tags TagKey=Project,TagValue=$PROJECT TagKey=ManagedBy,TagValue=bootstrap \
  --query KeyMetadata.KeyId \
  --output text)

# Create the alias referenced in backend.tf
aws kms create-alias \
  --alias-name alias/${PROJECT}-tfstate \
  --target-key-id $KMS_KEY_ID \
  --region $AWS_REGION

echo "KMS key ID: $KMS_KEY_ID"
echo "KMS alias:  alias/${PROJECT}-tfstate"

# Apply the CMK to each state bucket
for ENV in test staging prod; do
  aws s3api put-bucket-encryption \
    --bucket ${PROJECT}-tfstate-${ENV} \
    --server-side-encryption-configuration "{
      \"Rules\": [{
        \"ApplyServerSideEncryptionByDefault\": {
          \"SSEAlgorithm\": \"aws:kms\",
          \"KMSMasterKeyID\": \"$KMS_KEY_ID\"
        },
        \"BucketKeyEnabled\": true
      }]
    }"
done
```

---

## 6. Configure GitHub OIDC Trust

This allows GitHub Actions to authenticate to AWS without static credentials.

```bash
# Create the OIDC identity provider in AWS (run once per account)
OIDC_THUMBPRINT=$(curl -s https://token.actions.githubusercontent.com/.well-known/openid-configuration \
  | jq -r '.jwks_uri' \
  | xargs -I{} curl -sv {} 2>&1 \
  | grep -oP '(?<=SHA1 Fingerprint=)[0-9A-Fa-f:]+' \
  | tail -1 \
  | tr -d ':' \
  | tr '[:upper:]' '[:lower:]')

# Alternative: use the known stable thumbprint
OIDC_THUMBPRINT="6938fd4d98bab03faadb97b34396831e3780aea1"

aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list $OIDC_THUMBPRINT

echo "OIDC provider ARN:"
aws iam list-open-id-connect-providers \
  | jq -r '.OpenIDConnectProviderList[].Arn' \
  | grep actions.githubusercontent
```

---

## 7. Create IAM Deployment Roles

One IAM role per environment. Each role is assumed by GitHub Actions via OIDC.

```bash
# Write the trust policy template
cat > /tmp/github-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:environment:ENV_PLACEHOLDER"
        }
      }
    }
  ]
}
EOF

# Create a role for each environment
for ENV in test staging prod; do
  POLICY=$(cat /tmp/github-trust-policy.json | sed "s/ENV_PLACEHOLDER/$ENV/g")

  aws iam create-role \
    --role-name ${PROJECT}-github-${ENV} \
    --assume-role-policy-document "$POLICY" \
    --tags Key=Project,Value=$PROJECT Key=Environment,Value=$ENV Key=ManagedBy,Value=bootstrap

  # Attach permissions — scope these down per your security requirements
  # For initial setup AdministratorAccess is used; restrict after first deploy
  aws iam attach-role-policy \
    --role-name ${PROJECT}-github-${ENV} \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

  echo "Created role: ${PROJECT}-github-${ENV}"
  echo "ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-github-${ENV}"
done
```

> **Security note:** `AdministratorAccess` is used for the first bootstrap run. After the cluster and IAM roles are created via Terraform, replace it with a scoped policy that only allows the specific EKS, EC2, VPC, IAM, and KMS actions the pipeline needs.

---

## 8. Configure GitHub Repository

### Set repository secrets

```bash
# Using GitHub CLI
gh secret set AWS_ACCOUNT_ID --body "$AWS_ACCOUNT_ID" --repo ${GITHUB_ORG}/${GITHUB_REPO}

gh secret set AWS_ROLE_TEST \
  --body "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-github-test" \
  --repo ${GITHUB_ORG}/${GITHUB_REPO}

gh secret set AWS_ROLE_STAGING \
  --body "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-github-staging" \
  --repo ${GITHUB_ORG}/${GITHUB_REPO}

gh secret set AWS_ROLE_PROD \
  --body "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-github-prod" \
  --repo ${GITHUB_ORG}/${GITHUB_REPO}
```

### Create GitHub Environments

```bash
# Create environments via GitHub CLI
# test and staging: auto-approve
gh api repos/${GITHUB_ORG}/${GITHUB_REPO}/environments/test \
  --method PUT \
  --field wait_timer=0

gh api repos/${GITHUB_ORG}/${GITHUB_REPO}/environments/staging \
  --method PUT \
  --field wait_timer=0

# prod: requires manual reviewer (replace USER_LOGIN with actual GitHub username)
gh api repos/${GITHUB_ORG}/${GITHUB_REPO}/environments/prod \
  --method PUT \
  --input - << EOF
{
  "wait_timer": 0,
  "reviewers": [
    {
      "type": "User",
      "id": $(gh api users/<YOUR_GITHUB_USERNAME> --jq '.id')
    }
  ],
  "deployment_branch_policy": {
    "protected_branches": true,
    "custom_branch_policies": false
  }
}
EOF
```

### Protect the `main` branch

```bash
gh api repos/${GITHUB_ORG}/${GITHUB_REPO}/branches/main/protection \
  --method PUT \
  --input - << 'EOF'
{
  "required_status_checks": {
    "strict": true,
    "contexts": ["Build & Validate"]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1
  },
  "restrictions": null
}
EOF
```

---

## 9. Update Project Variables

Edit the following files to replace placeholder values with your real account ID and desired settings.

### `terraform/environments/test/terraform.tfvars`
```hcl
aws_region     = "us-east-1"         # change if needed
aws_account_id = "YOUR_ACCOUNT_ID"   # replace 123456789012
environment    = "test"
project        = "eks-platform"
```

### `terraform/environments/staging/terraform.tfvars`
```hcl
aws_region     = "us-east-1"
aws_account_id = "YOUR_ACCOUNT_ID"
environment    = "staging"
project        = "eks-platform"
```

### `terraform/environments/prod/terraform.tfvars`
```hcl
aws_region     = "us-east-1"
aws_account_id = "YOUR_ACCOUNT_ID"
environment    = "prod"
project        = "eks-platform"
```

```bash
# Quick replace (run from eks-platform/ root)
sed -i "s/123456789012/$AWS_ACCOUNT_ID/g" \
  terraform/environments/test/terraform.tfvars \
  terraform/environments/staging/terraform.tfvars \
  terraform/environments/prod/terraform.tfvars
```

---

## 10. Local Validation (Pre-Pipeline)

Run these checks locally before pushing to GitHub to catch issues early.

```bash
cd ~/eks-platform

# Format check
terraform fmt -check -recursive terraform/
echo "fmt: OK"

# Init + validate all environments (no backend needed)
for ENV in test staging prod; do
  echo "--- Validating: $ENV ---"
  terraform -chdir=terraform/environments/$ENV init -backend=false -upgrade
  terraform -chdir=terraform/environments/$ENV validate
done
echo "validate: OK"

# TFLint
tflint --init
for ENV in test staging prod; do
  tflint --chdir=terraform/environments/$ENV --format=compact
done
echo "tflint: OK"

# tfsec
tfsec terraform/ --minimum-severity HIGH --no-color
echo "tfsec: OK"

# checkov
checkov -d terraform/ --framework terraform --compact --quiet
echo "checkov: OK"

# Shellcheck
shellcheck scripts/k8s-healthcheck.sh scripts/pipeline-agent-verify.sh
echo "shellcheck: OK"
```

All commands must exit 0 before proceeding.

---

## 11. First Manual Deploy — Test Environment

The first deploy must be run manually to establish the Terraform state. The pipeline's backend requires the state bucket to exist before `terraform init` can run.

```bash
cd terraform/environments/test

# Step 1: Initialize with real backend
terraform init \
  -backend-config="bucket=${PROJECT}-tfstate-test" \
  -backend-config="region=${AWS_REGION}"

# Step 2: Plan — review the output carefully
terraform plan \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -out=tfplan.binary | tee plan_test.txt

# Step 3: Review what will be created
cat plan_test.txt | grep -E "^  [+~-]|Plan:"

# Step 4: Apply (creates VPC, EKS cluster, IAM roles, addons)
# Expected duration: 15–25 minutes
terraform apply tfplan.binary

# Step 5: Capture outputs
terraform output
terraform output kubeconfig_command
```

### Verify test cluster

```bash
# Update local kubeconfig
$(terraform output -raw kubeconfig_command)

# Confirm nodes are Ready
kubectl get nodes

# Run health check script
cd ~/eks-platform
./scripts/k8s-healthcheck.sh eks-platform-test $AWS_REGION
```

Expected: all 8 health checks pass, exit code 0.

---

## 12. First Manual Deploy — Staging Environment

```bash
cd ~/eks-platform/terraform/environments/staging

terraform init \
  -backend-config="bucket=${PROJECT}-tfstate-staging" \
  -backend-config="region=${AWS_REGION}"

terraform plan \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -out=tfplan.binary | tee plan_staging.txt

# Review — staging creates per-AZ NAT gateways (3 EIPs consumed)
cat plan_staging.txt | grep "Plan:"

# Apply — expected duration: 20–30 minutes
terraform apply tfplan.binary

# Verify
$(terraform output -raw kubeconfig_command)
kubectl get nodes
cd ~/eks-platform
./scripts/k8s-healthcheck.sh eks-platform-staging $AWS_REGION
```

---

## 13. First Manual Deploy — Production Environment

```bash
cd ~/eks-platform/terraform/environments/prod

terraform init \
  -backend-config="bucket=${PROJECT}-tfstate-prod" \
  -backend-config="region=${AWS_REGION}"

terraform plan \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -out=tfplan.binary | tee plan_prod.txt

# Production uses multi-region KMS, 3 node groups, and 90-day log retention
# Review all changes before applying
cat plan_prod.txt | grep "Plan:"

# Apply — expected duration: 25–35 minutes
terraform apply tfplan.binary

# Verify
$(terraform output -raw kubeconfig_command)
kubectl get nodes
cd ~/eks-platform
./scripts/k8s-healthcheck.sh eks-platform-prod $AWS_REGION
```

---

## 14. Push to GitHub & Run the Pipeline

Once all three environments are manually initialized, every subsequent change goes through the pipeline.

```bash
cd ~/eks-platform

# Ensure scripts are executable (committed with +x)
git update-index --chmod=+x scripts/k8s-healthcheck.sh
git update-index --chmod=+x scripts/pipeline-agent-verify.sh

# Commit all changes
git add .
git commit -m "feat: complete EKS platform with CI/CD pipeline"

# Push to main — triggers the pipeline
git push origin main
```

### Trigger via workflow_dispatch (manual run)

```bash
gh workflow run ci-cd-pipeline.yml \
  --ref main \
  --field environment=test \
  --repo ${GITHUB_ORG}/${GITHUB_REPO}
```

### Watch the pipeline

```bash
# Watch live in terminal
gh run watch --repo ${GITHUB_ORG}/${GITHUB_REPO}

# List recent runs
gh run list --repo ${GITHUB_ORG}/${GITHUB_REPO} --limit 5
```

---

## 15. Verify Each Pipeline Stage

### Stage 1 — Build (automatic)

```bash
# Check build stage status
gh run view --repo ${GITHUB_ORG}/${GITHUB_REPO} --log | grep -E "PASS|FAIL|fmt|validate|tflint"
```

Expected: `fmt: passed`, `validate: passed`, `tflint: passed`.

### Stage 2 — Test (automatic if Build passes)

```bash
# Download the test stage artifact
gh run download --repo ${GITHUB_ORG}/${GITHUB_REPO} --name test-status

cat agent-output.json | jq .
```

Expected:
```json
{
  "stage": "test",
  "status": "success",
  "reason": "tfsec=success, checkov=success, apply=success, healthcheck=success, agent=success"
}
```

### Stage 3 — Staging (automatic if Test passes)

```bash
gh run download --repo ${GITHUB_ORG}/${GITHUB_REPO} --name staging-status
cat agent-output.json | jq .
```

Staging additionally validates: cluster autoscaler, DNS resolution, ingress controller, metrics server.

### Stage 4 — Production (requires manual approval)

1. Navigate to **GitHub → Actions → latest run → Production Environment**
2. Click **Review deployments**
3. Select `prod` and click **Approve and deploy**

```bash
# Alternatively approve via CLI
gh run review --repo ${GITHUB_ORG}/${GITHUB_REPO} --approve
```

After production completes:

```bash
gh run download --repo ${GITHUB_ORG}/${GITHUB_REPO} --name prod-status
cat agent-output.json | jq .
```

---

## 16. Post-Deploy Cluster Access

### Update kubeconfig for each environment

```bash
# Test
aws eks update-kubeconfig \
  --region $AWS_REGION \
  --name eks-platform-test \
  --alias test

# Staging
aws eks update-kubeconfig \
  --region $AWS_REGION \
  --name eks-platform-staging \
  --alias staging

# Production
aws eks update-kubeconfig \
  --region $AWS_REGION \
  --name eks-platform-prod \
  --alias prod
```

### Switch between clusters

```bash
kubectl config use-context test
kubectl config use-context staging
kubectl config use-context prod
```

### Verify cluster health

```bash
# Node status
kubectl get nodes -o wide

# System pods
kubectl get pods -n kube-system

# Addon versions
kubectl get deployment coredns aws-load-balancer-controller cluster-autoscaler metrics-server \
  -n kube-system -o wide

# Node resource usage
kubectl top nodes

# Check HPA / autoscaling
kubectl get hpa -A
```

### Run the full health check manually

```bash
cd ~/eks-platform

# Run against any environment
./scripts/k8s-healthcheck.sh eks-platform-test $AWS_REGION
./scripts/k8s-healthcheck.sh eks-platform-staging $AWS_REGION
./scripts/k8s-healthcheck.sh eks-platform-prod $AWS_REGION
```

---

## 17. Teardown & Cleanup

> **Warning:** These steps permanently destroy infrastructure. Never run against production without explicit authorization and a full backup of state.

### Destroy test environment

```bash
cd terraform/environments/test

terraform destroy \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -auto-approve
```

### Destroy staging environment

```bash
cd ../staging

terraform destroy \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -auto-approve
```

### Destroy production environment

```bash
# Production requires two-step confirmation
cd ../prod

# Step 1: Plan the destroy and review
terraform plan -destroy \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -out=destroy.plan | tee destroy_review.txt

cat destroy_review.txt | grep "Plan:"

# Step 2: Apply only after explicit review
terraform apply destroy.plan
```

### Clean up bootstrap resources

```bash
# Delete state buckets (after all Terraform resources are destroyed)
for ENV in test staging prod; do
  # Empty the bucket first
  aws s3 rm s3://${PROJECT}-tfstate-${ENV} --recursive

  # Delete bucket
  aws s3api delete-bucket \
    --bucket ${PROJECT}-tfstate-${ENV} \
    --region $AWS_REGION
done

# Delete DynamoDB lock table
aws dynamodb delete-table \
  --table-name ${PROJECT}-tfstate-lock \
  --region $AWS_REGION

# Schedule KMS key for deletion (minimum 7 days)
aws kms schedule-key-deletion \
  --key-id alias/${PROJECT}-tfstate \
  --pending-window-in-days 7 \
  --region $AWS_REGION

# Delete IAM deployment roles
for ENV in test staging prod; do
  aws iam detach-role-policy \
    --role-name ${PROJECT}-github-${ENV} \
    --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
  aws iam delete-role --role-name ${PROJECT}-github-${ENV}
done

# Delete OIDC provider (only if no other repos use it)
OIDC_ARN=$(aws iam list-open-id-connect-providers \
  | jq -r '.OpenIDConnectProviderList[].Arn' \
  | grep actions.githubusercontent)
aws iam delete-open-id-connect-provider --open-id-connect-provider-arn $OIDC_ARN
```

---

## 18. Troubleshooting

### `terraform init` fails: bucket does not exist

```
Error: Failed to get existing workspaces: S3 bucket does not exist.
```

**Fix:** Run Step 4 (Bootstrap Remote State) before `terraform init`.

---

### `terraform init` fails: KMS key not found

```
Error: error getting S3 Bucket encryption: NoSuchBucket
```

**Fix:** Verify the KMS alias `alias/eks-platform-tfstate` exists:
```bash
aws kms describe-key --key-id alias/${PROJECT}-tfstate --region $AWS_REGION
```

---

### GitHub Actions: `Error: Credentials could not be loaded`

```
Error: Credentials could not be loaded, please check your action inputs
```

**Fix:**
1. Verify the OIDC provider was created: `aws iam list-open-id-connect-providers`
2. Verify the IAM role trust policy matches the repo/environment exactly
3. Confirm `AWS_ROLE_TEST` / `AWS_ROLE_STAGING` / `AWS_ROLE_PROD` secrets are set in GitHub

---

### EKS nodes not joining the cluster

```bash
# Check node group status
aws eks describe-nodegroup \
  --cluster-name eks-platform-test \
  --nodegroup-name eks-platform-test-system \
  --region $AWS_REGION \
  | jq '.nodegroup.status, .nodegroup.health'

# Check node bootstrap logs via SSM
aws ssm start-session --target <instance-id>
sudo journalctl -u kubelet --no-pager -n 50
```

Common causes: IAM node role missing `AmazonEKSWorkerNodePolicy`, subnets not tagged correctly for Kubernetes.

---

### Pods stuck in `Pending` state

```bash
# Describe the pod for scheduling events
kubectl describe pod <pod-name> -n kube-system

# Check node capacity
kubectl describe nodes | grep -A5 "Allocated resources"

# Check cluster autoscaler logs
kubectl logs -n kube-system deployment/cluster-autoscaler --tail=50
```

---

### `tfsec` HIGH findings blocking the pipeline

```bash
# View all findings locally
tfsec terraform/ --format json | jq '.results[] | {severity, description, location}'

# View only HIGH+
tfsec terraform/ --minimum-severity HIGH
```

Each finding includes the file, line, and a remediation link. Fix the underlying resource configuration — do not add `#tfsec:ignore` annotations without documented justification.

---

### Terraform state lock not releasing

```bash
# List locks in DynamoDB
aws dynamodb scan \
  --table-name ${PROJECT}-tfstate-lock \
  --region $AWS_REGION

# Force-unlock (only if the locking process is confirmed dead)
terraform force-unlock <LOCK_ID>
```

---

### DNS test pod fails in health check

```bash
# Check CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Check CoreDNS logs
kubectl logs -n kube-system deployment/coredns --tail=30

# Check VPC DNS settings
aws ec2 describe-vpc-attribute \
  --vpc-id <VPC_ID> \
  --attribute enableDnsSupport \
  --region $AWS_REGION
```

---

## 19. Architecture Reference

### Directory Structure

```
eks-platform/
├── .github/
│   └── workflows/
│       └── ci-cd-pipeline.yml       # 4-stage pipeline: build → test → staging → prod
├── terraform/
│   ├── modules/
│   │   ├── vpc/                     # Multi-AZ VPC, NAT gateways, VPC endpoints, flow logs
│   │   ├── eks/                     # EKS cluster, managed node groups, OIDC provider
│   │   ├── iam/                     # IRSA roles: LBC, CA, VPC CNI, EBS CSI, node, cluster
│   │   └── addons/                  # EKS addons + Helm: LBC, Cluster Autoscaler, Metrics Server
│   └── environments/
│       ├── test/                    # Single NAT GW, SPOT nodes, 7-day log retention
│       ├── staging/                 # Per-AZ NAT GWs, mixed SPOT/on-demand, 30-day retention
│       └── prod/                    # HA nodes, multi-region KMS, 3 node groups, 90-day retention
├── scripts/
│   ├── k8s-healthcheck.sh          # 8 health checks: nodes, pods, DNS, ingress, CSI, CNI
│   └── pipeline-agent-verify.sh   # Validation agent, emits agent-output.json artifacts
├── Claude.md                        # Autonomous orchestration rules and approval matrix
└── Skills.md                        # Executable skill definitions for pipeline operations
```

### Environment Differences

| Feature                  | test         | staging        | prod               |
|--------------------------|--------------|----------------|--------------------|
| VPC CIDR                 | 10.10.0.0/16 | 10.20.0.0/16   | 10.30.0.0/16       |
| NAT Gateways             | 1 (shared)   | 3 (per-AZ)     | 3 (per-AZ)         |
| KMS multi-region         | No           | No             | Yes                |
| KMS deletion window      | 7 days       | 14 days        | 30 days            |
| Log retention            | 7 days       | 30 days        | 90 days            |
| System nodes             | 2× t3.medium | 2× m5.large    | 3× m5.xlarge       |
| Workload nodes           | SPOT t3.large| SPOT m5.xlarge | ON_DEMAND + SPOT   |
| Min nodes                | 1            | 1              | 2 (on-demand)      |
| Max nodes                | 13           | 24             | 76                 |
| Pipeline deploy approval | Auto         | Auto           | Manual             |

### Security Controls

| Control                       | Implementation                              |
|-------------------------------|---------------------------------------------|
| Private EKS endpoint          | `endpoint_public_access = false`            |
| Secrets encryption            | KMS CMK via `encryption_config`             |
| EBS encryption                | KMS CMK in all launch templates             |
| IMDSv2 enforced               | `http_tokens = "required"` in LT           |
| No static AWS credentials     | GitHub OIDC `AssumeRoleWithWebIdentity`     |
| Least-privilege IAM           | Scoped IRSA per controller, no wildcards    |
| VPC flow logs                 | CloudWatch Logs, KMS-encrypted              |
| 10× VPC interface endpoints   | ECR, STS, ELB, SSM, EC2, ASG, CW Logs      |
| Network policies              | Default-deny ingress in default namespace   |
| Security scanning             | tfsec + checkov gate on every push          |
| State encryption              | KMS CMK on S3 + DynamoDB locking            |

### Pipeline Stage Flow

```
push to main / PR
       │
       ▼
┌─────────────┐
│    BUILD    │  terraform fmt + validate + tflint + shellcheck
└──────┬──────┘
       │ pass
       ▼
┌─────────────┐
│    TEST     │  tfsec + checkov + tf apply + k8s-healthcheck + agent
└──────┬──────┘  (AWS: eks-platform-test)
       │ pass
       ▼
┌─────────────┐
│   STAGING   │  tf apply + healthcheck + autoscaler + DNS + ingress + metrics + agent
└──────┬──────┘  (AWS: eks-platform-staging)
       │ pass
       ▼
┌─────────────┐
│  ⏸ MANUAL  │  GitHub Environment protection rule — human approval required
│  APPROVAL  │
└──────┬──────┘
       │ approved
       ▼
┌─────────────┐
│    PROD     │  security rescan + tf apply + healthcheck + rollout verify + agent
└─────────────┘  (AWS: eks-platform-prod)
```

### Rollback Flow (automatic on failure)

```
apply fails / healthcheck fails / agent emits failure
       │
       ▼
terraform apply -refresh-only   # reconcile state, non-destructive
       +
kubectl rollout undo deployment --all -n kube-system
       │
       ▼
stage marked FAILED → next stage blocked → pipeline halts
```
# eks-platform-claude-test
