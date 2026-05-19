# Autonomous Agents

This repository is operated by a layered agent system designed to minimize human intervention.

---

## Agent Index

| Agent | Script | Trigger | Blocks Pipeline |
|-------|--------|---------|-----------------|
| Security Triage | `scripts/security-triage-agent.sh` | CI/CD test stage | Yes (BLOCK findings) |
| Dependency Update | `scripts/dependency-update-agent.sh` | Sunday 02:00 UTC | No (creates PR) |
| Drift Remediation | `scripts/drift-remediation-agent.sh` | Daily 06:00 UTC | No (auto-remediates) |
| Cluster Self-Heal | `scripts/cluster-selfheal-agent.sh` | Every 15 min | No (reactive) |
| Rollback Decision | `scripts/rollback-decision-agent.sh` | Post-prod deploy | Yes (if degraded) |
| Auto-Approval | `scripts/auto-approval-engine.sh` | CI/CD prod stage | Yes (gates apply) |
| Cost Impact | `scripts/cost-impact-agent.sh` | CI/CD test/staging | No (warning only) |
| Prod Recommendation | `scripts/prod-recommendation-agent.sh` | CI/CD prod stage | Yes (if blockers) |
| Pipeline Verify | `scripts/pipeline-agent-verify.sh` | CI/CD all stages | Yes |
| Changelog | `scripts/changelog-agent.sh` | CI/CD staging | No |
| K8s Healthcheck | `scripts/k8s-healthcheck.sh` | CI/CD all stages | Yes |

---

## GitHub Actions Workflows

| Workflow | File | Schedule |
|----------|------|----------|
| CI/CD Pipeline | `.github/workflows/ci-cd-pipeline.yml` | On push to main |
| Scheduled Maintenance | `.github/workflows/scheduled-maintenance.yml` | Daily 06:00 (drift), Sunday 02:00 (deps) |
| Cluster Monitor | `.github/workflows/cluster-monitor.yml` | Every 15 minutes |

---

## Security Triage Agent

**`scripts/security-triage-agent.sh`** — Runs in the CI/CD test stage after tfsec and checkov.

Classifies every finding into one of three verdicts:
- **BLOCK** — genuine risk, pipeline fails
- **WARN** — logged but not blocking
- **SUPPRESS** — known-safe for this project (ALB egress, IRSA wildcards, etc.)

Classification rules:
1. Suppression list matched by rule ID → always `SUPPRESS`
2. Block list matched → always `BLOCK`
3. CRITICAL/HIGH severity → `BLOCK`
4. MEDIUM → `WARN`
5. LOW/INFO → `SUPPRESS`

If `ANTHROPIC_API_KEY` is set, BLOCK findings are sent to Claude Haiku for false-positive analysis. Works entirely without the key (rule-based fallback).

Output: `artifacts/security-triage-report.json`

```bash
scripts/security-triage-agent.sh tfsec-results.json checkov-results.json
```

---

## Dependency Update Agent

**`scripts/dependency-update-agent.sh`** — Runs weekly on Sunday at 02:00 UTC.

Checks for outdated:
1. EKS managed add-on versions (vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver)
2. Helm chart versions (aws-load-balancer-controller, cluster-autoscaler, metrics-server)
3. npm packages in `app/`
4. Docker base image (`node:XX-alpine`)
5. Terraform CLI version

When updates are found, creates a GitHub PR on branch `deps/auto-update-YYYYMMDD-HHMM` with all changes applied.

```bash
scripts/dependency-update-agent.sh --dry-run          # assess only
GH_TOKEN=... GITHUB_REPOSITORY=org/repo scripts/dependency-update-agent.sh
```

Output: `artifacts/dependency-update-report.json`

---

## Drift Remediation Agent

**`scripts/drift-remediation-agent.sh`** — Runs daily at 06:00 UTC against test and staging.

Runs `terraform plan -refresh-only` for each environment and classifies drifted resources:

**Safe to auto-apply:**
- Tag/label changes
- Minor attribute updates on non-critical resources

