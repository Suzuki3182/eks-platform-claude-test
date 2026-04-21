# Skills.md — EKS Platform Agent Skill Definitions

This file defines the executable skill set available to the autonomous pipeline agent. Each skill is self-contained, idempotent, and safe to re-invoke.

---

## Skill: `terraform-validate`

**Purpose:** Validates Terraform configuration correctness across all environments.

**Invocation:**
```bash
# Format check (all modules)
terraform fmt -check -recursive terraform/

# Init without backend (CI validation)
terraform -chdir=terraform/environments/<env> init -backend=false

# Validate syntax and references
terraform -chdir=terraform/environments/<env> validate

# Generate plan (requires backend + credentials)
terraform -chdir=terraform/environments/<env> plan \
  -var="aws_account_id=$AWS_ACCOUNT_ID" \
  -out=tfplan.binary \
  -detailed-exitcode

# Apply from saved plan
terraform -chdir=terraform/environments/<env> apply \
  -auto-approve tfplan.binary

# Refresh state (non-destructive rollback step)
terraform -chdir=terraform/environments/<env> apply \
  -refresh-only -auto-approve \
  -var="aws_account_id=$AWS_ACCOUNT_ID"

# Destroy (requires explicit --auto-approve AND human confirmation — NEVER in CI)
terraform -chdir=terraform/environments/<env> destroy \
  -var="aws_account_id=$AWS_ACCOUNT_ID"
```

**Exit codes:**
- `0` = no changes
- `1` = error
- `2` = changes present (plan only)

**Success criteria:** All environments validate without error. Plan diff is reviewed before apply.

---

## Skill: `security-scan`

**Purpose:** Runs static analysis tools against Terraform code and enforces policy-as-code gates.

**tfsec:**
```bash
# Install
curl -L https://github.com/aquasecurity/tfsec/releases/latest/download/tfsec-linux-amd64 \
  -o /usr/local/bin/tfsec && chmod +x /usr/local/bin/tfsec

# Run — fail on HIGH+
tfsec terraform/ \
  --format json \
  --out tfsec-results.json \
  --minimum-severity HIGH \
  --no-color

# Parse results
HIGH_COUNT=$(jq '[.results[] | select(.severity == "HIGH" or .severity == "CRITICAL")] | length' \
  tfsec-results.json)
```

**checkov:**
```bash
pip3 install checkov

checkov -d terraform/ \
  --framework terraform \
  --output json \
  --output-file checkov-results.json \
  --compact --quiet

FAILED=$(jq '.summary.failed' checkov-results.json)
```

**tflint:**
```bash
tflint --init
tflint --chdir=terraform/environments/<env> --format=compact
```

**Gate logic:**
- `tfsec` CRITICAL or HIGH findings → FAIL pipeline
- `checkov` failures > 10 → FAIL pipeline
- `tflint` errors → FAIL pipeline (warnings allowed)

---

## Skill: `k8s-verify`

**Purpose:** Verifies Kubernetes cluster health, pod readiness, DNS, and ingress.

**Node readiness:**
```bash
kubectl get nodes
kubectl wait --for=condition=Ready node --all --timeout=300s
```

**System deployment health:**
```bash
kubectl rollout status deployment/coredns -n kube-system --timeout=120s
kubectl rollout status deployment/aws-load-balancer-controller -n kube-system --timeout=120s
kubectl rollout status deployment/cluster-autoscaler -n kube-system --timeout=120s
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
```

**DaemonSet health:**
```bash
kubectl rollout status daemonset/aws-node -n kube-system --timeout=120s
kubectl rollout status daemonset/kube-proxy -n kube-system --timeout=120s
```

**DNS resolution test:**
```bash
kubectl run dns-test --image=busybox:1.28 --restart=Never --rm -i \
  --timeout=60s -- nslookup kubernetes.default.svc.cluster.local
```

**Pod CrashLoopBackOff check:**
```bash
kubectl get pods -A --field-selector=status.phase!=Succeeded | grep CrashLoopBackOff
```

**Full automated check:**
```bash
./scripts/k8s-healthcheck.sh <cluster-name> <aws-region>
```

**Success criteria:** Exit code 0, all 8 checks passed.

---

## Skill: `aws-ops`

**Purpose:** AWS authentication, STS session management, EKS operations, and S3/DynamoDB state management.

