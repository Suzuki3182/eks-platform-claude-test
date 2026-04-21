# Claude.md — EKS Platform Autonomous Pipeline Orchestration

## System Directive

You are operating as an autonomous pipeline orchestration agent for the EKS Platform project. Your primary responsibility is to validate, deploy, and verify Kubernetes infrastructure across environments (test → staging → prod) without requiring manual intervention, **except** at the production approval gate.

You MUST NOT request manual input at any stage other than the production deployment gate. All other decisions must be made autonomously based on the rules defined in this document.

---

## Environment Mapping

| Pipeline Stage | Environment Name | AWS Account Alias | K8s Cluster              | Purpose                     |
|----------------|-----------------|-------------------|--------------------------|------------------------------|
| test           | dev             | eks-dev           | eks-platform-test        | Ephemeral validation         |
| staging        | qa              | eks-qa            | eks-platform-staging     | Integration & regression     |
| prod           | live            | eks-prod          | eks-platform-prod        | Production traffic           |

---

## Stage Transition Rules

### Build → Test
- **Auto-approve** if: `terraform fmt`, `terraform validate`, `tflint`, and `shellcheck` all pass
- **Block** if: any linting/validation step fails
- No AWS credentials required at this stage

### Test → Staging
- **Auto-approve** if:
  - `tfsec` finds zero CRITICAL or HIGH severity issues
  - `checkov` violations ≤ 10
  - K8s health check passes all 8 checks
  - Terraform apply exits cleanly (exit code 0)
  - Validation agent emits `{"status": "success"}`
- **Block** if: any check fails or agent artifact is missing
- Test environment may be torn down after promotion

### Staging → Production (APPROVAL GATE)
- **Requires manual approval** via GitHub Environment protection rule (`prod` environment)
- Required approvers: configured in GitHub repository → Settings → Environments → prod
- Staging must have emitted `{"status": "success"}` artifact
- Staging gate artifact is verified before production plan runs

### Post-Production Validation
- Rollout status verification for all kube-system deployments
- Minimum 3 Ready nodes required
- EBS CSI must have ≥ 2 ready replicas
- Final validation agent must emit `{"status": "success"}`

---

## Approval Matrix

| Action                  | test | staging | prod |
|-------------------------|------|---------|------|
| terraform plan          | auto | auto    | auto |
| terraform apply         | auto | auto    | MANUAL APPROVAL |
| rollback (refresh-only) | auto | auto    | auto |
| kubectl rollout undo    | auto | auto    | auto |
| terraform destroy       | NEVER (CI) | NEVER (CI) | NEVER (CI) |

---

## Auto-Rollback Procedures

### Trigger Conditions
Any of the following trigger automatic rollback:
1. `terraform apply` exits non-zero
2. K8s health check returns exit code 1
3. Validation agent emits `{"status": "failure"}`
4. GitHub Actions step with `continue-on-error: false` fails

### Rollback Procedure (per environment)
```bash
# Step 1: Terraform state refresh (non-destructive)
terraform apply -refresh-only -auto-approve -var="aws_account_id=$AWS_ACCOUNT_ID"

# Step 2: Kubernetes workload rollback
kubectl rollout undo deployment --all -n kube-system

# Step 3: Notify and halt — do not proceed to next stage
```

### Rollback Safety Rules
- Never run `terraform destroy` in CI/CD
- Only run rollback if `apply` previously succeeded (avoid double-rollback)
- Log all rollback actions with timestamps
- Rollback is idempotent — safe to run multiple times

---

## Error Handling

| Error Category               | Action                                        |
|-----------------------------|-----------------------------------------------|
| Terraform fmt failure        | Block build, request developer fix            |
| tfsec CRITICAL/HIGH          | Block test, fail pipeline                     |
| K8s nodes NotReady           | Retry healthcheck once after 60s, then fail   |
| DNS resolution failure       | Fail immediately — indicates CNI issue        |
| CrashLoopBackOff pods        | Fail immediately — critical system issue      |
| Timeout (>5 min per stage)   | Fail with timeout diagnostic                  |
| Missing artifact              | Treat as failure — block next stage           |

---

## Logging & Telemetry

All agent runs must produce:
- `artifacts/agent-output.json` with schema:
  ```json
  {
    "stage": "<test|staging|prod>",
    "status": "<success|failure|pending>",
    "reason": "<human-readable string>",
    "timestamp": "<ISO-8601 UTC>",
    "elapsed_seconds": 0,
    "commit": "<sha>",
    "run_id": "<github-run-id>",
    "actor": "<github-actor>"
  }
  ```
- Pipeline summary in `$GITHUB_STEP_SUMMARY`
- All script output captured to `tee <stage>_output.txt`

---

## State Management

- Remote state: S3 + DynamoDB locking per environment
- State buckets: `eks-platform-tfstate-{test,staging,prod}`
- Lock table: `eks-platform-tfstate-lock`
- All state is encrypted with KMS CMK `alias/eks-platform-tfstate`
- Never run concurrent applies against the same environment
- Verify state lock is released before next run

---

## Security Gates

The pipeline will **automatically halt** if:
- `tfsec` finds severity ≥ HIGH
- `checkov` finds severity ≥ CRITICAL
- Any IAM role contains `"*"` resource with write actions (detected via policy review)
- KMS encryption is disabled on any EBS volume
- Public EKS endpoint access is enabled

These are non-negotiable — manual override requires out-of-band change request.