**Never auto-applied (hardcoded):**
- Changes to `module.vpc`, `module.eks`, `module.iam`, `aws_kms_key`, `module.github_oidc`
- Any `REPLACE` or `DELETE` action
- Production environment (unless `DRIFT_ALLOW_PROD=true`)

Auto-apply is disabled by default (`DRIFT_AUTO_APPLY=false`). Enable via GitHub repository variable `DRIFT_AUTO_APPLY` once the agent has been validated.

```bash
scripts/drift-remediation-agent.sh --dry-run
ENVIRONMENT=staging DRIFT_AUTO_APPLY=true scripts/drift-remediation-agent.sh
```

Output: `artifacts/drift-remediation-report.json`

---

## Cluster Self-Heal Agent

**`scripts/cluster-selfheal-agent.sh`** — Runs every 15 minutes via `cluster-monitor.yml`.

Three healing actions:
1. **Node cordon** — cordons `NotReady` nodes (never drains)
2. **Pod restart** — deletes `CrashLoopBackOff`/`OOMKilled` pods to trigger redeploy
3. **Add-on recovery** — `kubectl rollout restart` for critical add-ons with 0 ready replicas

**Safety constraints (hardcoded):**
- Cooldown: max 1 action per deployment per 30-minute window (`/tmp/selfheal-cooldown/`)
- Safety floor: will not restart pods if `readyReplicas < desired/2`
- Only restarts Deployment-owned pods — never StatefulSets or DaemonSets
- Cordons but **never drains** nodes

```bash
SELFHEAL_DRY_RUN=true scripts/cluster-selfheal-agent.sh cluster-name us-east-1
scripts/cluster-selfheal-agent.sh cluster-name us-east-1
```

Output: `artifacts/selfheal-report.json`

---

## Rollback Decision Agent

**`scripts/rollback-decision-agent.sh`** — Runs in the production stage immediately after a successful `terraform apply`.

Monitors the `typescript-app` deployment for 10 minutes (600s), polling every 60s. Each observation is scored 0.0–1.0 based on three signals:

| Signal | Good | Moderate | Bad |
|--------|------|----------|-----|
| Availability (ready/desired) | 1.0 | ×0.7 if partial | ×0.3 if < 50% |
| New restarts delta | 0 | ×0.7 if >2 | ×0.1 if >10 |
| CrashLoopBackOff pods | 0 | — | ×0.2 if any |

If the rolling average score falls below `ROLLBACK_THRESHOLD` (default `0.35`), the agent triggers `kubectl rollout undo deployment/typescript-app -n app`.

**Safety constraint:** Only uses `kubectl rollout undo`. Never touches Terraform state.

Auto-rollback is enabled by default in production (`ROLLBACK_AUTO_ENABLED=true`). Disable via GitHub repository variable if needed.

```bash
ROLLBACK_AUTO_ENABLED=true scripts/rollback-decision-agent.sh prod cluster-name
ROLLBACK_AUTO_ENABLED=false scripts/rollback-decision-agent.sh prod cluster-name  # assess only
```

Output: `artifacts/rollback-decision-report.json`

---

## Auto-Approval Engine

**`scripts/auto-approval-engine.sh`** — Runs in the CI/CD production stage.

Makes autonomous go/no-go decisions by combining the prod-recommendation confidence score with change-type analysis:

| Condition | Decision |
|-----------|----------|
| Blockers detected | MANUAL_APPROVAL_REQUIRED |
| Confidence < threshold | MANUAL_APPROVAL_REQUIRED |
| `terraform/` files changed | MANUAL_APPROVAL_REQUIRED |
| Cost increase detected | MANUAL_APPROVAL_REQUIRED |
| Patch / addon / security fix | AUTO_APPROVED |
| Confidence > 0.95 | AUTO_APPROVED |

Infrastructure detection uses `git diff --name-only HEAD~1 HEAD | grep '^terraform/'` (not keyword matching against commit messages).

Configuration: `.github/auto-approval-config.env`
- `AUTO_APPROVAL_ENABLED=true` (enabled)
- `MIN_CONFIDENCE_FOR_AUTO=0.90`
- `COST_THRESHOLD_USD=1000`