**OIDC authentication (GitHub Actions):**
```yaml
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: ${{ secrets.AWS_ROLE_<ENV> }}
    role-session-name: GitHubActions-<stage>-${{ github.run_id }}
    aws-region: us-east-1
```

**STS assume role (CLI):**
```bash
aws sts assume-role \
  --role-arn "arn:aws:iam::$ACCOUNT_ID:role/$ROLE_NAME" \
  --role-session-name pipeline-session \
  --duration-seconds 3600 \
  | jq '{AccessKeyId: .Credentials.AccessKeyId, SecretAccessKey: .Credentials.SecretAccessKey, SessionToken: .Credentials.SessionToken}'
```

**EKS kubeconfig:**
```bash
aws eks update-kubeconfig \
  --region $AWS_REGION \
  --name $CLUSTER_NAME
```

**EKS describe/status:**
```bash
aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION
aws eks list-nodegroups --cluster-name $CLUSTER_NAME --region $AWS_REGION
aws eks describe-nodegroup --cluster-name $CLUSTER_NAME --nodegroup-name $NG_NAME --region $AWS_REGION
```

**S3 state bucket bootstrap:**
```bash
aws s3api create-bucket \
  --bucket eks-platform-tfstate-$ENV \
  --region $AWS_REGION \
  --create-bucket-configuration LocationConstraint=$AWS_REGION

aws s3api put-bucket-versioning \
  --bucket eks-platform-tfstate-$ENV \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket eks-platform-tfstate-$ENV \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "aws:kms"}}]
  }'
```

**DynamoDB lock table bootstrap:**
```bash
aws dynamodb create-table \
  --table-name eks-platform-tfstate-lock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region $AWS_REGION
```

---

## Skill: `ci-cd-orchestrator`

**Purpose:** Manages GitHub Actions stage chaining, environment gates, artifact parsing, and pipeline status emission.

**Artifact emission (all stages):**
```bash
mkdir -p artifacts
cat > artifacts/agent-output.json << EOF
{
  "stage": "$STAGE",
  "status": "success|failure|pending",
  "reason": "<descriptive string>",
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "commit": "$GITHUB_SHA",
  "run_id": "$GITHUB_RUN_ID",
  "actor": "$GITHUB_ACTOR"
}
EOF
```

**Upload artifact:**
```yaml
- uses: actions/upload-artifact@v4
  with:
    name: <stage>-status
    path: artifacts/agent-output.json
    retention-days: 5
```

**Download and verify prior stage:**
```yaml
- uses: actions/download-artifact@v4
  with:
    name: <prior-stage>-status
    path: prior-artifacts/
- run: |
    STATUS=$(jq -r '.status' prior-artifacts/agent-output.json)
    [[ "$STATUS" == "success" ]] || (echo "Prior stage failed"; exit 1)
```

**Stage gate logic (needs + environment):**
```yaml
jobs:
  next-stage:
    needs: prior-stage
    if: needs.prior-stage.outputs.status == 'success'
    environment: <env-name>   # triggers GitHub Environment protection rules
```

**Rollback invocation:**
```bash
# Terraform state refresh
terraform apply -refresh-only -auto-approve -var="aws_account_id=$AWS_ACCOUNT_ID"

# K8s workload rollback
kubectl rollout undo deployment --all -n kube-system

# Verify rollback
kubectl rollout status deployment --all -n kube-system --timeout=120s
```

**Full pipeline agent:**
```bash
./scripts/pipeline-agent-verify.sh <test|staging|prod>
```

**Success criteria:** Agent writes `{"status": "success"}` to `artifacts/agent-output.json` and exits 0.

---

## Skill Execution Policy

| Skill                 | test | staging | prod | Requires Approval |
|-----------------------|------|---------|------|-------------------|
| terraform-validate    | ✓    | ✓       | ✓    | Never             |
| security-scan         | ✓    | ✓       | ✓    | Never             |
| k8s-verify            | ✓    | ✓       | ✓    | Never             |
| aws-ops (read)        | ✓    | ✓       | ✓    | Never             |
| aws-ops (write/apply) | auto | auto    | manual| prod only        |
| ci-cd-orchestrator    | auto | auto    | auto | Never             |

All skills are idempotent and timeout-safe (max 5 minutes each). Skills emit structured diagnostics on failure — never exit silently.
