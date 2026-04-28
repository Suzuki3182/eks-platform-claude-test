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
20. [Datadog Observability & Monitoring](#20-datadog-observability--monitoring)
21. [Autonomous Datadog Configuration Agent](#21-autonomous-datadog-configuration-agent)

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

# Datadog secrets (see Section 20 for how to obtain these)
gh secret set DD_API_KEY \
  --body "<YOUR_DATADOG_API_KEY>" \
  --repo ${GITHUB_ORG}/${GITHUB_REPO}

gh secret set DD_APP_KEY \
  --body "<YOUR_DATADOG_APP_KEY>" \
  --repo ${GITHUB_ORG}/${GITHUB_REPO}
```

> **Datadog keys:** `DD_API_KEY` is required. `DD_APP_KEY` is recommended — it enables the Metrics Provider (HPA on Datadog metrics) and Admission Controller. See [Section 20](#20-datadog-observability--monitoring) for step-by-step instructions to obtain both keys.

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
datadog_site   = "datadoghq.com"     # change if using EU or Gov region (see Section 20)
```

### `terraform/environments/staging/terraform.tfvars`
```hcl
aws_region     = "us-east-1"
aws_account_id = "YOUR_ACCOUNT_ID"
environment    = "staging"
project        = "eks-platform"
datadog_site   = "datadoghq.com"
```

### `terraform/environments/prod/terraform.tfvars`
```hcl
aws_region     = "us-east-1"
aws_account_id = "YOUR_ACCOUNT_ID"
environment    = "prod"
project        = "eks-platform"
datadog_site   = "datadoghq.com"
```

```bash
# Quick replace (run from eks-platform/ root)
sed -i "s/123456789012/$AWS_ACCOUNT_ID/g" \
  terraform/environments/test/terraform.tfvars \
  terraform/environments/staging/terraform.tfvars \
  terraform/environments/prod/terraform.tfvars
```

> **`datadog_site`** must match the site where your Datadog account is registered. Common values: `datadoghq.com` (US1), `us3.datadoghq.com` (US3), `us5.datadoghq.com` (US5), `datadoghq.eu` (EU1). Using the wrong site means the agent will accept data but never deliver it to your account.

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
  -var="datadog_api_key=${DD_API_KEY}" \
  -var="datadog_app_key=${DD_APP_KEY}" \
  -out=tfplan.binary | tee plan_test.txt

# Step 3: Review what will be created
cat plan_test.txt | grep -E "^  [+~-]|Plan:"

# Step 4: Apply (creates VPC, EKS cluster, IAM roles, addons, and Datadog)
# Expected duration: 18–28 minutes (Datadog Helm deploy adds ~3 min)
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

Expected: all 9 health checks pass (including Datadog Agent DaemonSet and Cluster Agent), exit code 0.

---

## 12. First Manual Deploy — Staging Environment

```bash
cd ~/eks-platform/terraform/environments/staging

terraform init \
  -backend-config="bucket=${PROJECT}-tfstate-staging" \
  -backend-config="region=${AWS_REGION}"

terraform plan \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -var="datadog_api_key=${DD_API_KEY}" \
  -var="datadog_app_key=${DD_APP_KEY}" \
  -out=tfplan.binary | tee plan_staging.txt

# Review — staging creates per-AZ NAT gateways (3 EIPs consumed)
# Also deploys Datadog with 2 Cluster Agent replicas for HA
cat plan_staging.txt | grep "Plan:"

# Apply — expected duration: 23–33 minutes
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
  -var="datadog_api_key=${DD_API_KEY}" \
  -var="datadog_app_key=${DD_APP_KEY}" \
  -out=tfplan.binary | tee plan_prod.txt

# Production uses multi-region KMS, 3 node groups, 90-day log retention,
# and Datadog Cluster Agent in HA mode (2 replicas with PDB)
cat plan_prod.txt | grep "Plan:"

# Apply — expected duration: 28–38 minutes
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
  -var="datadog_api_key=${DD_API_KEY}" \
  -var="datadog_app_key=${DD_APP_KEY}" \
  -auto-approve
```

### Destroy staging environment

```bash
cd ../staging

terraform destroy \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -var="datadog_api_key=${DD_API_KEY}" \
  -var="datadog_app_key=${DD_APP_KEY}" \
  -auto-approve
```

### Destroy production environment

```bash
# Production requires two-step confirmation
cd ../prod

# Step 1: Plan the destroy and review
terraform plan -destroy \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -var="datadog_api_key=${DD_API_KEY}" \
  -var="datadog_app_key=${DD_APP_KEY}" \
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
│   │   ├── addons/                  # EKS addons + Helm: LBC, Cluster Autoscaler, Metrics Server
│   │   └── datadog/                 # Datadog Agent + Cluster Agent + IRSA (observability)
│   └── environments/
│       ├── test/                    # Single NAT GW, SPOT nodes, 7-day log retention
│       ├── staging/                 # Per-AZ NAT GWs, mixed SPOT/on-demand, 30-day retention
│       └── prod/                    # HA nodes, multi-region KMS, 3 node groups, 90-day retention
├── scripts/
│   ├── k8s-healthcheck.sh          # 9 health checks: nodes, pods, DNS, ingress, CSI, CNI, Datadog
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
| Datadog Cluster Agent    | 1 replica    | 2 replicas (HA)| 2 replicas (HA+PDB)|
| Datadog APM              | Enabled      | Enabled        | Enabled            |
| Datadog NPM              | Disabled     | Disabled       | Disabled*          |

> *NPM (Network Performance Monitoring) can be enabled per-environment by setting `enable_npm = true` in the `module "datadog"` block. It requires kernel eBPF support (available on all EKS-optimized AMIs) and an active NPM subscription in Datadog.

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
---

## 20. Datadog Observability & Monitoring

### Overview

Datadog is deployed to all three environments (test, staging, prod) as part of the standard Terraform stack. It runs as a first-class citizen alongside the EKS cluster — provisioned, versioned, and health-checked the same way as every other component.

**What is deployed** (via `terraform/modules/datadog/`):

| Component | Type | What it does |
|-----------|------|--------------|
| Datadog Agent | DaemonSet (one pod per node) | Collects host metrics, container metrics, logs, APM traces, live processes |
| Datadog Cluster Agent | Deployment (1–2 replicas) | Kubernetes State Metrics, cluster events, External Metrics Provider for HPA, Admission Controller |
| IRSA IAM Role | AWS IAM | Grants Cluster Agent read-only access to EC2, EKS, CloudWatch, AutoScaling, and resource tagging APIs |
| Kubernetes Secret | `datadog-secret` in `datadog` ns | Holds `api-key` and `app-key` — never written to state in plaintext |
| Kubernetes Namespace | `datadog` | Isolated namespace for all Datadog workloads |

**What data Datadog receives out of the box:**

- **Infrastructure metrics** — CPU, memory, disk, network for every node and pod
- **Kubernetes State Metrics** — pod phases, deployment rollout status, HPA, PVC health, node conditions
- **Container logs** — all stdout/stderr from every container in the cluster
- **APM traces** — applications that emit traces via port 8126 or the Unix socket
- **Live processes** — running processes per node with resource breakdown
- **Kubernetes events** — pod scheduling failures, OOMKills, node pressure events
- **AWS CloudWatch metrics** — EC2, EKS, and AutoScaling metrics via the IRSA-authenticated Cluster Agent
- **Orchestrator Explorer** — real-time pod / deployment / node topology in the Datadog UI
- **Container image metadata** — image names, tags, and digests for Software Catalog
- **SBOM** — container image vulnerability inventory

---

### Step 1 — Create a Datadog Account

If you do not already have a Datadog account:

1. Go to [https://app.datadoghq.com](https://app.datadoghq.com) and sign up for a free trial (14 days, no credit card required)
2. Select the **site** that matches your region. Note this value — it must match `datadog_site` in your `terraform.tfvars`:

| Datadog Site | URL | `datadog_site` value |
|---|---|---|
| US1 (default) | app.datadoghq.com | `datadoghq.com` |
| US3 | us3.datadoghq.com | `us3.datadoghq.com` |
| US5 | us5.datadoghq.com | `us5.datadoghq.com` |
| EU1 | app.datadoghq.eu | `datadoghq.eu` |
| AP1 | ap1.datadoghq.com | `ap1.datadoghq.com` |

> **Critical:** If `datadog_site` does not match the site where your account is registered, the agent will appear healthy locally but data will never arrive in the UI.

---

### Step 2 — Obtain Your API Key and Application Key

#### API Key (required)

1. In the Datadog UI, go to **Organization Settings → API Keys** (or navigate to `https://app.datadoghq.com/organization-settings/api-keys`)
2. Click **+ New Key**
3. Name it `eks-platform` (or any descriptive name)
4. Copy the key value immediately — it is only shown once

#### Application Key (recommended)

The App Key is used by the Cluster Agent's External Metrics Provider (enables Kubernetes HPA scaled on Datadog metrics) and the Admission Controller.

1. Go to **Organization Settings → Application Keys**
2. Click **+ New Key**
3. Name it `eks-platform-cluster-agent`
4. Copy the key value

```bash
# Export for use in the commands below
export DD_API_KEY="<paste your API key here>"
export DD_APP_KEY="<paste your app key here>"
```

---

### Step 3 — Store Keys as GitHub Secrets

The CI/CD pipeline reads `DD_API_KEY` and `DD_APP_KEY` from GitHub Actions secrets and passes them to Terraform at plan/apply time. They are never written to `terraform.tfvars` or committed to the repository.

```bash
# Store in GitHub (requires gh CLI authenticated)
gh secret set DD_API_KEY \
  --body "${DD_API_KEY}" \
  --repo ${GITHUB_ORG}/${GITHUB_REPO}

gh secret set DD_APP_KEY \
  --body "${DD_APP_KEY}" \
  --repo ${GITHUB_ORG}/${GITHUB_REPO}

# Verify secrets are set
gh secret list --repo ${GITHUB_ORG}/${GITHUB_REPO}
```

Expected output includes `DD_API_KEY` and `DD_APP_KEY` in the secrets list.

---

### Step 4 — Verify `datadog_site` in tfvars

Confirm the correct site is set in all three environment tfvars files:

```bash
grep datadog_site terraform/environments/*/terraform.tfvars
```

Expected output:
```
terraform/environments/prod/terraform.tfvars:datadog_site    = "datadoghq.com"
terraform/environments/staging/terraform.tfvars:datadog_site = "datadoghq.com"
terraform/environments/test/terraform.tfvars:datadog_site    = "datadoghq.com"
```

To change the site (e.g., EU):
```bash
sed -i 's/datadog_site   = "datadoghq.com"/datadog_site   = "datadoghq.eu"/' \
  terraform/environments/test/terraform.tfvars \
  terraform/environments/staging/terraform.tfvars \
  terraform/environments/prod/terraform.tfvars
```

---

### Step 5 — Local Validation (Datadog Module)

Before pushing, validate that the Datadog module parses and formats correctly:

```bash
cd ~/eks-platform

# Format check (must exit 0)
terraform fmt -check -recursive terraform/modules/datadog/
terraform fmt -check -recursive terraform/environments/

# Init and validate each environment (no real deploy, no backend)
for ENV in test staging prod; do
  echo "--- Validating $ENV ---"
  terraform -chdir=terraform/environments/$ENV init -backend=false -upgrade
  terraform -chdir=terraform/environments/$ENV validate
done

# Confirm the new variable declarations exist
grep -l "datadog_api_key" terraform/environments/*/variables.tf
```

All commands must exit 0.

---

### Step 6 — First Manual Deploy with Datadog

If you are deploying for the first time (following sections 11–13), pass the Datadog variables alongside `aws_account_id`:

```bash
# Test environment
cd terraform/environments/test
terraform init -backend-config="bucket=${PROJECT}-tfstate-test" -backend-config="region=${AWS_REGION}"
terraform plan \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -var="datadog_api_key=${DD_API_KEY}" \
  -var="datadog_app_key=${DD_APP_KEY}" \
  -out=tfplan.binary
terraform apply tfplan.binary

# Staging environment
cd ../staging
terraform init -backend-config="bucket=${PROJECT}-tfstate-staging" -backend-config="region=${AWS_REGION}"
terraform plan \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -var="datadog_api_key=${DD_API_KEY}" \
  -var="datadog_app_key=${DD_APP_KEY}" \
  -out=tfplan.binary
terraform apply tfplan.binary

# Production environment
cd ../prod
terraform init -backend-config="bucket=${PROJECT}-tfstate-prod" -backend-config="region=${AWS_REGION}"
terraform plan \
  -var="aws_account_id=${AWS_ACCOUNT_ID}" \
  -var="datadog_api_key=${DD_API_KEY}" \
  -var="datadog_app_key=${DD_APP_KEY}" \
  -out=tfplan.binary
terraform apply tfplan.binary
```

Terraform creates the following resources per environment (in addition to the existing EKS stack):

```
kubernetes_namespace.datadog
kubernetes_secret.datadog
aws_iam_role.datadog_cluster_agent
aws_iam_policy.datadog_cluster_agent
aws_iam_role_policy_attachment.datadog_cluster_agent
helm_release.datadog
```

The Helm release deploys approximately 14–16 Kubernetes resources (DaemonSet, Deployment, ServiceAccount, ClusterRole, Services, ConfigMaps, etc.).

---

### Step 7 — Verify the Deployment

#### Check Kubernetes resources

```bash
# Update kubeconfig for the target cluster
aws eks update-kubeconfig --region $AWS_REGION --name eks-platform-test

# All Datadog pods should be Running
kubectl get pods -n datadog

# Agent DaemonSet: one pod per node
kubectl get daemonset datadog -n datadog

# Cluster Agent: 1 pod (test), 2 pods (staging/prod)
kubectl get deployment datadog-cluster-agent -n datadog

# IRSA annotation on Cluster Agent service account
kubectl get serviceaccount datadog-cluster-agent -n datadog -o jsonpath='{.metadata.annotations}'
```

Expected DaemonSet output:
```
NAME      DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE
datadog   3         3         3       3            3
```

Expected Cluster Agent output (staging/prod):
```
NAME                     READY   UP-TO-DATE   AVAILABLE
datadog-cluster-agent    2/2     2            2
```

#### Check agent connectivity

```bash
# Get logs from one Agent pod — look for "Datadog Agent initialized"
kubectl logs -n datadog daemonset/datadog --tail=30 | grep -E "initialized|connected|error"

# Check Cluster Agent logs — look for "Datadog Cluster Agent is now started"
kubectl logs -n datadog deployment/datadog-cluster-agent --tail=30

# Verify agent status inside a pod (detailed health report)
AGENT_POD=$(kubectl get pods -n datadog -l app=datadog -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n datadog $AGENT_POD -- agent status 2>/dev/null | head -60
```

#### Run the health check script

```bash
cd ~/eks-platform
./scripts/k8s-healthcheck.sh eks-platform-test $AWS_REGION
```

Look for CHECK 9 output:
```
[CHECK] Datadog Observability Stack
[INFO]  PASS: Datadog Agent DaemonSet: 3/3 ready
[INFO]  PASS: Datadog Cluster Agent: 1/1 ready
[INFO]  PASS: No CrashLoopBackOff pods in datadog namespace
```

#### Verify data in Datadog UI

1. Log in to your Datadog account
2. Navigate to **Infrastructure → Containers** — you should see all cluster pods within 2–3 minutes of deployment
3. Navigate to **Infrastructure → Hosts** — EKS nodes appear tagged with `cluster:<cluster-name>`, `env:<environment>`, `region:<aws-region>`
4. Navigate to **Logs → Live Tail** — container stdout/stderr logs appear within ~60 seconds
5. Navigate to **Infrastructure → Kubernetes** — full cluster topology (pods, deployments, nodes, namespaces)

---

### Step 8 — Pipeline Execution (Automated)

Once GitHub secrets are set, the CI/CD pipeline handles everything automatically on every push to `main`.

The pipeline passes `DD_API_KEY` and `DD_APP_KEY` to every `terraform plan`, `terraform apply`, and rollback command across all three stages. No manual intervention is needed for Datadog after secrets are configured.

```bash
# Trigger manually for a specific environment
gh workflow run ci-cd-pipeline.yml \
  --ref main \
  --field environment=test \
  --repo ${GITHUB_ORG}/${GITHUB_REPO}

# Watch live
gh run watch --repo ${GITHUB_ORG}/${GITHUB_REPO}
```

The pipeline's health check (CHECK 9) will fail the stage if:
- The Datadog namespace exists but the Agent DaemonSet has pods not ready
- The Cluster Agent deployment has pods not ready
- Any Datadog pod is in CrashLoopBackOff

It will warn (but not fail) if the namespace does not exist — this handles the first pipeline run where Terraform hasn't applied yet.

---

### Step 9 — What the IRSA Role Provides

The Datadog Cluster Agent runs with an IAM role (`{cluster-name}-datadog-cluster-agent`) that grants the following read-only AWS permissions:

| Permission Group | Actions | Purpose |
|---|---|---|
| EC2 Read | `Describe*` on instances, volumes, VPCs, security groups | Host tagging and metadata |
| EKS Read | `DescribeCluster`, `ListNodegroups`, `DescribeNodegroup` | Cluster metadata enrichment |
| CloudWatch Read | `GetMetricData`, `GetMetricStatistics`, `ListMetrics` | AWS service metrics in Datadog |
| AutoScaling Read | `DescribeAutoScalingGroups`, `DescribePolicies` | Node group autoscaling visibility |
| Resource Tagging | `GetResources`, `GetTagKeys`, `GetTagValues` | Tag-based metric filtering |

No write permissions are granted. The policy uses a tfsec ignore annotation (`#tfsec:ignore:aws-iam-no-policy-wildcards`) because AWS describe/list APIs do not support resource-level restrictions — the annotation is documented and scoped with an expiry date.

---

### Step 10 — Configuring Datadog Monitors and Dashboards

After the agents are running and data is flowing, set up alerting:

#### Recommended monitors to create in Datadog

```
# Node CPU > 80% for 5 minutes
avg(last_5m):avg:kubernetes.cpu.usage.total{cluster_name:eks-platform-prod} by {host} > 80

# Pod restart count > 5 in 10 minutes
sum(last_10m):sum:kubernetes.containers.restarts{cluster_name:eks-platform-prod} by {pod_name} > 5

# Node NotReady condition
avg(last_2m):avg:kubernetes.node.status{status:notready,cluster_name:eks-platform-prod} > 0

# Datadog Agent not reporting (heartbeat)
"datadog.agent.running" is not available on any host tagged cluster_name:eks-platform-prod
```

These can be created via the Datadog UI under **Monitors → New Monitor → Metric** or via the Datadog Terraform provider if you want monitors managed as code.

---

### Troubleshooting — Datadog

#### Agent pods are in `Pending` state

```bash
kubectl describe pod -n datadog -l app=datadog | grep -A10 Events
```

Common causes:
- Node resource pressure — check `kubectl top nodes`
- Missing tolerations for tainted nodes — the module configures tolerations for `NoSchedule` and `NoExecute` by default, covering system and spot node taints

#### Agent pods are in `CrashLoopBackOff`

```bash
kubectl logs -n datadog -l app=datadog --previous | tail -50
```

Common causes:
- **Invalid API key** — logs show `API key is not valid`. Verify `DD_API_KEY` secret value in GitHub and re-run the pipeline
- **Wrong `datadog_site`** — agent starts but shows `Error sending payload` for a different site. Verify `datadog_site` in `terraform.tfvars`
- **containerd socket not found** — logs show `criSocketPath not found`. Verify EKS node AMI is Amazon Linux 2 (EKS-optimized) which uses containerd

#### No data appearing in Datadog after 5 minutes

```bash
# Check agent connectivity directly
AGENT_POD=$(kubectl get pods -n datadog -l app=datadog -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n datadog $AGENT_POD -- agent status | grep -A5 "API Keys status"
```

If it shows `API Keys status: API Key valid`, the key is correct but data routing may be the issue. Confirm `datadog_site` matches your account's URL.

#### Cluster Agent fails to start — IRSA issue

```bash
kubectl logs -n datadog deployment/datadog-cluster-agent | grep -i "sts\|role\|credentials\|aws"
```

If you see `NoCredentialProviders` or `AccessDenied`, verify the IRSA annotation:

```bash
kubectl get serviceaccount datadog-cluster-agent -n datadog -o yaml | grep amazonaws
```

It should show `eks.amazonaws.com/role-arn: arn:aws:iam::<account>:role/<cluster>-datadog-cluster-agent`. If missing, re-run Terraform apply.

#### `datadog_api_key` variable not set — pipeline fails at plan

```
Error: No value for required variable
  on variables.tf line 24:
  24: variable "datadog_api_key" {
```

**Fix:** Confirm `DD_API_KEY` is set as a GitHub Actions secret:
```bash
gh secret list --repo ${GITHUB_ORG}/${GITHUB_REPO} | grep DD_API_KEY
```

If missing, set it (see Step 3 above). The pipeline does not have a default value for `datadog_api_key` intentionally — a missing key must fail loudly, not silently deploy a non-functional agent.

#### Upgrading the Datadog Helm chart version

The chart version is pinned in `terraform/modules/datadog/variables.tf`:

```hcl
variable "helm_chart_version" {
  default = "3.69.0"
}
```

To upgrade, change the default or override it per environment in the `module "datadog"` block:

```hcl
module "datadog" {
  ...
  helm_chart_version = "3.72.0"   # pin to new version
}
```

Check the Datadog Helm chart changelog at: `https://github.com/DataDog/helm-charts/blob/main/charts/datadog/CHANGELOG.md`

---

## 21. Autonomous Datadog Configuration Agent

### What it is

`scripts/datadog-agent.sh` is a fully autonomous post-deploy agent that runs inside the CI/CD pipeline immediately after the Kubernetes health check in every environment (test, staging, prod). It requires no human input — it reads credentials from environment variables, detects existing Datadog resources, and creates or updates everything idempotently.

On every pipeline run it:

1. **Validates** the Datadog API key against `GET /api/v1/validate` — fails the step immediately if the key is rejected
2. **Waits** for the Datadog Agent DaemonSet to reach full readiness (up to 5 minutes) using `kubectl` with an AWS API fallback for private-endpoint clusters
3. **Waits** for the first metric (`kubernetes.cpu.usage.total`) to appear in Datadog (up to 10 minutes) — non-blocking; continues even on timeout
4. **Creates or updates 7 monitors** using tag-based idempotency — safe to re-run on every push
5. **Creates or updates a dashboard** titled `EKS Overview — <cluster-name>` with 8 widgets
6. **Writes a structured JSON artifact** to `artifacts/datadog-agent.json` for the pipeline upload step

The step is marked `continue-on-error: true` so a transient Datadog API failure never blocks an infrastructure deployment.

---

### When it runs

| Pipeline stage | Condition to run | Environment passed |
|---|---|---|
| Test | Cluster exists in AWS (`guard.cluster_exists == 'true'`) | `test` |
| Staging | Kubernetes API reachable from runner (`kube_api.reachable == 'true'`) | `staging` |
| Production | Cluster exists in AWS (`guard.cluster_exists == 'true'`) | `prod` |

The agent is skipped automatically (step not triggered) on the very first pipeline run before a cluster has been provisioned.

---

### Required inputs

| Source | Variable | Required | Purpose |
|---|---|---|---|
| GitHub secret | `DD_API_KEY` | **Yes** | Authenticates to Datadog API; validated in Phase 1 |
| GitHub secret | `DD_APP_KEY` | No | Enables monitor/dashboard creation; agent warns and skips Phase 4+5 if absent |
| Global `env:` | `DD_SITE` | No (default `datadoghq.com`) | Datadog intake site; must match your account region |

The agent hard-exits (non-zero) only if `DD_API_KEY` is unset or invalid. Everything else degrades gracefully.

---

### What it creates

#### Monitors (7 total)

All monitors are tagged `managed-by:eks-platform-datadog-agent`, `cluster:<name>`, and `env:<environment>`. The agent does a lookup by these tags + name substring before creating — if a monitor already exists it sends a PUT (update), not a POST (duplicate).

| Monitor name | Condition | Severity |
|---|---|---|
| `[EKS] Node CPU High — <cluster>` | avg CPU > 85% for 5 min | Warning |
| `[EKS] Node Memory High — <cluster>` | avg memory > 90% for 5 min | Warning |
| `[EKS] Pod Restart Rate High — <cluster>` | restarts > 10 in 10 min | Critical |
| `[EKS] Node NotReady — <cluster>` | any node not ready for 2 min | Critical |
| `[EKS] Deployment Unavailable — <cluster>` | any deployment has 0 available replicas | Critical |
| `[EKS] Node Disk Pressure — <cluster>` | disk usage > 85% for 5 min | Warning |
| `[EKS] Agent Heartbeat — <cluster>` | `datadog.agent.running` missing | Critical |

#### Dashboard

A single dashboard titled `EKS Overview — <cluster-name>` with 8 time-series and query-value widgets:

- Node CPU usage by host
- Node memory usage by host
- Pod restart rate by pod name
- Active pod count
- Node disk usage by host
- Network in/out bytes by host
- Deployment available replicas
- Agent heartbeat status

---

### Running it manually

The agent can be run locally against any cluster you have `kubectl` access to:

```bash
# Export credentials
export DD_API_KEY="<your-api-key>"
export DD_APP_KEY="<your-app-key>"        # optional but recommended
export DD_SITE="datadoghq.com"            # match your account site

# Run against the test cluster
cd ~/eks-platform
./scripts/datadog-agent.sh eks-platform-test us-east-1 test

# Run against prod
./scripts/datadog-agent.sh eks-platform-prod us-east-1 prod
```

The script uses color-coded output:

```
[INFO]  Phase 1: API Validation
[INFO]  PASS: Datadog API key is valid
[INFO]  Phase 2: DaemonSet Readiness
[INFO]  PASS: DaemonSet ready: 3/3
[INFO]  Phase 3: Waiting for First Metrics
[INFO]  PASS: Metrics flowing (kubernetes.cpu.usage.total detected)
[INFO]  Phase 4: Creating/Updating Monitors
[INFO]  UPSERT: [EKS] Node CPU High — eks-platform-test (updated existing)
[INFO]  UPSERT: [EKS] Node Memory High — eks-platform-test (created new)
...
[INFO]  Phase 5: Creating/Updating Dashboard
[INFO]  UPSERT: EKS Overview — eks-platform-test (updated existing)
[INFO]  Phase 6: Summary
```

---

### Artifact output

After every run the agent writes `artifacts/datadog-agent.json`:

```json
{
  "agent": "datadog-agent",
  "version": "1.0.0",
  "cluster": "eks-platform-test",
  "environment": "test",
  "status": "success",
  "reason": "all phases completed",
  "phases": {
    "api_validation": "pass",
    "daemonset_ready": "pass",
    "metrics_wait": "pass",
    "monitors_created": 7,
    "dashboard_created": 1
  },
  "timestamp": "2026-04-28T14:32:01Z"
}
```

This artifact is uploaded as part of the stage artifact bundle (`test-status`, `staging-status`, `prod-status`) and is visible under **Actions → run → Artifacts** in GitHub.

Possible `status` values:

| Value | Meaning |
|---|---|
| `success` | All phases completed, monitors and dashboard are live |
| `api_key_missing` | `DD_API_KEY` env var was not set — step skipped entirely |
| `api_key_invalid` | Key rejected by Datadog API — check key value and `DD_SITE` |
| `no_app_key` | `DD_APP_KEY` not set — validation passed, monitor/dashboard creation skipped |
| `daemonset_timeout` | DaemonSet did not become ready within 5 minutes |
| `partial` | Some monitors or dashboard creation failed (details in pipeline logs) |

---

### Idempotency

The agent is safe to run on every pipeline execution. It does not create duplicate monitors or dashboards:

- **Monitors:** before creating, it calls `GET /api/v1/monitor?tags=managed-by:eks-platform-datadog-agent,cluster:<name>` and filters by name substring. If a match is found it sends `PUT /api/v1/monitor/<id>` (update in place). If not found it sends `POST /api/v1/monitor` (create new).
- **Dashboard:** searches existing dashboards by title. If found sends `PUT /api/v1/dashboard/<id>`. If not found sends `POST /api/v1/dashboard`.

This means a force-push or re-run of the pipeline against an already-deployed cluster will update existing Datadog resources to match the current configuration — the same idempotency guarantee as `terraform apply`.