Output: `artifacts/auto-approval-decision.json`

---

## Cost Impact Agent

**`scripts/cost-impact-agent.sh`** — Runs after `terraform plan` in test and staging.

Estimates monthly cost delta from the plan output using heuristic resource pricing. Non-blocking (warns only). Feeds cost signal into the prod-recommendation confidence score.

Output: `artifacts/cost-impact.json`

---

## Prod Recommendation Agent

**`scripts/prod-recommendation-agent.sh`** — Runs in the production stage before the auto-approval engine.

Aggregates 6 signals into a confidence score (0.0–1.0):
1. Staging gate outcome
2. Security scan results
3. Cost impact
4. Infrastructure drift
5. Cluster health checks
6. Change volume / commit count

Confidence ≥ 0.80 → `AUTO_APPROVE` recommendation fed to the auto-approval engine.

Output: `artifacts/prod-recommendation.json`

---

## Configuration Reference

### GitHub Secrets

| Secret | Purpose |
|--------|---------|
| `AWS_ROLE_TEST` | OIDC role for test environment |
| `AWS_ROLE_STAGING` | OIDC role for staging environment |
| `AWS_ROLE_PROD` | OIDC role for production environment |
| `AWS_ACCOUNT_ID` | Target AWS account ID |
| `GH_TOKEN` | GitHub token for dependency update PRs |
| `ANTHROPIC_API_KEY` | Optional: Claude API for security triage enrichment |
| `SLACK_WEBHOOK_URL` | Optional: Slack notifications from auto-approval engine |

### GitHub Repository Variables (Tunable)

| Variable | Default | Purpose |
|----------|---------|---------|
| `DRIFT_AUTO_APPLY` | `false` | Enable drift auto-remediation |
| `DRIFT_ALLOW_PROD` | `false` | Include prod in drift checks |
| `ROLLBACK_AUTO_ENABLED` | `true` | Enable autonomous rollback |

---

## Human Intervention Points

The following always require manual approval:

1. **Changes to `terraform/` files** — auto-approval engine blocks; requires GitHub environment approval
2. **Cost increase > $1000/month** — blocked by auto-approval engine
3. **Drift with REPLACE/DELETE actions** — drift-remediation agent skips; logged for review
4. **Protected resource drift** — `module.vpc`, `module.eks`, `module.iam`, `aws_kms_key`
5. **Rollback needed but `ROLLBACK_AUTO_ENABLED=false`** — agent exits 1, pipeline surfaces the alert
6. **Dependency PR** — auto-created but requires human review before merge
7. **Security BLOCK finding** — pipeline fails; requires fix or documented suppression

---

## Pipeline Flow

```
push to main
     │
     ▼
┌─────────────────────────────────────┐
│  Build (fmt, validate, lint, tsc)   │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  Test Environment                   │
│  ├─ ECR bootstrap + Docker build    │
│  ├─ terraform plan + apply          │
│  ├─ tfsec + checkov (raw scan)      │
│  ├─ security-triage-agent ← new     │
│  ├─ cost-impact-agent               │
│  ├─ k8s-healthcheck                 │
│  └─ pipeline-agent-verify           │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  Staging Environment                │
│  ├─ ECR + terraform apply           │
│  ├─ k8s health + addon validation   │
│  ├─ app deployment validation       │
│  ├─ changelog-agent                 │
│  └─ pipeline-agent-verify           │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│  Production Environment             │
│  ├─ ECR + terraform plan            │
│  ├─ Final security scan             │
│  ├─ prod-recommendation-agent       │
│  ├─ auto-approval-engine            │
│  ├─ terraform apply (if approved)   │
│  ├─ k8s rollout status              │
│  ├─ rollback-decision-agent ← new   │  (10-min post-deploy monitoring)
│  └─ pipeline-agent-verify           │
└─────────────────────────────────────┘

Background (cluster-monitor.yml — every 15 min):
  └─ cluster-selfheal-agent (all environments)

Background (scheduled-maintenance.yml):
  ├─ drift-remediation-agent (daily 06:00 UTC)
  └─ dependency-update-agent (Sunday 02:00 UTC)
```
